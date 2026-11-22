// 阶段 8 页面测试：设置主页主动性分组、决策中心候选池与执行记录。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/proactive/proactive_decision_center.dart';
import 'package:bubble/data/repositories/proactive_repository.dart';
import 'package:bubble/data/repositories/thinking_repository.dart';
import 'package:bubble/domain/proactive/proactive_models.dart';
import 'package:bubble/domain/thinking/thinking_models.dart';
import 'package:bubble/presentation/pages/proactive_center_page.dart';
import 'package:bubble/presentation/pages/settings_page.dart';
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
  late ProactiveRepository repo;
  late ThinkingRepository thinking;
  final now = DateTime(2026, 5, 20, 10, 0);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = ProactiveRepository(db, clock: () => now);
    thinking = ThinkingRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> insertCandidate({
    String draft = '想问问你今天过得怎么样',
    String dedupKey = 'chat:hello',
    int priority = 60,
  }) async {
    const id = 'cand_ui';
    await thinking.insertCandidate(
      id: id,
      insight: ThinkingInsight(
        kind: ThinkingResultKind.newConnection,
        content: draft,
        actionKind: ProactiveActionKind.chat,
        priority: priority,
        dedupKey: dedupKey,
        sourceKind: 'history_chat',
        title: '主动问候',
      ),
      relatedTaskId: 'task_ui',
      expiresAt: now.add(const Duration(days: 7)).millisecondsSinceEpoch,
    );
    return id;
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: BubbleTheme.light(), home: page),
    );
  }

  testWidgets('设置页展示三档并保存选择', (tester) async {
    await pumpPage(tester, SettingsPage(repository: repo));
    await pumpUntilFound(tester, find.text('泡泡的主动性'));

    expect(find.text('保守'), findsOneWidget);
    expect(find.text('均衡'), findsOneWidget);
    expect(find.text('积极'), findsOneWidget);
    expect(find.text('默认「积极」'), findsOneWidget);
    expect(find.text('硬限制始终生效'), findsOneWidget);

    await tester.tap(find.text('保守'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if ((await repo.loadSettings()).level == ProactivityLevel.conservative) {
        break;
      }
    }
    expect((await repo.loadSettings()).level, ProactivityLevel.conservative);

    // 关闭总开关（硬限制）
    await tester.tap(find.byType(SwitchListTile));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!(await repo.loadSettings()).enabled) break;
    }
    expect((await repo.loadSettings()).enabled, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('决策中心展示候选，运行后写入执行记录', (tester) async {
    await insertCandidate();
    final center = ProactiveDecisionCenter(
      db,
      repository: repo,
      clock: () => now,
      deliverer: (candidate) async =>
          const ProactiveDelivery(deliverableType: 'record', note: '界面测试投递'),
    );

    await pumpPage(
      tester,
      ProactiveCenterPage(repository: repo, center: center, clock: () => now),
    );
    await pumpUntilFound(tester, find.text('候选池（1）'));
    expect(find.text('主动问候'), findsWidgets);
    expect(find.text('立即执行'), findsOneWidget);

    await tester.tap(find.text('运行一次决策'));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('执行记录（最近 1 次）').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.textContaining('执行记录（最近 1 次）'), findsOneWidget);
    expect(find.text('候选池（0）'), findsOneWidget);
    expect(find.textContaining('今日已主动 1 / 6 次'), findsOneWidget);
    expect((await repo.recentActions()).length, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('关闭主动后决策中心显示硬限制提示', (tester) async {
    await repo.saveSettings(const ProactiveSettings(enabled: false));
    final center = ProactiveDecisionCenter(
      db,
      repository: repo,
      clock: () => now,
    );
    await pumpPage(
      tester,
      ProactiveCenterPage(repository: repo, center: center, clock: () => now),
    );
    await pumpUntilFound(tester, find.textContaining('你已关闭'));

    expect(find.textContaining('候选只会被记录，不会执行'), findsOneWidget);
    expect(find.text('还没有主动记录'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
