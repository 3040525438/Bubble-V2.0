// 图片库（T12.2，UI_PAGE_SPEC §21）：来源筛选 chips + 日期分组 + 三列网格 +
// 全屏预览 + 长按跳来源/删除 + 图片文字搜索（OCR，D-5 未接入时明确标注）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/attachment/attachment_store.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../domain/image/image_models.dart';
import '../../domain/image/ocr_engine.dart';
import '../theme/bubble_colors.dart';
import '../widgets/image/image_thumb.dart';
import 'image_preview_page.dart';

class ImageGalleryPage extends StatefulWidget {
  const ImageGalleryPage({
    super.key,
    this.repository,
    this.store,
    this.ocrEngine,
    this.clock,
  });

  final AttachmentRepository? repository;
  final AttachmentStore? store;
  final OcrEngine? ocrEngine;
  final DateTime Function()? clock;

  @override
  State<ImageGalleryPage> createState() => _ImageGalleryPageState();
}

class _ImageGalleryPageState extends State<ImageGalleryPage> {
  late final AttachmentStore _store =
      widget.store ?? widget.repository?.store ?? AttachmentStore();
  late final AttachmentRepository _repo =
      widget.repository ?? AttachmentRepository(AppDb.instance, store: _store);
  late final OcrEngine _ocr = widget.ocrEngine ?? const UnavailableOcrEngine();
  DateTime Function() get _clock => widget.clock ?? DateTime.now;

  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;

  bool _loading = true;
  bool _searchVisible = false;
  String _query = '';
  String? _ownerKind;
  String? _monthKey;
  List<GalleryImage> _all = const [];
  List<GalleryImage> _searchResults = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _store.ensureReady();
    await _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final images = await _repo.galleryImages();
    final query = _query.trim();
    final results = query.isEmpty
        ? const <GalleryImage>[]
        : await _repo.searchByText(query);
    if (!mounted) return;
    setState(() {
      _all = images;
      _searchResults = results;
      _loading = false;
      // 删除后当前月份可能已无图片，重置为「全部月份」避免下拉框值失效
      if (_monthKey != null && !_months.contains(_monthKey)) _monthKey = null;
    });
  }

  /// 当前展示列表（来源 + 月份 + 搜索三条件叠加）
  List<GalleryImage> get _visible {
    final base = _query.trim().isEmpty ? _all : _searchResults;
    return [
      for (final image in base)
        if ((_ownerKind == null || image.ownerKind == _ownerKind) &&
            (_monthKey == null || image.monthKey == _monthKey))
          image,
    ];
  }

  List<String> get _months {
    final months = <String>{for (final image in _all) image.monthKey};
    final list = months.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () async {
      final query = value.trim();
      if (query.isEmpty) {
        if (!mounted) return;
        setState(() {
          _query = '';
          _searchResults = const [];
        });
        return;
      }
      final results = await _repo.searchByText(query);
      if (!mounted) return;
      setState(() {
        _query = query;
        _searchResults = results;
      });
    });
  }

  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _search.clear();
        _query = '';
        _searchResults = const [];
      }
    });
  }

  void _openPreview(List<GalleryImage> images, int index) {
    if (images.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImagePreviewPage(
          images: images,
          store: _store,
          initialIndex: index,
        ),
      ),
    );
  }

  Future<void> _showItemMenu(GalleryImage image) async {
    final source = AttachmentSource.gallerySources.firstWhere(
      (s) => s.kind == image.ownerKind,
      orElse: () => const AttachmentSource('other', '本地图片'),
    );
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final semantic = sheetContext.bubbleColors;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Material(
              color: Theme.of(sheetContext).colorScheme.surface,
              borderRadius: BorderRadius.circular(BubbleRadius.card),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    dense: true,
                    title: Text(
                      '${source.label} · ${image.dayKey}',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    subtitle: image.hasOcrText
                        ? Text(
                            '已识别图中文字',
                            style: TextStyle(
                              fontSize: BubbleFontSize.badge,
                              color: semantic.lavenderDeep,
                            ),
                          )
                        : null,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.open_in_new_rounded, size: 20),
                    title: const Text('查看来源'),
                    subtitle: image.ownerExists ? null : const Text('来源已删除'),
                    enabled: image.ownerExists,
                    onTap: image.ownerExists
                        ? () => Navigator.pop(sheetContext, 'open')
                        : null,
                  ),
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      size: 20,
                      color: semantic.dangerDeep,
                    ),
                    title: Text(
                      '删除这张图片',
                      style: TextStyle(color: semantic.dangerDeep),
                    ),
                    onTap: () => Navigator.pop(sheetContext, 'delete'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    if (action == 'open') {
      await _openSource(image);
    } else if (action == 'delete') {
      await _deleteImage(image);
    }
  }

  Future<void> _openSource(GalleryImage image) async {
    switch (image.ownerKind) {
      case 'message':
        final conversationId = await _repo.conversationIdOfMessage(
          image.ownerId,
        );
        if (!mounted) return;
        if (conversationId == null) {
          _toast('来源会话已删除');
          return;
        }
        context.push('/chat/$conversationId');
      case 'post':
        context.push('/post/${image.ownerId}');
      case 'diary':
        context.push('/diary/${image.ownerId}');
      case 'letter':
        context.push('/letters/${image.ownerId}');
      default:
        _toast('来源类型不支持跳转');
    }
  }

  Future<void> _deleteImage(GalleryImage image) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除图片'),
        content: const Text('将删除这张图片的本地文件与记录，来源消息仍会保留文字。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: context.bubbleColors.dangerDeep,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.softDelete(image.id, deleteFile: true);
    await _load();
    if (!mounted) return;
    _toast('图片已删除');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1600),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        ),
        title: const Text(
          '图片库',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            key: const ValueKey('gallery-search-toggle'),
            tooltip: '按图片文字搜索',
            icon: Icon(
              _searchVisible ? Icons.close_rounded : Icons.search_rounded,
            ),
            onPressed: _toggleSearch,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_searchVisible) _buildSearchBar(onSurface),
                _buildSourceChips(semantic),
                if (_months.length > 1) _buildMonthPicker(onSurface),
                Expanded(child: _buildBody(onSurface, semantic)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                  child: Text(
                    VisionCapability.galleryFootnote,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildSearchBar(Color onSurface) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: context.bubbleColors.surfaceAlt,
        borderRadius: BorderRadius.circular(BubbleRadius.inputBar),
      ),
      child: Row(
        children: [
          Icon(
            Icons.text_fields_rounded,
            size: 18,
            color: onSurface.withValues(alpha: 0.45),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('gallery-search-field'),
              controller: _search,
              onChanged: _onSearchChanged,
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                color: onSurface,
              ),
              decoration: InputDecoration(
                hintText: '按图中文字搜索',
                hintStyle: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  color: onSurface.withValues(alpha: 0.4),
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 11),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceChips(BubbleSemanticColors semantic) {
    final chips = <(String?, String)>[
      (null, '全部'),
      for (final source in AttachmentSource.gallerySources)
        (source.kind, source.label),
    ];
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (kind, label) = chips[index];
          final selected = _ownerKind == kind;
          return GestureDetector(
            key: ValueKey(
              kind == null ? 'gallery-filter-all' : 'gallery-filter-$kind',
            ),
            onTap: () => setState(() => _ownerKind = kind),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? semantic.lavenderDeep : semantic.surfaceAlt,
                borderRadius: BorderRadius.circular(BubbleRadius.badge),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? Colors.white
                      : Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.6),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMonthPicker(Color onSurface) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Text(
            '月份',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<String?>(
            key: const ValueKey('gallery-month'),
            value: _monthKey,
            underline: const SizedBox.shrink(),
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.7),
            ),
            items: [
              const DropdownMenuItem<String?>(value: null, child: Text('全部月份')),
              for (final month in _months)
                DropdownMenuItem<String?>(
                  value: month,
                  child: Text(month.replaceFirst('-', ' 年 ') + ' 月'),
                ),
            ],
            onChanged: (value) => setState(() => _monthKey = value),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Color onSurface, BubbleSemanticColors semantic) {
    final visible = _visible;
    if (visible.isEmpty) {
      final searching = _query.trim().isNotEmpty;
      final message = _all.isEmpty
          ? '还没有图片 · 在聊天里发一张试试'
          : searching
          ? (_ocr.isAvailable
                ? '没有找到包含这段文字的图片'
                : VisionCapability.ocrUnavailableNotice)
          : '这个筛选下还没有图片';
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 46,
                color: onSurface.withValues(alpha: 0.25),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: BubbleFontSize.secondary,
                  color: onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final groups = groupGalleryByDay(visible);
    final now = _clock();
    return ListView.builder(
      key: const ValueKey('gallery-grid'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      itemCount: groups.length,
      itemBuilder: (context, groupIndex) {
        final group = groups[groupIndex];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: semantic.surfaceAlt,
                  borderRadius: BorderRadius.circular(BubbleRadius.badge),
                ),
                child: Text(
                  group.title(now),
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
              ),
              itemCount: group.items.length,
              itemBuilder: (context, index) {
                final image = group.items[index];
                final globalIndex = visible.indexOf(image);
                return GestureDetector(
                  key: ValueKey('gallery-item-${image.id}'),
                  onLongPress: () => _showItemMenu(image),
                  child: ImageThumb(
                    store: _store,
                    relPath: image.relPath,
                    onTap: () => _openPreview(visible, globalIndex),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
