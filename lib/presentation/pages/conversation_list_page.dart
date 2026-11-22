// 首页 · 会话列表（T2.3）：会话卡片、未读徽章、左滑删除（范围确认）、
// 长按重命名/删除、新建会话入口。
// 依据 UI_PAGE_SPEC §A1、UI_INTERACTION_SPEC §7。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/repositories/conversation_repository.dart';
import '../theme/bubble_colors.dart';
import '../utils/time_format.dart';
import '../widgets/chat/conversation_actions.dart';

class ConversationListPage extends StatefulWidget {
  const ConversationListPage({super.key, this.repository});

  final ConversationRepository? repository;

  @override
  State<ConversationListPage> createState() => _ConversationListPageState();
}

class _ConversationListPageState extends State<ConversationListPage> {
  late final ConversationRepository _repo =
      widget.repository ?? ConversationRepository(AppDb.instance);
  late Stream<List<ConversationSummary>> _stream = _repo.watchConversations();

  Future<void> _openChat(String id) async {
    await context.push('/chat/$id');
    // 返回列表时刷新未读状态（进入聊天页已标记已读）
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _createConversation() async {
    final conv = await _repo.createConversation();
    if (!mounted) return;
    await _openChat(conv.id);
  }

  Future<void> _showItemActions(ConversationSummary item) async {
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
                  title: const Text('重命名'),
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
          initialTitle: item.title);
      if (title == null || !mounted) return;
      await _repo.renameConversation(item.id, title);
      return;
    }
    await deleteConversationWithConfirm(
      context,
      repository: _repo,
      conversationId: item.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 6, 2),
            child: Row(
              children: [
                Text('消息',
                    style: TextStyle(
                      fontSize: BubbleFontSize.pageTitle,
                      fontWeight: FontWeight.w700,
                      color: onSurface,
                    )),
                const Spacer(),
                IconButton(
                  tooltip: '全局搜索',
                  onPressed: () => context.push('/search'),
                  icon: const Icon(Icons.search_rounded),
                ),
                IconButton(
                  tooltip: '新建对话',
                  onPressed: _createConversation,
                  icon: Icon(Icons.add_circle_outline_rounded,
                      color: semantic.bubbleUserA),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<ConversationSummary>>(
              stream: _stream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _ErrorState(onRetry: () {
                    setState(() => _stream = _repo.watchConversations());
                  });
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final items = snapshot.data!;
                if (items.isEmpty) {
                  return _EmptyState(onStart: _createConversation);
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(top: 4, bottom: 90),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    return _buildCard(items[index]);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(ConversationSummary item) {
    final semantic = context.bubbleColors;
    final surface = Theme.of(context).colorScheme.surface;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final preview = item.lastContent == null
        ? '说点什么，让泡泡听见你'
        : '${item.lastRole == 'assistant' ? '泡泡' : '你'}：'
            '${item.lastContent!.replaceAll(RegExp(r'\s+'), ' ')}';

    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(
          color: item.sortWeight != null ? semantic.bubbleUserA : semantic.stroke,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: () => _openChat(item.id),
        onLongPress: () => _showItemActions(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              _DualAvatar(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: BubbleFontSize.cardTitle,
                              fontWeight: FontWeight.w600,
                              color: onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatConversationTime(item.lastMessageAt),
                          style: TextStyle(
                            fontSize: BubbleFontSize.badge,
                            color: onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: BubbleFontSize.secondary,
                              color: onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ),
                        if (item.unreadCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: semantic.bubbleUserA,
                              borderRadius:
                                  BorderRadius.circular(BubbleRadius.badge),
                            ),
                            child: Text(
                              item.unreadCount > 99 ? '99+' : '${item.unreadCount}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: BubbleFontSize.badge),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Dismissible(
      key: ValueKey('conversation-${item.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        padding: const EdgeInsets.only(right: 20),
        alignment: Alignment.centerRight,
        decoration: BoxDecoration(
          color: semantic.danger.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(BubbleRadius.card),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
      ),
      // 删除由对话框确认后执行；数据流移除条目，这里返回 false 避免双重移除
      confirmDismiss: (_) async {
        await deleteConversationWithConfirm(
          context,
          repository: _repo,
          conversationId: item.id,
        );
        return false;
      },
      child: card,
    );
  }
}

/// 双头像叠放：泡泡 + 你
class _DualAvatar extends StatelessWidget {
  const _DualAvatar();

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    Widget circle(List<Color> colors, IconData icon, {bool foreground = false}) {
      return Container(
        width: foreground ? 26 : 32,
        height: foreground ? 26 : 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: colors),
          border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
        ),
        child: Icon(icon, size: foreground ? 13 : 16, color: Colors.white),
      );
    }

    return SizedBox(
      width: 50,
      height: 40,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 2,
            child: circle([semantic.lavender, semantic.bubbleUserA], Icons.cloud_rounded),
          ),
          Positioned(
            left: 18,
            top: 12,
            child: circle(
              [semantic.bubbleUserA, semantic.bubbleUserB],
              Icons.person_rounded,
              foreground: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  semantic.lavender.withValues(alpha: 0.45),
                  semantic.bubbleUserB.withValues(alpha: 0.45),
                ],
              ),
            ),
            child: const Icon(Icons.cloud_queue_rounded,
                size: 44, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Text('还没有对话',
              style: TextStyle(
                fontSize: BubbleFontSize.body,
                fontWeight: FontWeight.w600,
                color: onSurface,
              )),
          const SizedBox(height: 6),
          Text('跟泡泡说声你好吧',
              style: TextStyle(
                fontSize: BubbleFontSize.secondary,
                color: onSurface.withValues(alpha: 0.5),
              )),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: onStart,
            child: const Text('开始对话'),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_off_rounded, size: 36, color: Colors.grey),
          const SizedBox(height: 10),
          const Text('会话加载失败'),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
