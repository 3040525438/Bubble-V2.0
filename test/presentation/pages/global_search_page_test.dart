// 全局搜索页测试（T14.1）：搜索输入、分区命中展示与空态。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/search/global_search_repository.dart';
import 'package:bubble/presentation/pages/global_search_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
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
  late GlobalSearchRepository repo;
  final nowIso = DateTime.utc(2026, 11, 20).toIso8601String();

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    repo = GlobalSearchRepository(db);
    await db
        .into(db.memories)
        .insert(
          MemoriesCompanion.insert(
            id: 'mem_1',
            type: 'preference',
            title: const Value('咖啡偏好'),
            summary: '喜欢在周末去咖啡店看书',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
    await db
        .into(db.posts)
        .insert(
          PostsCompanion.insert(
            id: 'post_1',
            content: '今天路过咖啡店，想起你',
            publishedAt: 1000,
          ),
        );
    await repo.rebuildIndex();
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

  testWidgets('输入关键词展示分区命中', (tester) async {
    await pumpPage(tester, GlobalSearchPage(repository: repo));
    await tester.pump();

    expect(find.text('全局搜索'), findsOneWidget);
    expect(find.text('输入关键词开始搜索'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('global-search-field')), '咖啡');
    await tester.tap(find.byKey(const Key('global-search-submit')));

    await pumpUntilFound(
      tester,
      find.byKey(const Key('search-hit-memory-mem_1')),
    );
    expect(find.byKey(const Key('search-hit-memory-mem_1')), findsOneWidget);
    expect(find.byKey(const Key('search-hit-post-post_1')), findsOneWidget);
    expect(find.text('记忆'), findsOneWidget);
    expect(find.text('说说'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('无结果时展示空态', (tester) async {
    await pumpPage(tester, GlobalSearchPage(repository: repo));
    await tester.pump();

    await tester.enterText(
      find.byKey(const Key('global-search-field')),
      '完全不存在的词条',
    );
    await tester.tap(find.byKey(const Key('global-search-submit')));

    await pumpUntilFound(tester, find.text('没有找到匹配内容'));
    expect(find.text('没有找到匹配内容'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
