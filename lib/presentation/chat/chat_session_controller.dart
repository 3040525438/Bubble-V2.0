// 聊天会话控制器（T2.4/T2.5）：发送 → 流式 → 分段落定 / 停止 / 重试 / 继续，
// 以及失败消息队列（未发送队列）与中断恢复。
// 设计说明：消息事实一律写库，UI 通过 drift watch 渲染，避免内存与库不一致；
// 本控制器只负责「生成流水线」这一临时状态。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../data/database/app_database.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/model_repository.dart';
import '../../domain/chat/bubble_splitter.dart';
import '../../domain/chat/chat_error.dart';
import '../../domain/chat/chat_provider.dart';
import '../../domain/chat/message_status.dart';
import '../../domain/image/image_models.dart';

/// 上下文组装回调（阶段 6）：把原始会话历史装配为含 system 的消息列表。
typedef ContextAssemblerCallback = Future<List<ChatTurn>> Function(
    List<ChatTurn> history);

/// 待发送图片（阶段 12）：仅内存传递，落盘由附件仓储负责。
class OutgoingImage {
  const OutgoingImage({required this.bytes, required this.fileName});

  final Uint8List bytes;
  final String fileName;
}

class ChatSessionController extends ChangeNotifier {
  ChatSessionController({
    required this.repository,
    required this.provider,
    required this.conversationId,
    this.modelRepository,
    this.attachmentRepository,
    this.contextAssembler,
    this.scene = 'chat',
  });

  final ConversationRepository repository;
  final ChatCompletionProvider provider;
  final String conversationId;

  /// 用量记账仓储（真实模型接入后提供；假模型为空）
  final ModelRepository? modelRepository;

  /// 附件仓储（阶段 12：图片消息落盘与绑定）
  final AttachmentRepository? attachmentRepository;

  /// 上下文组装（人格 + 记忆）；为空时直接使用原始历史
  final ContextAssemblerCallback? contextAssembler;

  /// 用量场景（chat/thinking/proactive...）
  final String scene;

  /// 是否正在生成（输入条显示停止键）
  bool generating = false;

  /// 正在生成的助手消息 id
  String? activeMessageId;

  /// 失败消息条数（未发送队列）
  int pendingFailedCount = 0;

  /// 最近一次生成错误（供 UI 提示）
  String? lastError;

  final StringBuffer _buffer = StringBuffer();
  StreamSubscription<String>? _sub;
  Timer? _flushTimer;
  int _generation = 0;
  bool _disposed = false;
  Completer<void>? _generationCompleter;

  /// 打开会话时调用：先收敛悬挂状态，再统计失败队列。
  Future<void> load() async {
    await repository.recoverUnfinishedMessages(conversationId: conversationId);
    await refreshFailedQueue();
  }

  Future<void> refreshFailedQueue() async {
    final list = await repository.failedMessages(conversationId);
    pendingFailedCount = list.length;
    _notify();
  }

  /// 发送用户消息并开始生成。
  Future<void> send(String raw) => sendWithImages(raw, const []);

  /// 发送文字 + 图片（阶段 12）。
  ///
  /// 图片先落盘并绑定到用户消息；模型不支持视觉时明确降级为纯文字
  /// （图片仅本地保存，不放入请求体，FR-IMG-02）。
  Future<void> sendWithImages(String raw, List<OutgoingImage> images) async {
    final text = raw.trim();
    if ((text.isEmpty && images.isEmpty) || generating) return;
    if (images.length > kMaxImagesPerMessage) {
      throw ArgumentError('一条消息最多 ${kMaxImagesPerMessage} 张图片');
    }
    // 先做无 IO 的格式/大小校验，避免消息写完才发现图片不可用
    for (final image in images) {
      requireImageMime(image.fileName);
      requireImageSize(image.bytes.length);
    }

    lastError = null;
    final content = text.isEmpty ? '[图片]' : text;
    await repository.ensureTitleFromMessage(conversationId, content);
    final userMessage = await repository.appendUserMessage(conversationId, content);
    await _attachImages(userMessage.id, images);
    final assistant = await repository.beginAssistantMessage(conversationId);
    await _startGeneration(
      assistant.id,
      images: provider.supportsVision
          ? [
              for (final image in images)
                ChatImagePart(
                  mime: requireImageMime(image.fileName),
                  bytes: image.bytes,
                ),
            ]
          : const [],
    );
  }

  /// 图片落盘并绑定到消息（失败不影响已落库的文字消息，错误交给 UI 提示）
  Future<void> _attachImages(String messageId, List<OutgoingImage> images) async {
    final repo = attachmentRepository;
    if (repo == null || images.isEmpty) return;
    for (final image in images) {
      await repo.addImage(
        ownerKind: 'message',
        ownerId: messageId,
        messageId: messageId,
        bytes: image.bytes,
        fileName: image.fileName,
      );
    }
  }

  /// 停止生成：保留半成品（interrupted）；若一个字都没生成则删掉占位气泡。
  Future<void> stop() async {
    if (!generating) return;
    final messageId = activeMessageId;
    _generation++; // 使已排队的回调失效
    await _sub?.cancel();
    _sub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    final content = _buffer.toString().trim();
    if (messageId != null) {
      if (content.isEmpty) {
        await repository.hardDeleteMessage(messageId);
      } else {
        await repository.interruptMessage(messageId, content: content);
      }
    }
    _buffer.clear();
    _completeGeneration();
  }

  /// 重试失败消息：复用同一消息与 request_id（幂等，不重复落库）。
  Future<void> retry(String messageId) async {
    if (generating) return;
    final msg = await repository.getMessage(messageId);
    if (msg == null || msg.status != MessageStatuses.failed) return;
    await repository.resetForRetry(messageId);
    await _startGeneration(messageId);
  }

  /// 重新生成最后一条已发送的助手消息（软删旧消息后在同一位置重新生成）。
  Future<void> regenerate(String messageId) async {
    if (generating) return;
    final all = await repository.messages(conversationId);
    Message? lastAssistant;
    for (final m in all) {
      if (m.role == 'assistant') lastAssistant = m;
    }
    if (lastAssistant == null || lastAssistant.id != messageId) return;
    await repository.softDeleteMessage(messageId);
    final assistant = await repository.beginAssistantMessage(conversationId);
    await _startGeneration(assistant.id);
  }

  /// 继续生成被停止的消息（新建 continuation 气泡，原消息保持「已停止」）。
  Future<void> resume(String messageId) async {
    if (generating) return;
    final msg = await repository.getMessage(messageId);
    if (msg == null || msg.status != MessageStatuses.interrupted) return;
    final cont = await repository.beginAssistantMessage(
      conversationId,
      messageKind: MessageKinds.continuation,
    );
    await _startGeneration(cont.id);
  }

  /// 重试全部失败消息（串行，逐条等待生成结束）。
  Future<int> retryAllFailed() async {
    final list = await repository.failedMessages(conversationId);
    var count = 0;
    for (final msg in list) {
      if (_disposed || generating) break;
      await retry(msg.id);
      count++;
      final completer = _generationCompleter;
      if (completer != null) await completer.future;
    }
    return count;
  }

  Future<void> _startGeneration(
    String messageId, {
    List<ChatImagePart> images = const [],
  }) async {
    final token = ++_generation;
    _buffer.clear();
    generating = true;
    activeMessageId = messageId;
    _generationCompleter = Completer<void>();
    _notify();

    await repository.updateMessageContent(messageId, '',
        status: MessageStatuses.streaming);
    final history = await repository.history(conversationId);

    var payload = history;
    final assembler = contextAssembler;
    if (assembler != null) {
      try {
        payload = await assembler(history);
      } catch (_) {
        // 上下文失败不阻断聊天：回退原始历史（人格/记忆属增强项）
        payload = history;
      }
    }
    // 图片只随本轮最后一条用户消息发送（历史图片以 [图片] 文本呈现，控制请求体积）
    if (images.isNotEmpty) {
      payload = _attachImagesToLastUserTurn(payload, images);
    }
    if (token != _generation || _disposed) return;

    _sub = provider.stream(payload).listen(
      (chunk) {
        if (token != _generation || _disposed) return;
        _buffer.write(chunk);
        _scheduleFlush(messageId);
      },
      onError: (Object error, StackTrace stack) {
        if (token != _generation || _disposed) return;
        _failGeneration(messageId, error);
      },
      onDone: () {
        if (token != _generation || _disposed) return;
        _finishGeneration(messageId, token);
      },
      cancelOnError: true,
    );
  }

  /// 把图片附到本轮最后一条用户消息上（system/历史消息保持文本）
  List<ChatTurn> _attachImagesToLastUserTurn(
    List<ChatTurn> turns,
    List<ChatImagePart> images,
  ) {
    final index = turns.lastIndexWhere((turn) => turn.role == 'user');
    if (index < 0) return turns;
    final updated = [...turns];
    final turn = updated[index];
    updated[index] = ChatTurn(
      role: 'user',
      content: turn.content,
      images: images,
    );
    return updated;
  }

  /// 流式增量节流写库（80ms），避免每 chunk 一次事务。
  void _scheduleFlush(String messageId) {
    _flushTimer ??= Timer(const Duration(milliseconds: 80), () async {
      _flushTimer = null;
      if (_disposed || !generating) return;
      await repository.updateMessageContent(messageId, _buffer.toString());
    });
  }

  Future<void> _finishGeneration(String messageId, int token) async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final content = _buffer.toString().trim();
    if (content.isEmpty) {
      await repository.failMessage(messageId, errorCode: ChatErrorCodes.emptyReply);
    } else {
      // 连续多气泡：首段落原消息，其余段依次（150ms 间隔）独立落库
      final segments = splitReplySegments(content);
      await repository.finishMessage(messageId, content: segments.first);
      await _applyUsage(messageId);
      for (var i = 1; i < segments.length; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (_disposed || token != _generation) return;
        await repository.appendAssistantSegment(conversationId, segments[i]);
      }
    }
    _completeGeneration();
  }

  /// 落库 Token 用量与思考链，并按天记账（T3.2）。
  Future<void> _applyUsage(String messageId) async {
    final usage = provider.lastUsage;
    if (usage == null) return;
    await repository.applyMessageUsage(
      messageId,
      usage: usage,
      modelId: provider.modelId,
      reasoning: provider.lastReasoning,
    );
    final modelId = provider.modelId;
    final ledger = modelRepository;
    if (modelId != null && ledger != null) {
      await ledger.recordUsage(modelId: modelId, scene: scene, usage: usage);
    }
  }

  Future<void> _failGeneration(String messageId, Object error) async {
    _flushTimer?.cancel();
    _flushTimer = null;
    lastError = error.toString();
    await repository.failMessage(
      messageId,
      errorCode: errorCodeOf(error),
      errorDetail: error.toString(),
      content: _buffer.toString().trim(),
    );
    _completeGeneration();
  }

  void _completeGeneration() {
    if (_disposed) return;
    generating = false;
    activeMessageId = null;
    _buffer.clear();
    final completer = _generationCompleter;
    _generationCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
    _notify();
    unawaited(refreshFailedQueue());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _sub?.cancel();
    final completer = _generationCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
    super.dispose();
  }
}
