// 聊天输入条（T2.2）：图片入口 + 多行文本 + 发送/停止圆形按钮。
// 依据 UI_PAGE_SPEC §B5 与 UI_INTERACTION_SPEC §9（输入条按压最小点击区 44）。
import 'package:flutter/material.dart';

import '../../theme/bubble_colors.dart';

class ChatInputBar extends StatelessWidget {
  const ChatInputBar({
    super.key,
    required this.controller,
    required this.generating,
    required this.onSend,
    required this.onStop,
    this.onAttachTap,
    this.canSend = false,
  });

  final TextEditingController controller;
  final bool generating;
  final ValueChanged<String> onSend;
  final VoidCallback onStop;

  /// 图片入口（阶段 12：选图 → 本地保存 + 能力检测）
  final VoidCallback? onAttachTap;

  /// 无文字但有待发图片时也允许发送
  final bool canSend;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final surface = Theme.of(context).colorScheme.surface;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 10, 10),
        decoration: BoxDecoration(
          color: surface,
          border: Border(top: BorderSide(color: semantic.stroke)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              onPressed: onAttachTap,
              tooltip: '添加图片',
              icon: Icon(
                Icons.add_photo_alternate_outlined,
                color: onSurface.withValues(alpha: 0.55),
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: semantic.surfaceAlt,
                  borderRadius: BorderRadius.circular(BubbleRadius.inputBar),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(fontSize: BubbleFontSize.body, color: onSurface),
                  decoration: InputDecoration(
                    hintText: '和泡泡说点什么…',
                    hintStyle: TextStyle(
                      fontSize: BubbleFontSize.body,
                      color: onSurface.withValues(alpha: 0.4),
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                if (generating) {
                  return _CircleButton(
                    icon: Icons.stop_rounded,
                    color: semantic.danger,
                    tooltip: '停止生成',
                    onTap: onStop,
                  );
                }
                final hasText = value.text.trim().isNotEmpty;
                final enabled = hasText || canSend;
                return _CircleButton(
                  icon: Icons.arrow_upward_rounded,
                  color: enabled ? semantic.bubbleUserA : semantic.mist,
                  tooltip: '发送',
                  onTap: enabled ? () => onSend(controller.text) : null,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
