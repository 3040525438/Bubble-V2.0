// 思考中心页面测试（T7.3）：手动思考、想法史展示与中断恢复入口。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/data/repositories/memory_repository.dart';
import 'package:bubble/data/repositories/thinking_repository.dart';
import 'package:bubble/data/thinking/thinking_orchestrator.dart';
import 'package:bubble/domain/thinking/thinking_models.dart';
import 'package:bubble/presentation/pages/thinking_center_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpUntilFound(WidgetTester tester, Finder finder,
    {int maxPumps = 160}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppDatabase db;
  late MemoryRepository memories;
  late ConversationRepository conversations;
  late ThinkingRepository thinking;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    memories = MemoryRepository(db);
    conversations = ConversationRepository(db);
    thinking = ThinkingRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('点“开始思考”跑完并展示想法', (tester) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await memories.createMemory(
      type: 'preference',
      title: '西湖散步',
      summary: '我喜欢在周末去西湖边散步',
      confidence: 'high',
    );
    await memories.createMemory(
      type: 'preference',
      title: '西湖跑步',
      summary: '我喜欢在周末去西湖边跑步',
      confidence: 'high',
    );
    await memories.createMemory(
      type: 'event',
      title: '搬家',
      summary: '今天搬家了，新家有个小阳台',
      confidence: 'high',
    );

    final orchestrator = ThinkingOrchestrator(
      db,
      repository: thinking,
      memories: memories,
      conversations: conversations,
    );

    await tester.pumpWidget(MaterialApp(
      theme: BubbleTheme.light(),
      home: ThinkingCenterPage(
        orchestrator: orchestrator,
        repository: thinking,
      ),
    ));
    await pumpUntilFound(tester, find.text('泡泡的思考'));
    await pumpUntilFound(tester, find.text('开始思考'));

    expect(find.text('让泡泡想想'), findsOneWidget);
    expect(find.text('还没有想法'), findsOneWidget);

    await tester.tap(find.text('开始思考'));
    for (var i = 0; i < 160; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('好像有联系').evaluate().isNotEmpty ||
          find.textContaining('拿出来聊聊').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.textContaining('好像有联系'), findsWidgets);
    expect(find.text('还没有想法'), findsNothing);
    expect(find.text('想法'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('未完成任务可一键恢复', (tester) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final event =
        await memories.createMemory(type: 'event', summary: '今天搬家了');
    final task = await thinking.createTask(
      trigger: 'app_resume',
      initialState: 'saving',
    );
    await thinking.updateTask(
      task.id,
      state: 'saving',
      checkpoint: ThinkingCheckpoint(
        step: 'saving',
        reviewedUntilMs: 0,
        insights: [
          ThinkingInsight(
            kind: ThinkingResultKind.shareWorthy,
            content: '这段经历也许可以拿出来聊聊：今天搬家了',
            relatedMemoryIds: [event.id],
          ),
        ],
      ),
    );

    final orchestrator = ThinkingOrchestrator(
      db,
      repository: thinking,
      memories: memories,
      conversations: conversations,
    );
    await tester.pumpWidget(MaterialApp(
      theme: BubbleTheme.light(),
      home: ThinkingCenterPage(
        orchestrator: orchestrator,
        repository: thinking,
      ),
    ));
    await pumpUntilFound(tester, find.textContaining('未完成的思考'));

    expect(find.text('恢复'), findsOneWidget);
    await tester.tap(find.text('恢复'));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final current = await thinking.getTask(task.id);
      if (current?.state == 'done') break;
    }
    expect((await thinking.getTask(task.id))!.state, 'done');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
