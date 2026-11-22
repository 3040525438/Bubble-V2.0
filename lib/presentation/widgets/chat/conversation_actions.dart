// 会话操作（T2.3）：重命名 / 删除范围确认。首页、抽屉、聊天页共用。
// 依据 UI_INTERACTION_SPEC §7（左滑或长按重命名/删除）与 DATABASE_DESIGN §2.1
// 删除策略（先选择消息处理范围）。
import 'package:flutter/material.dart';

import '../../../data/repositories/conversation_repository.dart';
import '../../theme/bubble_colors.dart';

/// 会话删除时消息的处理范围
enum DeleteConversationScope {
  /// 仅删会话（消息归档保留，可在数据中心恢复查看）
  keepMessages,

  /// 连消息一起删除
  deleteMessages,
}

/// 重命名对话框；返回新标题（取消返回 null）。
Future<String?> showRenameConversationDialog(
  BuildContext context, {
  required String initialTitle,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _RenameDialog(initialTitle: initialTitle),
  );
}

/// 删除范围选择（含取消）；返回 null 表示取消。
Future<DeleteConversationScope?> showDeleteConversationScopeDialog(
  BuildContext context,
) {
  return showDialog<DeleteConversationScope>(
    context: context,
    builder: (context) {
      final semantic = context.bubbleColors;
      return SimpleDialog(
        title: const Text('删除会话'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '请选择消息记录的处理方式。',
              style: TextStyle(
                fontSize: BubbleFontSize.secondary,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, DeleteConversationScope.keepMessages),
            child: const _ScopeRow(
              icon: Icons.inventory_2_outlined,
              title: '仅删除会话',
              subtitle: '消息记录保留归档',
            ),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.pop(context, DeleteConversationScope.deleteMessages),
            child: _ScopeRow(
              icon: Icons.delete_outline_rounded,
              title: '删除会话及全部消息',
              subtitle: '一并删除该会话的消息与附件',
              color: semantic.dangerDeep,
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 删除会话（先选范围）。返回是否已删除。
Future<bool> deleteConversationWithConfirm(
  BuildContext context, {
  required ConversationRepository repository,
  required String conversationId,
}) async {
  final scope = await showDeleteConversationScopeDialog(context);
  if (scope == null) return false;
  await repository.softDeleteConversation(
    conversationId,
    deleteMessages: scope == DeleteConversationScope.deleteMessages,
  );
  return true;
}

class _ScopeRow extends StatelessWidget {
  const _ScopeRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 20, color: tint),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: BubbleFontSize.body, color: tint)),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialTitle);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名会话'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 30,
        decoration: const InputDecoration(hintText: '输入会话名'),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
