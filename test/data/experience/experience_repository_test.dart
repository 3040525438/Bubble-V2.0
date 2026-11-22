// 共同经历仓储单测（T9.1/T9.2）：创建、视角、回顾只追加、关联、自动提名与软删除。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/experience_repository.dart';
import 'package:bubble/data/repositories/memory_repository.dart';
import 'package:bubble/domain/experience/experience_models.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ExperienceRepository repo;
  late MemoryRepository memories;
  final now = DateTime(2026, 5, 20, 10, 0);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = ExperienceRepository(db, clock: () => now);
    memories = MemoryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<SharedExperience> create({
    String name = '第一次一起看雪',
    String content = '那天我们在西湖边看到今年第一场雪',
    int importance = 70,
  }) {
    return repo.createExperience(
      ExperienceDraft(
        name: name,
        occurredAtMs: DateTime(2025, 12, 20, 18, 30).millisecondsSinceEpoch,
        eventContent: content,
        importance: importance,
      ),
    );
  }

  group('创建与列表', () {
    test('创建后可按发生时间倒序列出', () async {
      await create(name: '西湖看雪', content: '一起看雪');
      await repo.createExperience(
        ExperienceDraft(
          name: '第一次一起做饭',
          occurredAtMs: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          eventContent: '一起做了番茄炒蛋',
        ),
      );
      final list = await repo.listExperiences();
      expect(list.length, 2);
      expect(list.first.name, '第一次一起做饭');
      expect(list.last.name, '西湖看雪');
      expect(await repo.countExperiences(), 2);
    });

    test('非法草稿被拒绝', () async {
      expect(
        () => repo.createExperience(
          const ExperienceDraft(name: ' ', occurredAtMs: 1, eventContent: '内容'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('历史事实防改', () {
    test('更新视角不改变名称、时间与事实正文', () async {
      final created = await create();
      final beforeName = created.name;
      final beforeAt = created.occurredAt;
      final beforeContent = created.eventContent;

      await repo.updatePerspectives(
        created.id,
        userPerspective: '我觉得很浪漫',
        bubblePerspective: '那天很安静，雪花落在你的肩上',
      );
      final updated = (await repo.getExperience(created.id))!;
      expect(updated.name, beforeName);
      expect(updated.occurredAt, beforeAt);
      expect(updated.eventContent, beforeContent);
      expect(updated.userPerspective, '我觉得很浪漫');
      expect(updated.bubblePerspective, '那天很安静，雪花落在你的肩上');
    });
  });

  group('回顾记录只追加', () {
    test('连续追加保留全部历史', () async {
      final created = await create();
      await repo.appendReview(
        created.id,
        ExperienceReviewEntry(
          atMs: DateTime(2026, 5, 21).millisecondsSinceEpoch,
          content: '第一次回看',
          author: 'bubble',
        ),
      );
      final second = await repo.appendReview(
        created.id,
        ExperienceReviewEntry(
          atMs: DateTime(2026, 6, 1).millisecondsSinceEpoch,
          content: '第二次回看',
          author: 'user',
        ),
      );
      final entries = ExperienceRules.parseReviewLog(second.reviewLog);
      expect(entries.length, 2);
      expect(entries.first.content, '第一次回看');
      expect(entries.last.content, '第二次回看');
      expect(second.eventContent, created.eventContent);
    });

    test('空白回顾被拒绝且不写库', () async {
      final created = await create();
      expect(
        () => repo.appendReview(
          created.id,
          ExperienceReviewEntry(
            atMs: now.millisecondsSinceEpoch,
            content: '   ',
            author: 'user',
          ),
        ),
        throwsArgumentError,
      );
      final row = (await repo.getExperience(created.id))!;
      expect(row.reviewLog, isNull);
    });
  });

  group('关联与软删除', () {
    test('关联记忆与会话可读写', () async {
      final created = await create();
      await repo.relate(created.id, memoryIds: ['mem_1', 'mem_2']);
      final row = (await repo.getExperience(created.id))!;
      expect(row.relatedMemoryIds, contains('mem_1'));
      expect(row.relatedMemoryIds, contains('mem_2'));
    });

    test('软删除后不再出现在列表', () async {
      final created = await create();
      await repo.softDelete(created.id);
      expect(await repo.listExperiences(), isEmpty);
      expect(await repo.countExperiences(), 0);
    });
  });

  group('自动提名', () {
    test('从共同经历类记忆提名并排除已关联记忆', () async {
      final joint = await memories.createMemory(
        type: 'experience_joint',
        title: '西湖看雪',
        summary: '那天我们在西湖边看到今年第一场雪',
        confidence: 'high',
        importance: 80,
      );
      await memories.createMemory(
        type: 'preference',
        summary: '我喜欢喝黑咖啡',
        confidence: 'high',
      );

      final nominations = await repo.nominateFromMemories();
      expect(nominations.length, 1);
      expect(nominations.single.sourceId, joint.id);
      expect(nominations.single.relatedMemoryIds, contains(joint.id));

      final created = await repo.createFromNomination(nominations.single);
      expect(created.name, '西湖看雪');
      expect(created.eventContent, contains('第一场雪'));

      final again = await repo.nominateFromMemories();
      expect(again, isEmpty, reason: '已写进时间线的记忆不再重复提名');
    });

    test('从思考产出提名（带记忆引用）', () async {
      final memory = await memories.createMemory(
        type: 'event',
        summary: '今天搬家了，新家有个小阳台',
        confidence: 'high',
      );
      final taskId = 'thk_test';
      await db
          .into(db.thinkingTasks)
          .insert(
            ThinkingTasksCompanion.insert(
              id: taskId,
              trigger: const Value('manual'),
              state: const Value('done'),
              startedAt: Value(now.millisecondsSinceEpoch),
            ),
          );
      await db
          .into(db.thinkingResults)
          .insert(
            ThinkingResultsCompanion.insert(
              id: 'res_test',
              taskId: taskId,
              resultKind: 'share_worthy',
              content: '新家的小阳台也许值得一起记住',
              relatedMemoryIds: Value('["${memory.id}"]'),
              createdAt: now.toUtc().toIso8601String(),
            ),
          );

      final nominations = await repo.nominateFromThinking();
      expect(nominations.length, 1);
      expect(nominations.single.sourceKind, 'thinking');
      expect(nominations.single.relatedMemoryIds, contains(memory.id));
    });
  });
}
