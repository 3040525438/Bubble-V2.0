// 聊天页发图交互测试（T12.2）：能力提示 → 选图 → 待发缩略条 → 发送后气泡显示图片。
import 'dart:convert';
import 'dart:io';

import 'package:bubble/data/attachment/attachment_store.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/attachment_repository.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/presentation/chat/image_picker_service.dart';
import 'package:bubble/presentation/pages/chat_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_provider.dart';

/// 1x1 合法 PNG（保证 Image.memory 能解码）
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class FakeImagePicker implements ImagePickerService {
  FakeImagePicker(this.images);

  final List<PickedImage> images;
  int calls = 0;

  @override
  Future<List<PickedImage>> pickImages() async {
    calls++;
    return images;
  }
}

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 120,
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
  late ConversationRepository repo;
  late Conversation conv;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_chat_image_page_');
    store = AttachmentStore(root: root);
    await store.ensureReady();
    attachments = AttachmentRepository(db, store: store);
    repo = ConversationRepository(db);
    conv = await repo.createConversation(title: '发图会话');
  });

  tearDown(() async {
    await db.close();
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Windows 下图片文件句柄可能延迟释放，忽略临时目录清理失败
    }
  });

  testWidgets('不支持视觉时先提示，确认后选图并发送图片消息', (tester) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final picker = FakeImagePicker([
      PickedImage(bytes: _pngBytes, fileName: 'cloud.png'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: BubbleTheme.light(),
        home: ChatPage(
          conversationId: conv.id,
          repository: repo,
          provider: FakeProvider(),
          attachmentRepository: attachments,
          attachmentStore: store,
          imagePicker: picker,
        ),
      ),
    );
    await pumpUntilFound(tester, find.byTooltip('添加图片'));

    // 点击图片入口 → 能力提示（FR-IMG-02）
    await tester.tap(find.byTooltip('添加图片'));
    await pumpUntilFound(tester, find.text('当前模型不支持看图'));
    expect(find.textContaining('泡泡看不到图片内容'), findsOneWidget);

    await tester.tap(find.text('仍要添加'));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('pending-image-strip')),
    );
    expect(picker.calls, 1);
    expect(find.byKey(const ValueKey('pending-image-strip')), findsOneWidget);

    // 发送（无文字，仅有图片）
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    // 落盘是真实文件 IO：交替 pump（推进微任务）与 runAsync（推进真实 IO）
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    await pumpUntilFound(tester, find.text('第一段回复内容'));

    final messages = (await tester.runAsync(() => repo.messages(conv.id)))!;
    final user = messages.firstWhere((m) => m.role == 'user');
    expect(user.content, '[图片]');
    final images = (await tester.runAsync(
      () => attachments.attachmentsOf('message', user.id),
    ))!;
    expect(images.length, 1);

    // 待发条清空，气泡内不再显示「[图片]」占位文本
    expect(find.byKey(const ValueKey('pending-image-strip')), findsNothing);
    expect(find.text('[图片]'), findsNothing);
    expect(find.textContaining('仅本地'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('待发图片可逐张移除', (tester) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final picker = FakeImagePicker([
      PickedImage(bytes: _pngBytes, fileName: 'a.png'),
      PickedImage(bytes: _pngBytes, fileName: 'b.png'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        theme: BubbleTheme.light(),
        home: ChatPage(
          conversationId: conv.id,
          repository: repo,
          provider: FakeProvider(),
          attachmentRepository: attachments,
          attachmentStore: store,
          imagePicker: picker,
        ),
      ),
    );
    await pumpUntilFound(tester, find.byTooltip('添加图片'));

    await tester.tap(find.byTooltip('添加图片'));
    await pumpUntilFound(tester, find.text('仍要添加'));
    await tester.tap(find.text('仍要添加'));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey('pending-image-remove-1')),
    );

    await tester.tap(find.byKey(const ValueKey('pending-image-remove-0')));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byKey(const ValueKey('pending-image-remove-1')), findsNothing);
    expect(
      find.byKey(const ValueKey('pending-image-remove-0')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
