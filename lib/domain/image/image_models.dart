// 图片系统领域模型（FR-IMG-01/02）：来源、类型校验、图片库分组、视觉能力提示。
// 说明：attachments 表为唯一事实来源；本层只做无副作用的数据整理与校验。

/// 附件来源（与 attachments.owner_kind 的 UI 可见子集对应）
class AttachmentSource {
  const AttachmentSource(this.kind, this.label);

  final String kind; // message / post / diary / letter
  final String label; // 中文展示名

  static const message = AttachmentSource('message', '来自聊天');
  static const post = AttachmentSource('post', '来自说说');
  static const diary = AttachmentSource('diary', '来自日记');
  static const letter = AttachmentSource('letter', '来自信件');

  /// 图片库筛选顺序（全部由 null 表示）
  static const gallerySources = <AttachmentSource>[
    message,
    post,
    diary,
    letter,
  ];
}

/// 支持的图片扩展名（html/webp/gif 仅预览，不做理解）
const kSupportedImageExtensions = <String>{
  'jpg',
  'jpeg',
  'png',
  'heic',
  'heif',
  'webp',
  'gif',
};

/// 单张图片大小上限（20MB，避免误选视频/超大图拖垮存储）
const kMaxImageBytes = 20 * 1024 * 1024;

/// 单条消息最多图片数（多图分析上限）
const kMaxImagesPerMessage = 6;

/// 文件扩展名（小写，不含点）
String extensionOf(String fileName) {
  final name = fileName.trim();
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 扩展名 → MIME（未知返回 null）
String? imageMimeOfExtension(String ext) {
  switch (ext.toLowerCase()) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'heic':
      return 'image/heic';
    case 'heif':
      return 'image/heif';
    case 'webp':
      return 'image/webp';
    case 'gif':
      return 'image/gif';
    default:
      return null;
  }
}

/// 校验并返回 MIME；不支持的类型抛 [UnsupportedImageException]。
String requireImageMime(String fileName) {
  final ext = extensionOf(fileName);
  if (!kSupportedImageExtensions.contains(ext)) {
    throw UnsupportedImageException('不支持的图片格式：${ext.isEmpty ? '未知' : ext}');
  }
  return imageMimeOfExtension(ext) ?? 'image/jpeg';
}

/// 校验图片字节数；超限抛 [ImageTooLargeException]。
void requireImageSize(int sizeBytes) {
  if (sizeBytes <= 0) {
    throw const UnsupportedImageException('图片内容为空');
  }
  if (sizeBytes > kMaxImageBytes) {
    throw const ImageTooLargeException('图片超过 20MB，请先压缩再发送');
  }
}

/// 不支持的图片类型
class UnsupportedImageException implements Exception {
  const UnsupportedImageException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 图片过大
class ImageTooLargeException implements Exception {
  const ImageTooLargeException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 图片库条目（attachments 一行 + 来源是否仍存在）
class GalleryImage {
  const GalleryImage({
    required this.id,
    required this.relPath,
    required this.ownerKind,
    required this.ownerId,
    required this.createdAt,
    this.mime,
    this.width,
    this.height,
    this.ocrText,
    this.aiCaption,
    this.ownerExists = true,
  });

  final String id;
  final String relPath;
  final String ownerKind;
  final String ownerId;
  final DateTime createdAt; // 本地时间
  final String? mime;
  final int? width;
  final int? height;
  final String? ocrText;
  final String? aiCaption;

  /// 来源记录是否仍存在（用于长按跳来源时提示已删除）
  final bool ownerExists;

  bool get hasOcrText => (ocrText ?? '').trim().isNotEmpty;

  /// 本地日期键 yyyy-MM-dd（日期分组用）
  String get dayKey =>
      '${createdAt.year.toString().padLeft(4, '0')}-'
      '${createdAt.month.toString().padLeft(2, '0')}-'
      '${createdAt.day.toString().padLeft(2, '0')}';

  /// 月份键 yyyy-MM
  String get monthKey =>
      '${createdAt.year.toString().padLeft(4, '0')}-'
      '${createdAt.month.toString().padLeft(2, '0')}';

  GalleryImage copyWith({bool? ownerExists}) => GalleryImage(
    id: id,
    relPath: relPath,
    ownerKind: ownerKind,
    ownerId: ownerId,
    createdAt: createdAt,
    mime: mime,
    width: width,
    height: height,
    ocrText: ocrText,
    aiCaption: aiCaption,
    ownerExists: ownerExists ?? this.ownerExists,
  );
}

/// 图片库分组（同一天一组）
class GalleryGroup {
  const GalleryGroup({required this.dayKey, required this.items});

  final String dayKey;
  final List<GalleryImage> items;

  /// 分组标题：今天 / 昨天 / 2026年5月20日
  String title(DateTime now) {
    final parts = dayKey.split('-');
    if (parts.length != 3) return dayKey;
    final date = DateTime(
      int.tryParse(parts[0]) ?? 1970,
      int.tryParse(parts[1]) ?? 1,
      int.tryParse(parts[2]) ?? 1,
    );
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(date.year, date.month, date.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${date.year}年${date.month}月${date.day}日';
  }
}

/// 按日期倒序分组（输入应为 createdAt 倒序或乱序均可）
List<GalleryGroup> groupGalleryByDay(List<GalleryImage> images) {
  final buckets = <String, List<GalleryImage>>{};
  final sorted = [...images]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  for (final image in sorted) {
    buckets.putIfAbsent(image.dayKey, () => []).add(image);
  }
  return [
    for (final entry in buckets.entries)
      GalleryGroup(dayKey: entry.key, items: entry.value),
  ];
}

/// 图片库筛选条件（来源 + 月份，均为空表示全部）
class GalleryFilter {
  const GalleryFilter({this.ownerKind, this.monthKey});

  final String? ownerKind;
  final String? monthKey;

  bool get isEmpty => ownerKind == null && monthKey == null;

  GalleryFilter copyWith({
    String? ownerKind,
    String? monthKey,
    bool clearOwnerKind = false,
    bool clearMonth = false,
  }) {
    return GalleryFilter(
      ownerKind: clearOwnerKind ? null : (ownerKind ?? this.ownerKind),
      monthKey: clearMonth ? null : (monthKey ?? this.monthKey),
    );
  }
}

/// 视觉能力提示文案（FR-IMG-02：不支持时明确提示，不假装支持）
class VisionCapability {
  const VisionCapability({required this.supported});

  final bool supported;

  /// 聊天输入区选图前的提示（不支持时的弹窗正文）
  static const unsupportedNotice =
      '当前模型不支持看图。图片会保存在这台设备上，你可以预览和删除，'
      '但泡泡看不到图片内容，只会收到文字。\n\n'
      '想让她真正理解图片，请在模型管理里启用支持视觉能力的模型。';

  /// 图片消息气泡下的徽章文案
  static String badgeText({required bool mock}) =>
      mock ? '仅本地 · 开发回声看不到图片' : '仅本地 · 当前模型看不到图片';

  /// 图片库底部说明
  static const galleryFootnote = '点按大图预览（左滑多图）· 长按跳来源 · 仅本地存储';

  /// OCR 未接入时的明确标注（D-5 方案待确认）
  static const ocrUnavailableNotice = '图片文字识别尚未接入 · 暂不可按图中文字搜索';
}

/// 文件缺失占位文案（附件完整性异常，不假装图片存在）
const kImageMissingText = '文件缺失';
