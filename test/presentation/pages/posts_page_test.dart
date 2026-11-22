// 阶段 10 页面测试：说说瀑布流与筛选、详情编辑历史、生成器本地预览。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/post/post_generator.dart';
import 'package:bubble/data/repositories/post_repository.dart';
import 'package:bubble/domain/post/post_models.dart';
import 'package:bubble/presentation/pages/post_detail_page.dart';
import 'package:bubble/presentation/pages/post_generator_page.dart';
import 'package:bubble/presentation/pages/posts_page.dart';
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
  late PostRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = PostRepository(db, clock: () => DateTime(2026, 5, 20, 10, 0));
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
      MaterialApp(
        theme: BubbleTheme.light(),
        home: Scaffold(body: page),
      ),
    );
  }

  testWidgets('说说列表展示内容与心情筛选', (tester) async {
    await repo.createPost(
      const PostDraft(content: '今天想你了，路过那家咖啡店', mood: PostMood.mood),
    );
    await repo.createPost(
      const PostDraft(content: '今天把阳台的花浇了一遍', mood: PostMood.daily),
    );

    await pumpPage(tester, PostsPage(repository: repo));
    await pumpUntilFound(tester, find.textContaining('咖啡店'));

    expect(find.text('说说'), findsOneWidget);
    expect(find.text('写一篇'), findsOneWidget);
    expect(find.textContaining('阳台的花'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mood-filter-daily')));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('咖啡店').evaluate().isEmpty) break;
    }
    expect(find.textContaining('阳台的花'), findsOneWidget);
    expect(find.textContaining('咖啡店'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('说说详情展示来源与编辑历史', (tester) async {
    final post = await repo.createPost(
      const PostDraft(content: '最初的版本', mood: PostMood.thought),
    );
    await repo.updatePost(post.id, content: '改过的版本');

    await pumpPage(tester, PostDetailPage(postId: post.id, repository: repo));
    await pumpUntilFound(tester, find.text('改过的版本'));

    expect(find.textContaining('泡泡自主生成'), findsOneWidget);
    expect(find.text('编辑历史'), findsOneWidget);
    expect(find.textContaining('生成'), findsWidgets);
    expect(find.textContaining('你手动改'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('生成器本地生成后展示「本地草稿」标注', (tester) async {
    final generator = PostGenerator(db, repository: repo);
    await pumpPage(tester, PostGeneratorPage(generator: generator));
    await pumpUntilFound(tester, find.text('自主生成'));

    await tester.tap(find.text('生成一篇'));
    await pumpUntilFound(tester, find.text('本地草稿'));

    expect(find.text('本地草稿'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('发布这篇'), findsOneWidget);
    expect(
      (tester.widget<TextField>(find.byType(TextField).last))
          .controller
          ?.text
          .isNotEmpty,
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
