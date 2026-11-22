// 聊天主界面（T2.2/T2.3）：消息流、气泡、时间分隔、长按菜单、输入条、
// 多会话抽屉、会话内搜索、失败队列入口；阶段 12 增加选图/图片气泡/全屏预览。
// 依据 UI_PAGE_SPEC §B5、UI_INTERACTION_SPEC §2 与 ROADMAP 阶段 2/12。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../data/attachment/attachment_store.dart';
import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/context/chat_context_assembler.dart';
import '../../data/notification/notification_runtime.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/model_repository.dart';
import '../../domain/chat/chat_provider.dart';
import '../../domain/chat/echo_provider.dart';
import '../../domain/chat/message_status.dart';
import '../../domain/image/image_models.dart';
import '../chat/chat_provider_resolver.dart';
import '../chat/chat_session_controller.dart';
import '../chat/image_picker_service.dart';
import '../theme/bubble_colors.dart';
import '../utils/time_format.dart';
import '../widgets/chat/chat_input_bar.dart';
import '../widgets/chat/conversation_actions.dart';
import '../widgets/chat/conversation_drawer.dart';
import '../widgets/chat/message_bubble.dart';
import 'image_preview_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.conversationId,
    this.focusMessageId,
    this.repository,
    this.modelRepository,
    this.provider,
    this.attachmentRepository,
    this.attachmentStore,
    this.imagePicker,
    this.contextAssembler,
  });

  final String conversationId;

  /// 通知点击深链定位的消息 id（阶段 13）
  final String? focusMessageId;

  /// 可选注入（测试用）；默认使用全局数据库
  final ConversationRepository? repository;
  final ModelRepository? modelRepository;
  final ChatCompletionProvider? provider;

  /// 图片附件仓储/存储（测试注入临时目录）
  final AttachmentRepository? attachmentRepository;
  final AttachmentStore? attachmentStore;

  /// 选图服务（测试注入假实现，避免触碰相册平台通道）
  final ImagePickerService? imagePicker;

  /// 上下文组装回调（测试注入）；为空时真实模型自动启用 ContextBuilder
  final ContextAssemblerCallback? contextAssembler;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final ConversationRepository _repo =
      widget.repository ?? ConversationRepository(AppDb.instance);
  late final ModelRepository _modelRepo =
      widget.modelRepository ?? ModelRepository(AppDb.instance);
  late final AttachmentStore _attachmentStore =
      widget.attachmentStore ?? AttachmentStore();
  late final AttachmentRepository _attachmentRepo =
      widget.attachmentRepository ??
          AttachmentRepository(AppDb.instance, store: _attachmentStore);
  late final ImagePickerService _picker =
      widget.imagePicker ?? DeviceImagePickerService();
  late final Stream<List<Message>> _messagesStream =
      _repo.watchMessages(widget.conversationId);
  late final Stream<List<Attachment>> _attachmentsStream =
      _attachmentRepo.watchMessageAttachments(widget.conversationId);

  /// 待发送图片（发送成功或清空时释放）
  final List<PickedImage> _pendingImages = [];

  /// 解析完成前为空（bootstrap 阶段显示加载）
  ChatCompletionProvider? _provider;
  ChatSessionController? _session;
  String? _providerNotice;

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _messageKeys = {};

  String? _title;
  String? _highlightId;
  String? _pendingFocusId;
  Timer? _highlightTimer;
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _pendingFocusId = widget.focusMessageId;
    _scroll.addListener(_onScroll);
    _bootstrap();
    _bootstrapAttachments();
  }

  /// 附件存储根目录解析（失败不阻断聊天，图片区域显示占位）
  Future<void> _bootstrapAttachments() async {
    try {
      await _attachmentStore.ensureReady();
      if (mounted) setState(() {});
    } catch (_) {
      // 存储不可用时图片显示「文件缺失」占位，文字聊天不受影响
    }
  }

  /// 解析聊天的模型来源：已配置 Key → DeepSeek；否则回退开发回声并提示。
  Future<void> _bootstrap() async {
    ChatCompletionProvider provider;
    String? notice;
    if (widget.provider != null) {
      provider = widget.provider!;
    } else {
      try {
        final resolved = await resolveChatProvider(_modelRepo);
        provider = resolved.provider;
        notice = resolved.notice;
      } catch (error) {
        provider = const EchoProvider();
        notice = '模型解析失败 · 使用开发回声';
      }
    }

    final conv = await _repo.getConversation(widget.conversationId);
    if (!mounted) return;

    // 真实模型启用「人格 + 记忆」总装；开发回声不装配，避免误导为真实能力
    final assembler = widget.contextAssembler ??
        (provider.isMock
            ? null
            : ChatContextAssembler(AppDb.instance).assembleMessages);
    final session = ChatSessionController(
      repository: _repo,
      provider: provider,
      conversationId: widget.conversationId,
      modelRepository: provider.isMock ? null : _modelRepo,
      attachmentRepository: _attachmentRepo,
      contextAssembler: assembler,
    );
    session.addListener(_onSessionChanged);
    setState(() {
      _provider = provider;
      _providerNotice = notice;
      _session = session;
      _title = conv?.title;
    });

    await _repo.markConversationRead(widget.conversationId);
    await session.load();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _stickToBottom =
        _scroll.position.maxScrollExtent - _scroll.position.pixels < 120;
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
    if (_session?.generating ?? false) _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _handleSend(String text) async {
    final session = _session;
    if (session == null) return;
    final images = [..._pendingImages];
    if (text.trim().isEmpty && images.isEmpty) return;
    _input.clear();
    _stickToBottom = true;
    setState(_pendingImages.clear);
    try {
      await session.sendWithImages(
        text,
        [
          for (final image in images)
            OutgoingImage(bytes: image.bytes, fileName: image.fileName),
        ],
      );
    } catch (error) {
      if (!mounted) return;
      // 校验失败：恢复待发图片，明确提示原因（不静默丢弃）
      setState(() => _pendingImages.insertAll(0, images));
      if (error is UnsupportedImageException ||
          error is ImageTooLargeException) {
        _toast('$error');
      } else {
        _toast('图片发送失败：$error');
      }
    }
  }

  /// 选图入口：模型不支持视觉时先明确提示（FR-IMG-02），用户确认后仍可仅本地保存。
  Future<void> _handleAttach() async {
    final provider = _provider;
    if (provider == null || (_session?.generating ?? false)) return;
    if (!provider.supportsVision) {
      final choice = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('当前模型不支持看图'),
          content: const Text(VisionCapability.unsupportedNotice),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'configure'),
              child: const Text('去配置模型'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'add'),
              child: const Text('仍要添加'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == 'configure') {
        context.push('/models');
        return;
      }
      if (choice != 'add') return;
    }

    List<PickedImage> picked;
    try {
      picked = await _picker.pickImages();
    } catch (_) {
      _toast('无法打开相册');
      return;
    }
    if (picked.isEmpty || !mounted) return;
    final room = kMaxImagesPerMessage - _pendingImages.length;
    setState(() {
      _pendingImages.addAll(picked.take(room < 0 ? 0 : room));
    });
    if (picked.length > room) {
      _toast('一条消息最多 $kMaxImagesPerMessage 张图片');
    }
  }

  void _removePendingImage(int index) {
    if (index < 0 || index >= _pendingImages.length) return;
    setState(() => _pendingImages.removeAt(index));
  }

  void _openImagePreview(List<Attachment> attachments, int index) {
    final images = [
      for (final attachment in attachments)
        GalleryImage(
          id: attachment.id,
          relPath: attachment.relPath,
          ownerKind: attachment.ownerKind,
          ownerId: attachment.ownerId,
          createdAt:
              (DateTime.tryParse(attachment.createdAt) ?? DateTime.now())
                  .toLocal(),
          mime: attachment.mime,
          ocrText: attachment.ocrText,
        ),
    ];
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ImagePreviewPage(
        images: images,
        store: _attachmentStore,
        initialIndex: index,
      ),
    ));
  }

  void _handleBack() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1600),
      ));
  }

  Future<void> _copyMessage(Message message) async {
    await Clipboard.setData(ClipboardData(text: message.content));
    _toast('已复制');
  }

  Future<void> _deleteMessage(Message message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('删除后该消息不再显示，可在数据中心统一管理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
                foregroundColor: context.bubbleColors.dangerDeep),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.softDeleteMessage(message.id);
    // 消息删除后联动取消其待投递通知（FR-IOS-06）
    await NotificationRuntime.dispatcher?.cancelForMessage(message.id);
  }

  Future<void> _showMessageActions(
    Message message,
    List<Message> messages,
    bool isLastAssistant,
  ) async {
    final session = _session;
    if (session == null) return;
    final generatingThis =
        session.generating && session.activeMessageId == message.id;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final semantic = sheetContext.bubbleColors;
        final surface = Theme.of(sheetContext).colorScheme.surface;

        Widget item({
          required IconData icon,
          required String label,
          Color? color,
          required VoidCallback onTap,
        }) {
          return ListTile(
            dense: true,
            leading: Icon(icon, size: 20, color: color),
            title: Text(
              label,
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                color: color,
              ),
            ),
            onTap: onTap,
          );
        }

        void run(VoidCallback action) {
          Navigator.pop(sheetContext);
          action();
        }

        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(BubbleRadius.card),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                item(
                  icon: Icons.copy_rounded,
                  label: '复制',
                  onTap: () => run(() => _copyMessage(message)),
                ),
                if (message.role == 'assistant' &&
                    message.status == MessageStatuses.sent &&
                    isLastAssistant)
                  item(
                    icon: Icons.refresh_rounded,
                    label: '重新生成',
                    onTap: () => run(() => session.regenerate(message.id)),
                  ),
                if (message.role == 'assistant' &&
                    message.status == MessageStatuses.interrupted)
                  item(
                    icon: Icons.play_arrow_rounded,
                    label: '继续生成',
                    onTap: () => run(() => session.resume(message.id)),
                  ),
                if (generatingThis)
                  item(
                    icon: Icons.stop_rounded,
                    label: '停止生成',
                    color: semantic.dangerDeep,
                    onTap: () => run(() => session.stop()),
                  ),
                if (message.status == MessageStatuses.failed)
                  item(
                    icon: Icons.refresh_rounded,
                    label: '重试',
                    onTap: () => run(() => session.retry(message.id)),
                  ),
                item(
                  icon: Icons.delete_outline_rounded,
                  label: '删除',
                  color: semantic.dangerDeep,
                  onTap: () => run(() => _deleteMessage(message)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showConversationMenu() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final semantic = sheetContext.bubbleColors;
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Theme.of(sheetContext).colorScheme.surface,
              borderRadius: BorderRadius.circular(BubbleRadius.card),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.edit_outlined, size: 20),
                  title: const Text('重命名会话'),
                  onTap: () => Navigator.pop(sheetContext, 'rename'),
                ),
                ListTile(
                  dense: true,
                  leading: Icon(Icons.delete_outline_rounded,
                      size: 20, color: semantic.dangerDeep),
                  title: Text('删除会话',
                      style: TextStyle(color: semantic.dangerDeep)),
                  onTap: () => Navigator.pop(sheetContext, 'delete'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;

    if (action == 'rename') {
      final title = await showRenameConversationDialog(context,
          initialTitle: _title ?? '');
      if (title == null || !mounted) return;
      await _repo.renameConversation(widget.conversationId, title);
      if (!mounted) return;
      setState(() => _title = title);
      return;
    }

    final deleted = await deleteConversationWithConfirm(
      context,
      repository: _repo,
      conversationId: widget.conversationId,
    );
    if (!mounted || !deleted) return;
    context.go('/');
  }

  Future<void> _openSearch() async {
    final messageId = await showDialog<String>(
      context: context,
      builder: (_) => _ConversationSearchDialog(
        repository: _repo,
        conversationId: widget.conversationId,
      ),
    );
    if (messageId == null || !mounted) return;
    await _focusMessage(messageId);
  }

  /// 搜索命中后定位：先按比例估算滚动，再 ensureVisible 精确定位。
  Future<void> _focusMessage(String messageId) async {
    _highlightTimer?.cancel();
    setState(() => _highlightId = messageId);
    _highlightTimer = Timer(const Duration(milliseconds: 2200), () {
      if (!mounted) return;
      setState(() {
        _highlightId = null;
        _messageKeys.clear();
      });
    });

    _stickToBottom = false;
    final messages = await _repo.messages(widget.conversationId);
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index >= 0 && _scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      final ratio =
          messages.length <= 1 ? 1.0 : index / (messages.length - 1);
      _scroll.jumpTo((max * ratio).clamp(0.0, max));
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final targetContext = _messageKeys[messageId]?.currentContext;
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 300),
        alignment: 0.35,
      );
    }
  }

  @override
  void dispose() {
    _highlightTimer?.cancel();
    _session?.removeListener(_onSessionChanged);
    _session?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final provider = _provider;
    final session = _session;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: _handleBack,
        ),
        title: Text(
          _title ?? '对话',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: '会话内搜索',
            icon: const Icon(Icons.search_rounded),
            onPressed: _openSearch,
          ),
          IconButton(
            tooltip: '会话设置',
            icon: const Icon(Icons.more_horiz_rounded),
            onPressed: _showConversationMenu,
          ),
        ],
      ),
      drawer: ConversationDrawer(
        repository: _repo,
        currentConversationId: widget.conversationId,
        provider: provider,
      ),
      body: provider == null || session == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (provider.isMock)
                  _MockModeBanner(
                    providerName: provider.displayName,
                    notice: _providerNotice,
                    onConfigure: () => context.push('/models'),
                  ),
                Expanded(
                  child: StreamBuilder<List<Attachment>>(
                    stream: _attachmentsStream,
                    builder: (context, attachmentSnapshot) {
                      final byMessage = <String, List<Attachment>>{};
                      for (final attachment in attachmentSnapshot.data ??
                          const <Attachment>[]) {
                        byMessage
                            .putIfAbsent(attachment.ownerId, () => [])
                            .add(attachment);
                      }
                      return StreamBuilder<List<Message>>(
                        stream: _messagesStream,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Center(
                              child: Text('消息加载失败',
                                  style: TextStyle(color: semantic.dangerDeep)),
                            );
                          }
                          if (!snapshot.hasData) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          final messages = snapshot.data!;
                          if (messages.isEmpty) return const _ChatEmptyState();

                          if (_stickToBottom) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted || !_scroll.hasClients) return;
                              _scroll.jumpTo(_scroll.position.maxScrollExtent);
                            });
                          }
                          // 通知深链：首帧后定位到目标消息并高亮
                          final focusId = _pendingFocusId;
                          if (focusId != null &&
                              messages.any((m) => m.id == focusId)) {
                            _pendingFocusId = null;
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _focusMessage(focusId);
                            });
                          }
                          return _buildMessageList(
                            messages,
                            byMessage,
                            provider,
                          );
                        },
                      );
                    },
                  ),
                ),
                if (session.pendingFailedCount > 0)
                  _FailedQueueBar(
                    count: session.pendingFailedCount,
                    onRetryAll: () async {
                      final retried = await session.retryAllFailed();
                      if (!mounted) return;
                      if (retried > 0) _toast('已重新生成 $retried 条消息');
                    },
                  ),
                if (_pendingImages.isNotEmpty)
                  _PendingImageStrip(
                    images: _pendingImages,
                    onRemove: _removePendingImage,
                  ),
                ChatInputBar(
                  controller: _input,
                  generating: session.generating,
                  canSend: _pendingImages.isNotEmpty,
                  onSend: _handleSend,
                  onStop: session.stop,
                  onAttachTap: _handleAttach,
                ),
              ],
            ),
    );
  }

  Widget _buildMessageList(
    List<Message> messages,
    Map<String, List<Attachment>> attachmentsByMessage,
    ChatCompletionProvider provider,
  ) {
    // 最后一条助手消息（「重新生成」只允许作用于它，保证 seq 顺序不乱）
    Message? lastAssistant;
    for (final m in messages) {
      if (m.role == 'assistant') lastAssistant = m;
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(top: 10, bottom: 10),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final previous = index > 0 ? messages[index - 1] : null;
        final currentTime = DateTime.tryParse(message.createdAt)?.toLocal();
        final previousTime =
            previous == null ? null : DateTime.tryParse(previous.createdAt)?.toLocal();

        final showDivider = currentTime != null &&
            needsTimeDivider(previousTime, currentTime);
        final sameSpeaker =
            previous != null && previous.role == message.role;
        final withinGroup = sameSpeaker &&
            previousTime != null &&
            currentTime != null &&
            currentTime.difference(previousTime).inMinutes < 3;

        final highlight = message.id == _highlightId;
        final key = highlight
            ? _messageKeys.putIfAbsent(message.id, () => GlobalKey())
            : null;
        final attachments =
            attachmentsByMessage[message.id] ?? const <Attachment>[];

        return Column(
          children: [
            if (showDivider)
              _TimeDivider(text: formatMessageTimestamp(message.createdAt)),
            Padding(
              padding: EdgeInsets.only(bottom: withinGroup ? 4 : 12),
              child: KeyedSubtree(
                key: key,
                child: MessageBubble(
                  message: message,
                  showAvatar: !withinGroup,
                  highlight: highlight,
                  attachments: attachments,
                  attachmentStore: _attachmentStore,
                  imageLocalBadge:
                      attachments.isNotEmpty && !provider.supportsVision
                          ? VisionCapability.badgeText(mock: provider.isMock)
                          : null,
                  onImageTap: attachments.isEmpty
                      ? null
                      : (index) => _openImagePreview(attachments, index),
                  onLongPress: () => _showMessageActions(
                    message,
                    messages,
                    lastAssistant?.id == message.id,
                  ),
                  onRetryTap: message.status == MessageStatuses.failed
                      ? () => _session?.retry(message.id)
                      : null,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 开发模式提示条（禁止把假模型伪装成真实功能）
class _MockModeBanner extends StatelessWidget {
  const _MockModeBanner({
    required this.providerName,
    this.notice,
    this.onConfigure,
  });

  final String providerName;
  final String? notice;
  final VoidCallback? onConfigure;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final text = notice == null || notice!.isEmpty
        ? '开发模式 · $providerName · 未接入真实模型'
        : '开发模式 · $notice';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: semantic.lavender.withValues(alpha: 0.14),
      child: Row(
        children: [
          Icon(Icons.science_outlined, size: 14, color: semantic.lavenderDeep),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: semantic.lavenderDeep,
              ),
            ),
          ),
          if (onConfigure != null)
            GestureDetector(
              onTap: onConfigure,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '去配置',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    fontWeight: FontWeight.w600,
                    color: semantic.lavenderDeep,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 失败消息队列（未发送队列）横幅
class _FailedQueueBar extends StatelessWidget {
  const _FailedQueueBar({required this.count, required this.onRetryAll});

  final int count;
  final VoidCallback onRetryAll;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Material(
      color: semantic.danger.withValues(alpha: 0.12),
      child: InkWell(
        onTap: onRetryAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 15, color: semantic.dangerDeep),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$count 条消息生成失败',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: semantic.dangerDeep,
                  ),
                ),
              ),
              Text(
                '全部重试',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  fontWeight: FontWeight.w600,
                  color: semantic.dangerDeep,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimeDivider extends StatelessWidget {
  const _TimeDivider({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Container(
        margin: const EdgeInsets.only(bottom: 10, top: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: semantic.surfaceAlt,
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            color: onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// 待发送图片缩略条（发送前可逐张移除）
class _PendingImageStrip extends StatelessWidget {
  const _PendingImageStrip({required this.images, required this.onRemove});

  final List<PickedImage> images;
  final void Function(int index) onRemove;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Container(
      key: const ValueKey('pending-image-strip'),
      height: 82,
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  images[index].bytes,
                  width: 66,
                  height: 66,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 66,
                    height: 66,
                    color: semantic.surfaceAlt,
                    child: Icon(Icons.broken_image_outlined,
                        size: 20, color: semantic.dangerDeep),
                  ),
                ),
              ),
              Positioned(
                right: -6,
                top: -6,
                child: GestureDetector(
                  key: ValueKey('pending-image-remove-$index'),
                  onTap: () => onRemove(index),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.2),
                    ),
                    child: const Icon(Icons.close_rounded,
                        size: 13, color: Colors.white),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ChatEmptyState extends StatelessWidget {
  const _ChatEmptyState();

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  semantic.lavender.withValues(alpha: 0.5),
                  semantic.bubbleUserB.withValues(alpha: 0.5),
                ],
              ),
            ),
            child: const Icon(Icons.cloud_rounded, size: 40, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Text('跟泡泡说声你好吧',
              style: TextStyle(
                fontSize: BubbleFontSize.body,
                fontWeight: FontWeight.w600,
                color: onSurface,
              )),
          const SizedBox(height: 6),
          Text('消息只存在这台设备上',
              style: TextStyle(
                fontSize: BubbleFontSize.secondary,
                color: onSurface.withValues(alpha: 0.45),
              )),
        ],
      ),
    );
  }
}

/// 会话内搜索弹层（T2.6）：bigram 过滤 + 结果定位
class _ConversationSearchDialog extends StatefulWidget {
  const _ConversationSearchDialog({
    required this.repository,
    required this.conversationId,
  });

  final ConversationRepository repository;
  final String conversationId;

  @override
  State<_ConversationSearchDialog> createState() =>
      _ConversationSearchDialogState();
}

class _ConversationSearchDialogState extends State<_ConversationSearchDialog> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<Message> _results = const [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => _runSearch(value),
    );
  }

  Future<void> _runSearch(String query) async {
    if (query.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final results =
        await widget.repository.searchMessages(widget.conversationId, query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 64),
      child: SizedBox(
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 6, 6),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 20, color: semantic.lavenderDeep),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      onChanged: _onChanged,
                      decoration: const InputDecoration(
                        hintText: '搜索这段对话',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Divider(color: semantic.stroke, height: 1),
            Expanded(
              child: _searching
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                      ? Center(
                          child: Text(
                            _controller.text.trim().isEmpty
                                ? '输入关键词，搜到后可定位到原消息'
                                : '没有找到相关消息',
                            style: TextStyle(
                              fontSize: BubbleFontSize.secondary,
                              color: onSurface.withValues(alpha: 0.45),
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: _results.length,
                          separatorBuilder: (_, _) =>
                              Divider(color: semantic.stroke, height: 1),
                          itemBuilder: (context, index) {
                            final message = _results[index];
                            return ListTile(
                              title: Text(
                                message.content,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: BubbleFontSize.bodySmall,
                                  color: onSurface,
                                ),
                              ),
                              subtitle: Text(
                                '${message.role == 'user' ? '你' : '泡泡'} · '
                                '${formatMessageTimestamp(message.createdAt)}',
                                style: TextStyle(
                                  fontSize: BubbleFontSize.badge,
                                  color: onSurface.withValues(alpha: 0.45),
                                ),
                              ),
                              onTap: () => Navigator.pop(context, message.id),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
