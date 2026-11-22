// 说说生成器单测（T10.2）：模型注入、去重重试、失败降级、本地生成。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/post/post_generator.dart';
import 'package:bubble/data/repositories/post_repository.dart';
import 'package:bubble/domain/post/post_models.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('注入模型时使用模型文本并标注 fromModel', () async {
    final prompts = <String>[];
    final generator = PostGenerator(
      db,
      repository: repo,
      caller: (prompt) async {
        prompts.add(prompt);
        return '今天路过那家咖啡店，忽然想起你说过喜欢靠窗的位置。';
      },
    );
    final draft = await generator.generate(
      mode: PostGenerationMode.autonomous,
      mood: PostMood.daily,
    );
    expect(draft.fromModel, isTrue);
    expect(draft.content, contains('咖啡店'));
    expect(draft.duplicateRisk, isFalse);
    expect(prompts.single, contains('你是「泡泡」'));
  });

  test('模型内容与最近说说重复时重试一次', () async {
    await repo.createPost(const PostDraft(content: '今天想你了'));
    var calls = 0;
    final generator = PostGenerator(
      db,
      repository: repo,
      caller: (prompt) async {
        calls++;
        if (calls == 1) return '今天想你了';
        return '窗外在下雨，忽然想起你上次说喜欢雨声。';
      },
    );
    final draft = await generator.generate(mode: PostGenerationMode.autonomous);
    expect(calls, 2);
    expect(draft.content, contains('雨声'));
    expect(draft.duplicateRisk, isFalse);
  });

  test('重试后仍重复则标记 duplicateRisk 但不阻断预览', () async {
    await repo.createPost(const PostDraft(content: '今天想你了'));
    final generator = PostGenerator(
      db,
      repository: repo,
      caller: (prompt) async => '今天想你了',
    );
    final draft = await generator.generate(mode: PostGenerationMode.autonomous);
    expect(draft.duplicateRisk, isTrue);
    expect(draft.content, '今天想你了');
  });

  test('模型失败时回退本地草稿并明确标注非模型', () async {
    final generator = PostGenerator(
      db,
      repository: repo,
      caller: (prompt) async => throw StateError('网络错误'),
    );
    final draft = await generator.generate(
      mode: PostGenerationMode.userTopic,
      topic: '下雨天',
      mood: PostMood.mood,
    );
    expect(draft.fromModel, isFalse);
    expect(draft.content, contains('下雨天'));
  });

  test('未配置模型时使用本地降级且不冒充模型内容', () async {
    final generator = PostGenerator(db, repository: repo);
    final draft = await generator.generate(mode: PostGenerationMode.autonomous);
    expect(draft.fromModel, isFalse);
    expect(draft.content, isNotEmpty);
  });

  test('发布生成结果会落库并带来源与心情', () async {
    final generator = PostGenerator(
      db,
      repository: repo,
      caller: (prompt) async => '今天风很好，想把窗户打开一会儿。',
    );
    final draft = await generator.generate(
      mode: PostGenerationMode.userTopic,
      topic: '风',
      mood: PostMood.thought,
    );
    final post = await generator.publish(draft);
    expect(post.content, contains('窗户'));
    expect(post.mood, 'thought');
    expect(post.origin, 'user_topic');
    expect(post.topic, '风');
    expect(await repo.countPosts(), 1);
  });

  test('决策投递器：post 候选真实发布，其他候选保持记录模式', () async {
    final generator = PostGenerator(
      db,
      repository: repo,
      caller: (prompt) async => '今天阳光很好，想和你一起晒晒太阳。',
    );
    final deliverer = postAwareDeliverer(generator);

    final chatDelivery = await deliverer(
      ProactiveCandidate(
        id: 'c1',
        actionKind: 'chat',
        priority: 50,
        status: 'pending',
        createdAt: DateTime.now().toUtc().toIso8601String(),
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    expect(chatDelivery?.deliverableType, isNull);

    final postDelivery = await deliverer(
      ProactiveCandidate(
        id: 'c2',
        actionKind: 'post',
        priority: 60,
        status: 'pending',
        sourceKind: 'share_worthy',
        title: '阳光',
        createdAt: DateTime.now().toUtc().toIso8601String(),
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      ),
    );
    expect(postDelivery?.deliverableType, 'post');
    expect(postDelivery?.deliverableId, isNotNull);
    expect(await repo.countPosts(), 1);
  });
}
