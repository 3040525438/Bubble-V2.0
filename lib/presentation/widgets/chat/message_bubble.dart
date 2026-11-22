// 聊天气泡（T2.2/T12.2）：品牌双色气泡、头像左右、发送状态、失败/停止标注、生成中动效；
// 阶段 12 增加图片缩略图网格与「仅本地」能力徽章。
// 依据 UI_PAGE_SPEC §B5 与 UI_DESIGN_SYSTEM §4（气泡圆角 22、收口角 6）。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/attachment/attachment_store.dart';
import '../../../data/database/app_database.dart';
import '../../../domain/chat/chat_error.dart';
import '../../../domain/chat/message_status.dart';
import '../../theme/bubble_colors.dart';
import '../image/image_thumb.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.showAvatar = true,
    this.highlight = false,
    this.onLongPress,
    this.onRetryTap,
    this.attachments = const [],
    this.attachmentStore,
    this.onImageTap,
    this.imageLocalBadge,
  });

  final Message message;

  /// 连续消息（同一发言人 3 分钟内）合并头像
  final bool showAvatar;

  /// 搜索定位高亮（淡紫描边 1.5s）
  final bool highlight;

  final VoidCallback? onLongPress;

  /// 失败气泡点按重试
  final VoidCallback? onRetryTap;

  /// 消息图片（阶段 12，来自 attachments 表）
  final List<Attachment> attachments;

  /// 本地文件解析（未初始化时不渲染缩略图）
  final AttachmentStore? attachmentStore;

  /// 点击第 index 张图片（全屏预览）
  final void Function(int index)? onImageTap;

  /// 模型不支持视觉时的明确标注（FR-IMG-02；为空表示不显示）
  final String? imageLocalBadge;

  bool get _isUser => message.role == 'user';
  bool get _isFailed => message.status == MessageStatuses.failed;
  bool get _isStreaming => message.status == MessageStatuses.streaming;
  bool get _isInterrupted => message.status == MessageStatuses.interrupted;

  /// 仅图片消息不重复显示「[图片]」占位文本
  bool get _showText {
    final content = message.content.trim();
    if (content.isEmpty) return false;
    if (content == '[图片]' && attachments.isNotEmpty) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.72;

    final bubble = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: GestureDetector(
        onLongPress: onLongPress,
        onTap: _isFailed ? onRetryTap : null,
        child: Column(
          crossAxisAlignment:
              _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                gradient: _isUser
                    ? LinearGradient(colors: [
                        semantic.bubbleUserA,
                        semantic.bubbleUserB,
                      ])
                    : null,
                color: _isUser ? null : Theme.of(context).colorScheme.surface,
                borderRadius: _bubbleRadius(),
                border: Border.all(
                  color: _isFailed
                      ? semantic.danger
                      : (highlight
                          ? semantic.lavenderDeep
                          : (_isUser
                              ? Colors.transparent
                              : semantic.stroke)),
                  width: highlight ? 1.6 : 1,
                ),
                boxShadow: highlight
                    ? [
                        BoxShadow(
                          color: semantic.lavender.withValues(alpha: 0.35),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: _isUser
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (attachments.isNotEmpty) ...[
                    _AttachmentGrid(
                      attachments: attachments,
                      store: attachmentStore,
                      onTap: onImageTap,
                    ),
                    if (_showText) const SizedBox(height: 6),
                  ],
                  if (_isStreaming && message.content.isEmpty)
                    _TypingDots(color: semantic.lavenderDeep)
                  else if (_showText)
                    Text(
                      message.content,
                      style: TextStyle(
                        fontSize: BubbleFontSize.body,
                        height: 1.55,
                        color: _isUser
                            ? Colors.white
                            : Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  if (_statusIcon() != null) ...[
                    const SizedBox(height: 3),
                    _statusIcon()!,
                  ],
                ],
              ),
            ),
            if (attachments.isNotEmpty && (imageLocalBadge ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.visibility_off_outlined,
                      size: 12,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.45),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      imageLocalBadge!,
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
            if (_isInterrupted)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '已停止 · 长按可继续',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
            if (_isFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 13, color: semantic.dangerDeep),
                    const SizedBox(width: 3),
                    Text(
                      chatErrorText(message.errorCode),
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        color: semantic.dangerDeep,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            _isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: _isUser
            ? [
                Flexible(child: bubble),
                const SizedBox(width: 8),
                _BubbleAvatar(isUser: true, visible: showAvatar),
              ]
            : [
                _BubbleAvatar(isUser: false, visible: showAvatar),
                const SizedBox(width: 8),
                Flexible(child: bubble),
              ],
      ),
    );
  }

  BorderRadius _bubbleRadius() {
    const big = Radius.circular(BubbleRadius.bubble);
    const tail = Radius.circular(BubbleRadius.bubbleTail);
    return BorderRadius.only(
      topLeft: _isUser ? big : tail,
      topRight: _isUser ? tail : big,
      bottomLeft: big,
      bottomRight: big,
    );
  }

  /// 发送状态图标（仅用户消息：发送中/失败/已发送）
  Widget? _statusIcon() {
    if (!_isUser) return null;
    final color = Colors.white.withValues(alpha: 0.75);
    switch (message.status) {
      case MessageStatuses.sending:
        return Icon(Icons.schedule_rounded, size: 11, color: color);
      case MessageStatuses.failed:
        return const Icon(Icons.error_outline, size: 12, color: Colors.white);
      case MessageStatuses.sent:
        return Icon(Icons.check_rounded, size: 12, color: color);
      default:
        return null;
    }
  }
}

/// 消息图片网格：单图大图 / 2 列 / 3 列缩略图（点击全屏预览）
class _AttachmentGrid extends StatelessWidget {
  const _AttachmentGrid({
    required this.attachments,
    this.store,
    this.onTap,
  });

  final List<Attachment> attachments;
  final AttachmentStore? store;
  final void Function(int index)? onTap;

  @override
  Widget build(BuildContext context) {
    final store = this.store;
    if (store == null || !store.isReady) {
      return Text(
        '图片加载中…',
        style: TextStyle(
          fontSize: BubbleFontSize.badge,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = attachments.length;
        final columns = count == 1 ? 1 : (count == 2 ? 2 : 3);
        final width = constraints.maxWidth;
        final side = count == 1
            ? math.min(width, 200.0)
            : (width - (columns - 1) * 6) / columns;
        return Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < attachments.length; i++)
              SizedBox(
                width: side,
                height: side,
                child: ImageThumb(
                  store: store,
                  relPath: attachments[i].relPath,
                  borderRadius: 14,
                  onTap: onTap == null ? null : () => onTap!(i),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 头像：泡泡=淡紫渐变云朵，用户=天空蓝渐变小人
class _BubbleAvatar extends StatelessWidget {
  const _BubbleAvatar({required this.isUser, required this.visible});

  final bool isUser;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox(width: 34, height: 34);
    final semantic = context.bubbleColors;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isUser
              ? [semantic.bubbleUserA, semantic.bubbleUserB]
              : [semantic.lavender, semantic.bubbleUserA],
        ),
      ),
      child: Icon(
        isUser ? Icons.person_rounded : Icons.cloud_rounded,
        size: 17,
        color: Colors.white,
      ),
    );
  }
}

/// 生成中：三个漂浮小泡泡
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});

  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 18,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final phase = (_controller.value + i * 0.18) % 1.0;
              final dy = -2.4 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Transform.translate(
                  offset: Offset(0, dy),
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: widget.color.withValues(alpha: 0.55 + 0.35 * (1 - dy.abs() / 2.4)),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
