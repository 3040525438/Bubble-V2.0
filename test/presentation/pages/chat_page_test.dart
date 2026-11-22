// 聊天页组件测试（T2.2）：消息渲染、开发模式提示、发送后出现回复。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/presentation/pages/chat_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_provider.dart';

/// 反复 pump 直到目标出现（避免 pumpAndSettle 被加载动画卡住）
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 40,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppDatabase db;
  late ConversationRepository repo;
  late Conversation conv;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    repo = ConversationRepository(db);
    conv = await repo.createConversation(title: '测试会话');
  });

  tearDown(() async => db.close());

  Widget wrap(String conversationId) => MaterialApp(
        theme: BubbleTheme.light(),
        home: ChatPage(
          conversationId: conversationId,
          repository: repo,
          provider: FakeProvider(),
        ),
      );

  testWidgets('渲染历史消息与开发模式提示', (tester) async {
    await repo.appendUserMessage(conv.id, '你好呀');
    final assistant = await repo.beginAssistantMessage(conv.id);
    await repo.finishMessage(assistant.id, content: '我在呢');

    await tester.pumpWidget(wrap(conv.id));
    await pumpUntilFound(tester, find.text('我在呢'));

    expect(find.text('你好呀'), findsOneWidget);
    expect(find.text('我在呢'), findsOneWidget);
    expect(find.textContaining('开发模式'), findsOneWidget);
    expect(find.text('测试会话'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    // 让页面异步初始化与 drift watch 的收尾定时器走完，避免 pending timer 断言
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('发送消息后出现拆分的多条气泡', (tester) async {
    await tester.pumpWidget(wrap(conv.id));
    await pumpUntilFound(tester, find.byType(TextField));

    await tester.enterText(find.byType(TextField), '在吗');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await pumpUntilFound(tester, find.text('第二段回复内容'));

    expect(find.text('在吗'), findsOneWidget);
    expect(find.text('第一段回复内容'), findsOneWidget);
    expect(find.text('第二段回复内容'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
