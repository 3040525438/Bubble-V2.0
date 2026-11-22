// 图片缩略图（T12.2）：本地文件渲染 + 文件缺失占位（不假装图片存在）。
import 'package:flutter/material.dart';

import '../../../data/attachment/attachment_store.dart';
import '../../../domain/image/image_models.dart';
import '../../theme/bubble_colors.dart';

class ImageThumb extends StatelessWidget {
  const ImageThumb({
    super.key,
    required this.store,
    required this.relPath,
    this.width,
    this.height,
    this.borderRadius = 12,
    this.onTap,
    this.fit = BoxFit.cover,
  });

  final AttachmentStore store;
  final String relPath;
  final double? width;
  final double? height;
  final double borderRadius;
  final VoidCallback? onTap;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final missing = !store.isReady || !store.exists(relPath);
    Widget child;
    if (missing) {
      child = _MissingPlaceholder(
        width: width,
        height: height,
        borderRadius: borderRadius,
      );
    } else {
      child = ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.file(
          store.fileOf(relPath),
          width: width,
          height: height,
          fit: fit,
          errorBuilder: (_, _, _) => _MissingPlaceholder(
            width: width,
            height: height,
            borderRadius: borderRadius,
          ),
        ),
      );
    }
    if (onTap == null) return child;
    return GestureDetector(onTap: onTap, child: child);
  }
}

class _MissingPlaceholder extends StatelessWidget {
  const _MissingPlaceholder({
    this.width,
    this.height,
    required this.borderRadius,
  });

  final double? width;
  final double? height;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Container(
      width: width ?? 96,
      height: height ?? 96,
      decoration: BoxDecoration(
        color: semantic.surfaceAlt,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: semantic.stroke),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 20,
            color: semantic.dangerDeep.withValues(alpha: 0.8),
          ),
          const SizedBox(height: 2),
          Text(
            kImageMissingText,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: semantic.dangerDeep,
            ),
          ),
        ],
      ),
    );
  }
}
