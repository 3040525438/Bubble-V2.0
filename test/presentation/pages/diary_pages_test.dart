// 阶段 11 日记页面测试：列表/月历切换、版本切换、整理今天。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/diary/diary_generator.dart';
import 'package:bubble/data/repositories/diary_repository.dart';
import 'package:bubble/domain/diary/diary_models.dart';
import 'package:bubble/presentation/pages/diary_detail_page.dart';
import 'package:bubble/presentation/pages/diary_page.dart';
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
  late DiaryRepository repo;
  final now = DateTime(2026, 5, 20, 21);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = DiaryRepository(db, clock: () => now);
  });

  tearDown(() async {
    await db.close();
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

  testWidgets('列表展示来源徽章，可切到月历并选中日期', (tester) async {
    await repo.createDiary(
      DiaryDraft(entryDate: DateTime(2026, 5, 20), content: '今天一起看了云'),
    );
    await repo.createDiary(
      DiaryDraft(
        entryDate: DateTime(2026, 5, 21),
        content: '我补写的一段',
        origin: DiaryOrigin.manual,
      ),
    );

    await pumpPage(tester, DiaryPage(repository: repo));
    await pumpUntilFound(tester, find.text('今天一起看了云'));

    expect(find.text('AI 整理'), findsOneWidget);
    expect(find.text('你补写'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('diary-view-calendar')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('2026年5月'), findsOneWidget);
    expect(find.byKey(const ValueKey('diary-day-20')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('diary-day-20')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('今天一起看了云'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('详情可以切换历史版本并回到当前版本', (tester) async {
    final diary = await repo.createDiary(
      DiaryDraft(entryDate: DateTime(2026, 5, 20), content: '最初的版本'),
    );
    await repo.updateDiary(diary.id, content: '改过的版本');

    await pumpPage(
      tester,
      DiaryDetailPage(diaryId: diary.id, repository: repo),
    );
    await pumpUntilFound(tester, find.text('改过的版本'));

    expect(find.text('版本记录'), findsOneWidget);
    expect(find.text('共 2 个版本'), findsOneWidget);
    expect(find.text('改过的版本'), findsWidgets);

    await tester.tap(find.text('v1'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('最初的版本'), findsWidgets);
    expect(find.textContaining('旧版本'), findsOneWidget);

    await tester.tap(find.text('当前 v2'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('改过的版本'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('整理今天生成预览并保存为日记', (tester) async {
    final generator = DiaryGenerator(db, repository: repo, clock: () => now);
    await pumpPage(tester, DiaryPage(repository: repo, generator: generator));
    await pumpUntilFound(tester, find.text('还没有日记'));

    await tester.tap(find.byKey(const ValueKey('diary-organize-today')));
    await pumpUntilFound(tester, find.text('整理今天的日记'));
    expect(find.text('本地整理'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await pumpUntilFound(tester, find.text('已写进今天的日记'));

    expect(await repo.countDiaries(), 1);
    expect(find.textContaining('2026年05月20日'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
