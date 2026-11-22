// 日记整理器单测（T11.1）：真实模型注入、素材筛选、失败回退与保存。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/diary/diary_generator.dart';
import 'package:bubble/data/repositories/diary_repository.dart';
import 'package:bubble/domain/diary/diary_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late DiaryRepository repo;
  final day = DateTime(2026, 5, 20, 21);

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = DiaryRepository(db, clock: () => day);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> addMessage({
    required String id,
    required String content,
    required DateTime at,
    String role = 'user',
  }) async {
    final conversationId = 'conv_$id';
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: conversationId,
            title: '测试会话',
            createdAt: at.toUtc().toIso8601String(),
            updatedAt: at.toUtc().toIso8601String(),
          ),
        );
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            role: role,
            seq: 1,
            content: content,
            status: 'sent',
            createdAt: at.toUtc().toIso8601String(),
            updatedAt: at.toUtc().toIso8601String(),
          ),
        );
  }

  test('注入模型时返回模型整理并带上当天消息关联', () async {
    await addMessage(
      id: 'msg_1',
      content: '今天去了咖啡店，窗边有光',
      at: DateTime(2026, 5, 20, 10, 30),
    );
    await addMessage(
      id: 'msg_old',
      content: '昨天的消息',
      at: DateTime(2026, 5, 19, 10),
    );

    String? captured;
    final generator = DiaryGenerator(
      db,
      repository: repo,
      caller: (prompt) async {
        captured = prompt;
        return '今天在咖啡店的窗边坐了很久，光落在桌面上。';
      },
      clock: () => day,
    );

    final draft = await generator.generate();
    expect(draft.fromModel, isTrue);
    expect(draft.content, contains('咖啡店'));
    expect(draft.relatedMessageIds, contains('msg_1'));
    expect(draft.relatedMessageIds, isNot(contains('msg_old')));
    expect(captured, contains('今天去了咖啡店'));
    expect(captured, isNot(contains('昨天的消息')));
  });

  test('未注入模型时本地整理并明确非模型', () async {
    await addMessage(
      id: 'msg_2',
      content: '今天一起听了雨声',
      at: DateTime(2026, 5, 20, 20),
    );
    final generator = DiaryGenerator(db, repository: repo, clock: () => day);
    final draft = await generator.generate();
    expect(draft.fromModel, isFalse);
    expect(draft.content, contains('雨声'));
  });

  test('模型失败时回退本地整理', () async {
    await addMessage(
      id: 'msg_3',
      content: '今天煮了面',
      at: DateTime(2026, 5, 20, 19),
    );
    final generator = DiaryGenerator(
      db,
      repository: repo,
      caller: (prompt) async => throw StateError('网络超时'),
      clock: () => day,
    );
    final draft = await generator.generate();
    expect(draft.fromModel, isFalse);
    expect(draft.content, contains('煮了面'));
  });

  test('保存后按日期归档', () async {
    final generator = DiaryGenerator(db, repository: repo, clock: () => day);
    final draft = await generator.generate();
    final saved = await generator.save(draft);
    expect(saved.entryDate, DiaryRules.dateKey(day));
    expect(saved.origin, DiaryOrigin.aiOrganized.wire);
    expect((await repo.listByDate(day)).length, 1);
  });
}
