// 信件仓储单测（T11.2）：草稿/寄出、双向筛选、7 天冷却与软删除。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/letter_repository.dart';
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

  Future<Letter> draft({
    LetterDirection direction = LetterDirection.userToBubble,
    String content = '想和你说说今天',
  }) {
    return repo.createDraft(
      LetterDraft(direction: direction, content: content),
    );
  }

  group('创建与寄出', () {
    test('新建的是草稿且没有寄出时间', () async {
      final letter = await draft();
      expect(letter.state, LetterState.draft.wire);
      expect(letter.sentAt, isNull);
      expect(letter.title, isNotNull);
      final drafts = await repo.listDrafts();
      expect(drafts.length, 1);
    });

    test('寄出后状态与时间写入，筛选生效', () async {
      final letter = await draft();
      final sent = await repo.sendLetter(letter.id);
      expect(sent.state, LetterState.sent.wire);
      expect(sent.sentAt, now.millisecondsSinceEpoch);

      expect(await repo.listDrafts(), isEmpty);
      final fromUser = await repo.listLetters(filter: LetterFilter.fromUser);
      expect(fromUser.length, 1);
      final fromBubble = await repo.listLetters(
        filter: LetterFilter.fromBubble,
      );
      expect(fromBubble, isEmpty);
    });

    test('已寄出的信不能再次寄出或修改', () async {
      final letter = await draft();
      await repo.sendLetter(letter.id);
      await expectLater(repo.sendLetter(letter.id), throwsStateError);
      await expectLater(
        repo.updateDraft(letter.id, content: '想改一下'),
        throwsStateError,
      );
    });

    test('草稿编辑保留新内容', () async {
      final letter = await draft(content: '旧内容');
      await repo.updateDraft(letter.id, content: '新内容');
      final updated = (await repo.getLetter(letter.id))!;
      expect(updated.content, '新内容');
    });
  });

  group('泡泡写信 7 天冷却', () {
    test('首次可以寄出，6 天后被拒绝，满 7 天后恢复', () async {
      expect(await repo.canBubbleSendNow(), isTrue);
      final first = await draft(direction: LetterDirection.bubbleToUser);
      await repo.sendLetter(first.id);

      now = now.add(const Duration(days: 6));
      expect(await repo.canBubbleSendNow(), isFalse);
      final second = await draft(direction: LetterDirection.bubbleToUser);
      await expectLater(repo.sendLetter(second.id), throwsStateError);
      expect(
        LetterState.fromWire((await repo.getLetter(second.id))!.state),
        LetterState.draft,
      );

      now = now.add(const Duration(days: 1));
      expect(await repo.canBubbleSendNow(), isTrue);
      final sent = await repo.sendLetter(second.id);
      expect(sent.state, LetterState.sent.wire);
    });

    test('用户写的信不受泡泡冷却影响', () async {
      final bubble = await draft(direction: LetterDirection.bubbleToUser);
      await repo.sendLetter(bubble.id);
      now = now.add(const Duration(hours: 1));
      final userLetter = await draft();
      final sent = await repo.sendLetter(userLetter.id);
      expect(sent.state, LetterState.sent.wire);
      expect(await repo.canBubbleSendNow(), isFalse);
    });

    test('最近泡泡来信时间忽略用户信件', () async {
      final userLetter = await draft();
      await repo.sendLetter(userLetter.id);
      expect(await repo.lastBubbleSentAtMs(), isNull);

      final bubble = await draft(direction: LetterDirection.bubbleToUser);
      await repo.sendLetter(bubble.id);
      expect(await repo.lastBubbleSentAtMs(), now.millisecondsSinceEpoch);
    });
  });

  group('排序与删除', () {
    test('草稿排在已寄出的信前面', () async {
      final sentLetter = await draft(content: '已寄出的');
      await repo.sendLetter(sentLetter.id);
      now = now.add(const Duration(minutes: 5));
      final draftLetter = await draft(content: '还没寄出的');

      final rows = await repo.listLetters();
      expect(rows.first.id, draftLetter.id);
      expect(rows.last.id, sentLetter.id);
    });

    test('软删除后列表与计数都不包含', () async {
      final letter = await draft();
      await repo.softDelete(letter.id);
      expect(await repo.listLetters(), isEmpty);
      expect(await repo.countLetters(), 0);
    });

    test('最近信件正文用于去重数据源', () async {
      await draft(content: '第一封的内容');
      await draft(content: '第二封的内容');
      final recent = await repo.recentContents(limit: 2);
      expect(recent.length, 2);
      expect(recent.any((text) => text.contains('第一封')), isTrue);
    });
  });
}
