// 多会话抽屉（T2.3）：会话切换 / 新建 / 重命名 / 删除范围确认。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../data/repositories/conversation_repository.dart';
import '../../../domain/chat/chat_provider.dart';
import '../../theme/bubble_colors.dart';
import '../../utils/time_format.dart';
import 'conversation_actions.dart';

class ConversationDrawer extends StatefulWidget {
  const ConversationDrawer({
    super.key,
    required this.repository,
    required this.currentConversationId,
    this.provider,
  });

  final ConversationRepository repository;
  final String currentConversationId;
  final ChatCompletionProvider? provider;

  @override
  State<ConversationDrawer> createState() => _ConversationDrawerState();
}

class _ConversationDrawerState extends State<ConversationDrawer> {
  late final Stream<List<ConversationSummary>> _stream =
      widget.repository.watchConversations();

  void _switchTo(String id) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop(); // 关闭抽屉
    if (id != widget.currentConversationId) {
      router.pushReplacement('/chat/$id');
    }
  }

  Future<void> _createConversation() async {
    final conv = await widget.repository.createConversation();
    if (!mounted) return;
    _switchTo(conv.id);
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
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('重命名'),
                  onTap: () => Navigator.pop(sheetContext, 'rename'),
                ),
                ListTile(
                  leading: Icon(Icons.delete_outline_rounded,
                      color: semantic.dangerDeep),
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
      await widget.repository.renameConversation(item.id, title);
      return;
    }

    final deleted = await deleteConversationWithConfirm(
      context,
      repository: widget.repository,
      conversationId: item.id,
    );
    if (!mounted || !deleted) return;
    if (item.id == widget.currentConversationId) {
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      router.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Drawer(
      width: 304,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  Text('对话',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: onSurface,
                      )),
                  const Spacer(),
                  IconButton(
                    onPressed: _createConversation,
                    tooltip: '新建对话',
                    icon: Icon(Icons.add_circle_outline_rounded,
                        color: semantic.bubbleUserA),
                  ),
                ],
              ),
            ),
            Divider(color: semantic.stroke, height: 1),
            Expanded(
              child: StreamBuilder<List<ConversationSummary>>(
                stream: _stream,
                builder: (context, snapshot) {
                  final list = snapshot.data ?? const <ConversationSummary>[];
                  if (snapshot.hasError) {
                    return Center(
                      child: Text('会话加载失败',
                          style: TextStyle(color: semantic.dangerDeep)),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (list.isEmpty) {
                    return Center(
                      child: Text('还没有对话',
                          style: TextStyle(
                              fontSize: BubbleFontSize.secondary,
                              color: onSurface.withValues(alpha: 0.5))),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: list.length,
                    itemBuilder: (context, index) {
                      final item = list[index];
                      final selected = item.id == widget.currentConversationId;
                      return ListTile(
                        selected: selected,
                        selectedTileColor: semantic.surfaceAlt,
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: BubbleFontSize.bodySmall,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400,
                          ),
                        ),
                        subtitle: item.lastContent == null
                            ? null
                            : Text(
                                item.lastContent!.replaceAll('\n', ' '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: BubbleFontSize.badge,
                                  color: onSurface.withValues(alpha: 0.45),
                                ),
                              ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (item.unreadCount > 0)
                              Container(
                                margin: const EdgeInsets.only(right: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: semantic.bubbleUserA,
                                  borderRadius:
                                      BorderRadius.circular(BubbleRadius.badge),
                                ),
                                child: Text(
                                  '${item.unreadCount}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: BubbleFontSize.badge),
                                ),
                              ),
                            Text(
                              formatConversationTime(item.lastMessageAt),
                              style: TextStyle(
                                fontSize: BubbleFontSize.badge,
                                color: onSurface.withValues(alpha: 0.4),
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _switchTo(item.id),
                        onLongPress: () => _showItemActions(item),
                      );
                    },
                  );
                },
              ),
            ),
            Divider(color: semantic.stroke, height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '长按会话可重命名或删除',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.35),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
