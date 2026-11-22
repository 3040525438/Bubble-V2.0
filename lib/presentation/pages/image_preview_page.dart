// 图片全屏预览（T12.2，UI_PAGE_SPEC §32）：深色覆盖层 + 左右滑多图 + 计数。
// 手势约定（UI_INTERACTION_SPEC）：预览态使用独立页面，避免与聊天页左滑返回冲突。
import 'package:flutter/material.dart';

import '../../data/attachment/attachment_store.dart';
import '../../domain/image/image_models.dart';

class ImagePreviewPage extends StatefulWidget {
  const ImagePreviewPage({
    super.key,
    required this.images,
    required this.store,
    this.initialIndex = 0,
  });

  final List<GalleryImage> images;
  final AttachmentStore store;
  final int initialIndex;

  @override
  State<ImagePreviewPage> createState() => _ImagePreviewPageState();
}

class _ImagePreviewPageState extends State<ImagePreviewPage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.images.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _sourceLabel(String kind) {
    for (final source in AttachmentSource.gallerySources) {
      if (source.kind == kind) return source.label;
    }
    return '本地图片';
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.images.length;
    final current = total == 0 ? null : widget.images[_index];
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        backgroundColor: const Color(0xFF0E1116),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const ValueKey('image-preview-close'),
                      tooltip: '关闭',
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                      ),
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const Spacer(),
                    Text(
                      total == 0 ? '0/0' : '${_index + 1}/$total',
                      key: const ValueKey('image-preview-count'),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                      ),
                    ),
                    const Spacer(),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Expanded(
                child: total == 0
                    ? const Center(
                        child: Text(
                          '没有可预览的图片',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : PageView.builder(
                        controller: _controller,
                        itemCount: total,
                        onPageChanged: (value) =>
                            setState(() => _index = value),
                        itemBuilder: (context, index) {
                          final image = widget.images[index];
                          if (!widget.store.isReady ||
                              !widget.store.exists(image.relPath)) {
                            return const Center(
                              child: Text(
                                '文件缺失 · 可能已被外部清理',
                                style: TextStyle(color: Colors.white54),
                              ),
                            );
                          }
                          return InteractiveViewer(
                            minScale: 1,
                            maxScale: 4,
                            child: Center(
                              child: Image.file(
                                widget.store.fileOf(image.relPath),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => const Center(
                                  child: Text(
                                    '图片无法打开',
                                    style: TextStyle(color: Colors.white54),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (current != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '${_sourceLabel(current.ownerKind)} · '
                        '${current.dayKey}',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                      if (current.hasOcrText) ...[
                        const SizedBox(width: 8),
                        const Icon(
                          Icons.text_snippet_outlined,
                          size: 13,
                          color: Colors.white38,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
