// 图片库与全屏预览页面测试（T12.2）：网格、来源筛选、长按菜单、OCR 搜索提示、多图预览。
import 'dart:io';
import 'dart:typed_data';

import 'package:bubble/data/attachment/attachment_store.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/attachment_repository.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/domain/image/image_models.dart';
import 'package:bubble/presentation/pages/image_gallery_page.dart';
import 'package:bubble/presentation/pages/image_preview_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 160,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppDatabase db;
  late Directory root;
  late AttachmentStore store;
  late AttachmentRepository attachments;
  late Conversation conv;
  late Message message;

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_gallery_');
    store = AttachmentStore(root: root);
    await store.ensureReady();
    attachments = AttachmentRepository(db, store: store);
    final conversations = ConversationRepository(db);
    conv = await conversations.createConversation(title: '图片会话');
    message = await conversations.appendUserMessage(conv.id, '[图片]');
  });

  tearDown(() async {
    await db.close();
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Windows 下图片文件句柄可能延迟释放，忽略临时目录清理失败
    }
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: BubbleTheme.light(), home: page),
    );
  }

  testWidgets('空态：没有图片时给出引导', (tester) async {
    await pumpPage(
      tester,
      ImageGalleryPage(repository: attachments, store: store),
    );
    await pumpUntilFound(tester, find.textContaining('还没有图片'));
    expect(find.textContaining('还没有图片'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('三列网格 + 来源筛选 + 长按删除图片', (tester) async {
    // 真实文件写入必须在 runAsync 中执行（testWidgets 默认 FakeAsync 不推进真实 IO）
    late final Attachment chatImage;
    late final Attachment postImage;
    await tester.runAsync(() async {
      chatImage = await attachments.addImage(
        ownerKind: 'message',
        ownerId: message.id,
        bytes: bytes([1, 2]),
        fileName: 'chat.png',
      );
      postImage = await attachments.addImage(
        ownerKind: 'post',
        ownerId: 'post-x',
        bytes: bytes([3, 4]),
        fileName: 'post.png',
        ocrText: '奶茶店收据',
      );
    });

    await pumpPage(
      tester,
      ImageGalleryPage(repository: attachments, store: store),
    );
    await pumpUntilFound(
      tester,
      find.byKey(ValueKey('gallery-item-${chatImage.id}')),
    );
    expect(
      find.byKey(ValueKey('gallery-item-${chatImage.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey('gallery-item-${postImage.id}')),
      findsOneWidget,
    );

    // 来源筛选：来自说说
    await tester.tap(find.byKey(const ValueKey('gallery-filter-post')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(
      find.byKey(ValueKey('gallery-item-${postImage.id}')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('gallery-item-${chatImage.id}')), findsNothing);

    // 长按 → 菜单 → 删除（确认）
    await tester.longPress(
      find.byKey(ValueKey('gallery-item-${postImage.id}')),
    );
    await pumpUntilFound(tester, find.text('查看来源'));
    await tester.pump(const Duration(milliseconds: 400)); // 等待底部菜单动画到位
    expect(find.text('删除这张图片'), findsOneWidget);
    await tester.tap(find.text('删除这张图片'));
    await tester.pump(const Duration(milliseconds: 500)); // 关闭菜单并弹出确认框
    expect(find.text('删除图片'), findsOneWidget);

    await tester.tap(find.text('删除'));
    // 删除包含真实文件 IO：先让真实事件循环推进，再 pump 完成 UI 刷新
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await pumpUntilFound(tester, find.textContaining('这个筛选下还没有图片'));

    final remaining = await tester.runAsync(
      () => attachments.galleryImages(ownerKind: 'post'),
    );
    expect(remaining, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('图片文字搜索：无 OCR 结果时明确标注未接入', (tester) async {
    await tester.runAsync(() async {
      await attachments.addImage(
        ownerKind: 'message',
        ownerId: message.id,
        bytes: bytes([5]),
        fileName: 'a.png',
      );
    });
    await pumpPage(
      tester,
      ImageGalleryPage(repository: attachments, store: store),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('gallery-search-toggle')),
    );

    await tester.tap(find.byKey(const ValueKey('gallery-search-toggle')));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.enterText(
      find.byKey(const ValueKey('gallery-search-field')),
      '不存在的文字',
    );
    await pumpUntilFound(
      tester,
      find.textContaining('图片文字识别尚未接入'),
      maxPumps: 200,
    );
    expect(find.textContaining('图片文字识别尚未接入'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('全屏预览：计数随翻页变化，缺失文件明确提示', (tester) async {
    final now = DateTime(2026, 5, 20, 10);
    final images = [
      GalleryImage(
        id: 'i1',
        relPath: 'Attachments/2026/05/missing1.png',
        ownerKind: 'message',
        ownerId: message.id,
        createdAt: now,
      ),
      GalleryImage(
        id: 'i2',
        relPath: 'Attachments/2026/05/missing2.png',
        ownerKind: 'message',
        ownerId: message.id,
        createdAt: now,
      ),
    ];
    await pumpPage(tester, ImagePreviewPage(images: images, store: store));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('image-preview-count')))
          .data,
      '1/2',
    );
    expect(find.textContaining('文件缺失'), findsWidgets);

    await tester.drag(find.byType(PageView), const Offset(-800, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('image-preview-count')))
          .data,
      '2/2',
    );

    expect(find.byKey(const ValueKey('image-preview-close')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
