// 阶段 11 信件页面测试：筛选、草稿寄出、冷却提示与写信校验。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/letter/letter_generator.dart';
import 'package:bubble/data/repositories/letter_repository.dart';
import 'package:bubble/domain/letter/letter_models.dart';
import 'package:bubble/presentation/pages/letter_compose_page.dart';
import 'package:bubble/presentation/pages/letter_detail_page.dart';
import 'package:bubble/presentation/pages/letters_page.dart';
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
  late LetterRepository repo;
  final now = DateTime(2026, 5, 20, 10);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = LetterRepository(db, clock: () => now);
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

  testWidgets('信件列表按筛选隐藏已寄出的信', (tester) async {
    await repo.createDraft(
      const LetterDraft(
        direction: LetterDirection.userToBubble,
        content: '还没寄出的信',
      ),
    );
    await repo.createAndSend(
      const LetterDraft(
        direction: LetterDirection.bubbleToUser,
        content: '泡泡寄来的信',
      ),
    );

    await pumpPage(tester, LettersPage(repository: repo));
    await pumpUntilFound(tester, find.text('泡泡寄来的信'));

    expect(find.text('还没寄出的信'), findsOneWidget);
    expect(find.text('已寄出'), findsOneWidget);
    expect(find.text('草稿'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('letter-filter-drafts')));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('泡泡寄来的信').evaluate().isEmpty) break;
    }
    expect(find.text('还没寄出的信'), findsOneWidget);
    expect(find.text('泡泡寄来的信'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('草稿详情可以寄出并切换为已寄出状态', (tester) async {
    final draft = await repo.createDraft(
      const LetterDraft(
        direction: LetterDirection.userToBubble,
        content: '想和你说说今天的事',
      ),
    );

    await pumpPage(
      tester,
      LetterDetailPage(letterId: draft.id, repository: repo),
    );
    await pumpUntilFound(tester, find.text('寄出这封信'));

    await tester.tap(find.text('寄出这封信'));
    await pumpUntilFound(tester, find.text('再读一遍'));

    expect(find.text('已寄出'), findsOneWidget);
    expect(
      LetterState.fromWire((await repo.getLetter(draft.id))!.state),
      LetterState.sent,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('冷却期内「让泡泡写」提示 7 天间隔', (tester) async {
    await repo.createAndSend(
      const LetterDraft(
        direction: LetterDirection.bubbleToUser,
        content: '第一封信',
      ),
    );
    final generator = LetterGenerator(db, repository: repo, clock: () => now);

    await pumpPage(tester, LettersPage(repository: repo, generator: generator));
    await pumpUntilFound(tester, find.text('第一封信'));

    await tester.tap(find.byKey(const ValueKey('letter-ask-bubble')));
    await pumpUntilFound(tester, find.textContaining('7 天'));

    expect(find.textContaining('7 天'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('写信页空内容时不提交并提示', (tester) async {
    await pumpPage(tester, LetterComposePage(repository: repo));
    await pumpUntilFound(tester, find.text('寄出这封信'));

    await tester.tap(find.text('寄出这封信'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('先写点什么，再寄出'), findsOneWidget);
    expect(await repo.countLetters(), 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
