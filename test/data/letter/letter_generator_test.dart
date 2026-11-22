// 泡泡写信生成器单测（T11.2）：模型注入、素材、7 天冷却与草稿落库。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/letter/letter_generator.dart';
import 'package:bubble/data/repositories/experience_repository.dart';
import 'package:bubble/data/repositories/letter_repository.dart';
import 'package:bubble/domain/experience/experience_models.dart';
import 'package:bubble/domain/letter/letter_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late LetterRepository repo;
  late DateTime now;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    now = DateTime(2026, 5, 20, 10);
    repo = LetterRepository(db, clock: () => now);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addExperience() async {
    final experiences = ExperienceRepository(db, clock: () => now);
    await experiences.createExperience(
      ExperienceDraft(
        name: '第一次一起看海',
        occurredAtMs: now.millisecondsSinceEpoch,
        eventContent: '傍晚的海边风很大，我们把外套裹紧了一点。',
      ),
    );
  }

  Future<void> addMemory() async {
    await db
        .into(db.memories)
        .insert(
          MemoriesCompanion.insert(
            id: 'mem_letter_1',
            type: 'preference',
            summary: '她喜欢桂花味的东西',
            createdAt: now.toUtc().toIso8601String(),
            updatedAt: now.toUtc().toIso8601String(),
          ),
        );
  }

  test('注入模型时返回模型生成并引用素材', () async {
    await addExperience();
    await addMemory();
    String? captured;
    final generator = LetterGenerator(
      db,
      repository: repo,
      caller: (prompt) async {
        captured = prompt;
        return '展信安。\n\n最近总想起傍晚的海边，风把我们的话吹得很远。';
      },
      clock: () => now,
    );

    final draft = await generator.generate();
    expect(draft.fromModel, isTrue);
    expect(draft.content, contains('海边'));
    expect(draft.relatedExperienceIds, isNotEmpty);
    expect(draft.relatedMemoryIds, contains('mem_letter_1'));
    expect(captured, contains('第一次一起看海'));
    expect(captured, contains('桂花'));
  });

  test('未注入模型时返回本地草稿', () async {
    await addExperience();
    final generator = LetterGenerator(db, repository: repo, clock: () => now);
    final draft = await generator.generate();
    expect(draft.fromModel, isFalse);
    expect(draft.content, contains('第一次一起看海'));
  });

  test('冷却期内拒绝生成', () async {
    final first = await repo.createAndSend(
      const LetterDraft(
        direction: LetterDirection.bubbleToUser,
        content: '第一封信',
      ),
    );
    expect(first.state, LetterState.sent.wire);

    now = now.add(const Duration(days: 6));
    final generator = LetterGenerator(db, repository: repo, clock: () => now);
    await expectLater(generator.generate(), throwsStateError);

    now = now.add(const Duration(days: 1));
    final draft = await generator.generate();
    expect(draft.content, isNotEmpty);
  });

  test('保存为草稿后方向正确且未寄出', () async {
    final generator = LetterGenerator(db, repository: repo, clock: () => now);
    final draft = await generator.generate();
    final saved = await generator.saveAsDraft(draft);
    expect(saved.direction, LetterDirection.bubbleToUser.wire);
    expect(saved.state, LetterState.draft.wire);
    expect(await repo.listDrafts(), hasLength(1));
  });
}
