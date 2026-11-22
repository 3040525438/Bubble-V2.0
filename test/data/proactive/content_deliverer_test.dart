// 统一内容投递器单测（T11.3）：post/diary/letter 分流、冷却与重复整理保护。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/diary/diary_generator.dart';
import 'package:bubble/data/letter/letter_generator.dart';
import 'package:bubble/data/proactive/content_deliverer.dart';
import 'package:bubble/data/repositories/diary_repository.dart';
import 'package:bubble/data/repositories/letter_repository.dart';
import 'package:bubble/domain/letter/letter_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  final day = DateTime(2026, 5, 20, 21);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
  });

  tearDown(() async {
    await db.close();
  });

  ProactiveCandidate candidate(String kind, {String id = ''}) {
    final iso = day.toUtc().toIso8601String();
    return ProactiveCandidate(
      id: id.isEmpty ? 'cand_$kind' : id,
      actionKind: kind,
      priority: 60,
      status: 'pending',
      createdAt: iso,
      updatedAt: iso,
    );
  }

  test('日记候选落库，同一天第二次跳过', () async {
    final repo = DiaryRepository(db, clock: () => day);
    final generator = DiaryGenerator(
      db,
      repository: repo,
      caller: (prompt) async => '今天在窗边坐了很久。',
      clock: () => day,
    );
    final deliverer = contentAwareDeliverer(diary: generator);

    final first = await deliverer(candidate('diary'));
    expect(first!.deliverableType, 'diary');
    expect(first.deliverableId, isNotNull);
    expect(await repo.countDiaries(), 1);

    final second = await deliverer(candidate('diary', id: 'cand_diary_2'));
    expect(second!.note, contains('今天已经有日记'));
    expect(await repo.countDiaries(), 1);
  });

  test('信件候选：模型生成直接寄出，冷却内跳过', () async {
    final repo = LetterRepository(db, clock: () => day);
    final generator = LetterGenerator(
      db,
      repository: repo,
      caller: (prompt) async => '展信安。最近想起海边的风。',
      clock: () => day,
    );
    final deliverer = contentAwareDeliverer(letter: generator);

    final first = await deliverer(candidate('letter'));
    expect(first!.deliverableType, 'letter');
    final letters = await repo.listLetters(filter: LetterFilter.fromBubble);
    expect(letters.length, 1);
    expect(letters.single.state, LetterState.sent.wire);

    final second = await deliverer(candidate('letter', id: 'cand_letter_2'));
    expect(second!.note, contains('7 天'));
  });

  test('信件候选：本地草稿只落草稿不寄出', () async {
    final repo = LetterRepository(db, clock: () => day);
    final generator = LetterGenerator(db, repository: repo, clock: () => day);
    final deliverer = contentAwareDeliverer(letter: generator);

    final delivery = await deliverer(candidate('letter'));
    expect(delivery!.deliverableType, 'letter_draft');
    final drafts = await repo.listDrafts();
    expect(drafts.length, 1);
    expect(drafts.single.direction, LetterDirection.bubbleToUser.wire);
  });

  test('其他类型保持记录模式', () async {
    final deliverer = contentAwareDeliverer();
    final delivery = await deliverer(candidate('chat'));
    expect(delivery!.note, contains('记录模式'));
  });
}
