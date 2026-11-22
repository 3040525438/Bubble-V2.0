// 通知深链测试（T13.3）：focus 参数进入聊天后定位并高亮目标消息。
import 'dart:io';

import 'package:bubble/data/attachment/attachment_store.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/attachment_repository.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/presentation/pages/chat_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:bubble/presentation/widgets/chat/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_provider.dart';

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 100,
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
  late Message first;
  late Message second;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_deeplink_');
    store = AttachmentStore(root: root);
    attachments = AttachmentRepository(db, store: store);
    repo = ConversationRepository(db);
    conv = await repo.createConversation(title: '深链会话');
    first = await repo.appendUserMessage(conv.id, '在吗');
    second = await repo.appendAssistantSegment(conv.id, '我在的，刚刚在看云');
  });

  tearDown(() async {
    await db.close();
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Windows 句柄延迟释放，忽略临时目录清理失败
    }
  });

  testWidgets('focusMessageId 定位并高亮目标消息，随后自动取消高亮', (tester) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: BubbleTheme.light(),
        home: ChatPage(
          conversationId: conv.id,
          focusMessageId: second.id,
          repository: repo,
          provider: FakeProvider(),
          attachmentRepository: attachments,
          attachmentStore: store,
        ),
      ),
    );
    await pumpUntilFound(tester, find.byType(MessageBubble));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final bubbles = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    final target = bubbles.firstWhere((b) => b.message.id == second.id);
    final other = bubbles.firstWhere((b) => b.message.id == first.id);
    expect(target.highlight, isTrue);
    expect(other.highlight, isFalse);

    // 2.2 秒后自动取消高亮
    await tester.pump(const Duration(milliseconds: 2400));
    final after = tester
        .widgetList<MessageBubble>(find.byType(MessageBubble))
        .toList();
    expect(
      after.where((b) => b.message.id == second.id).single.highlight,
      isFalse,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
