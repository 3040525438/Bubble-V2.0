// 阶段 9 页面测试：共同经历时间线与详情（双视角、回顾只追加）。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/experience_repository.dart';
import 'package:bubble/domain/experience/experience_models.dart';
import 'package:bubble/presentation/pages/experience_detail_page.dart';
import 'package:bubble/presentation/pages/timeline_page.dart';
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
  late ExperienceRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = ExperienceRepository(db, clock: () => DateTime(2026, 5, 20, 10, 0));
  });

  tearDown(() async {
    await db.close();
  });

  Future<SharedExperience> create() async {
    final created = await repo.createExperience(
      ExperienceDraft(
        name: '第一次一起看雪',
        occurredAtMs: DateTime(2025, 12, 20, 18, 30).millisecondsSinceEpoch,
        eventContent: '那天我们在西湖边看到今年第一场雪',
        importance: 80,
        userPerspective: '我觉得很浪漫',
        bubblePerspective: '雪花落在你的肩上，很安静',
      ),
    );
    await repo.appendReview(
      created.id,
      ExperienceReviewEntry(
        atMs: DateTime(2026, 1, 1).millisecondsSinceEpoch,
        content: '后来每次下雪都会想起那天',
        author: 'bubble',
      ),
    );
    return (await repo.getExperience(created.id))!;
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

  testWidgets('时间线展示经历、双视角与回顾计数', (tester) async {
    await create();
    await pumpPage(tester, TimelinePage(repository: repo));
    await pumpUntilFound(tester, find.text('第一次一起看雪'));

    expect(find.text('共同经历'), findsOneWidget);
    expect(find.text('你的视角'), findsOneWidget);
    expect(find.text('泡泡的视角'), findsOneWidget);
    expect(find.text('回顾 1 次'), findsOneWidget);
    expect(find.text('从记忆里发现'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('详情页展示历史事实锁条与两种视角', (tester) async {
    final created = await create();
    await pumpPage(
      tester,
      ExperienceDetailPage(experienceId: created.id, repository: repo),
    );
    await pumpUntilFound(tester, find.text('第一次一起看雪'));

    expect(find.textContaining('那天我们在西湖边看到今年第一场雪'), findsOneWidget);
    expect(find.textContaining('历史事实不可修改'), findsOneWidget);
    expect(find.text('我觉得很浪漫'), findsOneWidget);
    expect(find.text('雪花落在你的肩上，很安静'), findsOneWidget);
    expect(find.textContaining('回顾记录（1）'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('补充视角只改视角不改历史事实', (tester) async {
    final created = await create();
    await pumpPage(
      tester,
      ExperienceDetailPage(experienceId: created.id, repository: repo),
    );
    await pumpUntilFound(tester, find.text('你的视角'));

    await tester.tap(find.text('编辑').first);
    await pumpUntilFound(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField).last, '那天的冷现在还记得');
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final row = await repo.getExperience(created.id);
      if (row?.userPerspective == '那天的冷现在还记得') break;
    }

    final row = (await repo.getExperience(created.id))!;
    expect(row.userPerspective, '那天的冷现在还记得');
    expect(row.name, '第一次一起看雪');
    expect(row.eventContent, '那天我们在西湖边看到今年第一场雪');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('追加回顾后计数增加且旧记录保留', (tester) async {
    final created = await create();
    await pumpPage(
      tester,
      ExperienceDetailPage(experienceId: created.id, repository: repo),
    );
    await pumpUntilFound(tester, find.text('泡泡补'));

    await tester.tap(find.text('泡泡补'));
    await pumpUntilFound(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField).last, '今天又想起那场雪');
    await tester.tap(find.text('追加'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('回顾记录（2）').evaluate().isNotEmpty) break;
    }

    expect(find.textContaining('回顾记录（2）'), findsOneWidget);
    final row = (await repo.getExperience(created.id))!;
    final entries = ExperienceRules.parseReviewLog(row.reviewLog);
    expect(entries.length, 2);
    expect(entries.first.content, contains('后来每次下雪'));
    expect(entries.last.content, '今天又想起那场雪');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
