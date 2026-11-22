// 记忆域页面共用小组件（T5.4）：类型色点、徽章、日期与空态卡。
import 'package:flutter/material.dart';

import '../../../domain/memory/memory_models.dart';
import '../../theme/bubble_colors.dart';

/// 记忆类型语义色
Color memoryTypeColor(BuildContext context, String? type) {
  final semantic = context.bubbleColors;
  switch (type) {
    case 'profile':
      return semantic.mist;
    case 'preference':
      return semantic.lavender;
    case 'experience_joint':
      return semantic.bubbleUserA;
    case 'event':
      return semantic.success;
    case 'relationship':
      return semantic.pink;
    case 'agreement':
      return semantic.warn;
    case 'opinion':
      return semantic.lavenderDeep;
    case 'lesson':
      return semantic.successDeep;
    case 'project':
      return semantic.bubbleUserB;
    default:
      return semantic.pinkDeep;
  }
}

/// 小圆角徽章
class MemoryBadge extends StatelessWidget {
  const MemoryBadge({
    super.key,
    required this.text,
    required this.color,
    required this.background,
  });

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: BubbleFontSize.badge,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

/// 记忆日期展示：yyyy-MM-dd
String formatMemoryDate(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// 记忆日期时间展示：yyyy-MM-dd HH:mm
String formatMemoryDateTime(String? iso) {
  final date = formatMemoryDate(iso);
  final parsed = iso == null ? null : DateTime.tryParse(iso);
  if (parsed == null) return date;
  final local = parsed.toLocal();
  return '$date ${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// 空态卡
class MemoryEmptyCard extends StatelessWidget {
  const MemoryEmptyCard({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部说明条
class MemoryLockBar extends StatelessWidget {
  const MemoryLockBar(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt,
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 15, color: semantic.lavenderDeep),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 类型筛选 chips
class MemoryTypeFilter extends StatelessWidget {
  const MemoryTypeFilter({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final entries = <String?>[null, ...MemoryType.values.map((t) => t.wire)];
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final wire = entries[index];
          final active = selected == wire;
          final label =
              wire == null ? '全部' : MemoryType.labelOf(wire);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelected(wire),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: active
                    ? semantic.lavender.withValues(alpha: 0.22)
                    : semantic.surfaceAlt,
                borderRadius: BorderRadius.circular(BubbleRadius.badge),
                border: Border.all(
                  color: active ? semantic.lavender : Colors.transparent,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? semantic.lavenderDeep : onSurface.withValues(alpha: 0.65),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
