// 说说仓储单测（T10.1）：发布、筛选、编辑历史、软删除与去重数据源。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/post_repository.dart';
import 'package:bubble/domain/post/post_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PostRepository repo;
  final now = DateTime(2026, 5, 20, 10, 0);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = PostRepository(db, clock: () => now);
  });

  tearDown(() async {
    await db.close();
  });

  Future<Post> create({
    String content = '今天想你了',
    PostMood? mood = PostMood.mood,
    PostOrigin origin = PostOrigin.autonomous,
    String? topic,
  }) {
    return repo.createPost(
      PostDraft(content: content, mood: mood, origin: origin, topic: topic),
    );
  }

  group('发布与列表', () {
    test('发布后可按时间倒序列出', () async {
      final first = await create(content: '第一条');
      final second = await create(content: '第二条', mood: PostMood.daily);
      final list = await repo.listPosts();
      expect(list.length, 2);
      expect(list.first.id, second.id);
      expect(list.last.id, first.id);
      expect(await repo.countPosts(), 2);
    });

    test('心情筛选只返回对应心情', () async {
      await create(content: '心情说说', mood: PostMood.mood);
      await create(content: '日常说说', mood: PostMood.daily);
      final filtered = await repo.listPosts(mood: PostMood.daily);
      expect(filtered.length, 1);
      expect(filtered.single.content, '日常说说');
    });

    test('非法草稿被拒绝', () async {
      expect(
        () => repo.createPost(const PostDraft(content: '  ')),
        throwsArgumentError,
      );
      expect(
        () => repo.createPost(
          const PostDraft(content: '内容', origin: PostOrigin.userTopic),
        ),
        throwsArgumentError,
      );
    });
  });

  group('编辑历史与删除', () {
    test('编辑写入追加式历史且保留旧摘要', () async {
      final post = await create(content: '最初的版本');
      await repo.updatePost(post.id, content: '改过的版本');
      final history = await repo.editHistory(post.id);
      expect(history.length, 2);
      expect(history.any((log) => log.op == 'create'), isTrue);
      expect(history.any((log) => log.op == 'update'), isTrue);
      final update = history.firstWhere((log) => log.op == 'update');
      expect(update.beforeDigest, contains('最初的版本'));
      expect(update.afterDigest, contains('改过的版本'));
      final updated = (await repo.getPost(post.id))!;
      expect(updated.content, '改过的版本');
      expect(updated.editedAt, isNotNull);
    });

    test('空内容编辑被拒绝且不写历史', () async {
      final post = await create();
      expect(
        () => repo.updatePost(post.id, content: '   '),
        throwsArgumentError,
      );
      expect((await repo.editHistory(post.id)).length, 1);
    });

    test('软删除后列表与计数都不包含', () async {
      final post = await create();
      await repo.softDelete(post.id);
      expect(await repo.listPosts(), isEmpty);
      expect(await repo.countPosts(), 0);
      final deleted = (await repo.getPost(post.id))!;
      expect(deleted.deletedAt, isNotNull);
    });

    test('最近正文用于去重数据源', () async {
      await create(content: '今天想你了');
      await create(content: '明天要下雨');
      final recent = await repo.recentContents(limit: 10);
      expect(recent, contains('今天想你了'));
      expect(recent, contains('明天要下雨'));
    });
  });
}
