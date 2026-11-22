// 图片域模型单测（T12.1）：格式/大小校验、日期分组、筛选、视觉能力文案。
import 'package:bubble/domain/image/image_models.dart';
import 'package:flutter_test/flutter_test.dart';

GalleryImage image({
  required String id,
  required DateTime createdAt,
  String ownerKind = 'message',
  String relPath = 'Attachments/2026/05/a.png',
  String? ocrText,
}) {
  return GalleryImage(
    id: id,
    relPath: relPath,
    ownerKind: ownerKind,
    ownerId: 'owner-$id',
    createdAt: createdAt,
    ocrText: ocrText,
  );
}

void main() {
  group('图片格式与大小校验', () {
    test('常见图片扩展名 → MIME', () {
      expect(requireImageMime('a.JPG'), 'image/jpeg');
      expect(requireImageMime('照片.png'), 'image/png');
      expect(requireImageMime('b.heic'), 'image/heic');
      expect(requireImageMime('c.webp'), 'image/webp');
      expect(extensionOf('x.y.jpeg'), 'jpeg');
    });

    test('不支持的格式抛 UnsupportedImageException', () {
      expect(
        () => requireImageMime('movie.mp4'),
        throwsA(isA<UnsupportedImageException>()),
      );
      expect(
        () => requireImageMime('noext'),
        throwsA(isA<UnsupportedImageException>()),
      );
    });

    test('空内容与超限大小抛异常', () {
      expect(
        () => requireImageSize(0),
        throwsA(isA<UnsupportedImageException>()),
      );
      expect(
        () => requireImageSize(kMaxImageBytes + 1),
        throwsA(isA<ImageTooLargeException>()),
      );
      expect(() => requireImageSize(1024), returnsNormally);
    });
  });

  group('图片库分组与筛选', () {
    test('按日期倒序分组，同一天合并', () {
      final groups = groupGalleryByDay([
        image(id: '1', createdAt: DateTime(2026, 5, 20, 9)),
        image(id: '2', createdAt: DateTime(2026, 5, 21, 10)),
        image(id: '3', createdAt: DateTime(2026, 5, 21, 22)),
      ]);
      expect(groups.length, 2);
      expect(groups.first.dayKey, '2026-05-21');
      expect(groups.first.items.length, 2);
      expect(groups.last.dayKey, '2026-05-20');
    });

    test('分组标题：今天 / 昨天 / 具体日期', () {
      final now = DateTime(2026, 5, 22, 12);
      expect(
        GalleryGroup(dayKey: '2026-05-22', items: const []).title(now),
        '今天',
      );
      expect(
        GalleryGroup(dayKey: '2026-05-21', items: const []).title(now),
        '昨天',
      );
      expect(
        GalleryGroup(dayKey: '2026-05-20', items: const []).title(now),
        '2026年5月20日',
      );
    });

    test('月份键与筛选 copyWith/clear', () {
      final item = image(id: '1', createdAt: DateTime(2026, 5, 20, 9));
      expect(item.monthKey, '2026-05');
      const filter = GalleryFilter(ownerKind: 'post', monthKey: '2026-05');
      expect(filter.copyWith(clearMonth: true).monthKey, isNull);
      expect(filter.copyWith(clearOwnerKind: true).ownerKind, isNull);
      expect(filter.copyWith(ownerKind: 'diary').ownerKind, 'diary');
    });

    test('四个来源标签齐全', () {
      expect(AttachmentSource.gallerySources.map((s) => s.label), [
        '来自聊天',
        '来自说说',
        '来自日记',
        '来自信件',
      ]);
    });
  });

  group('视觉能力文案（FR-IMG-02）', () {
    test('不支持时明确告知图片仅本地保存', () {
      expect(VisionCapability.unsupportedNotice, contains('不支持看图'));
      expect(VisionCapability.unsupportedNotice, contains('泡泡看不到图片内容'));
      expect(VisionCapability.badgeText(mock: false), contains('仅本地'));
      expect(VisionCapability.badgeText(mock: true), contains('开发回声'));
      expect(VisionCapability.galleryFootnote, contains('仅本地存储'));
    });
  });
}
