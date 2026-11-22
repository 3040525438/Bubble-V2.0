// 数据中心服务测试（T14.4）：状态、孤立附件清理、索引重建与删除全部数据。
import 'dart:io';

import 'package:bubble/data/data_center/data_center_service.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late DataCenterService service;
  late Directory root;
  final nowIso = DateTime.utc(2026, 11, 20).toIso8601String();

  Future<void> seed() async {
    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'conv_1',
            title: '测试会话',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'msg_1',
            conversationId: 'conv_1',
            role: 'user',
            seq: 1,
            content: '你好呀',
            status: 'sent',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
    await db
        .into(db.memories)
        .insert(
          MemoriesCompanion.insert(
            id: 'mem_1',
            type: 'preference',
            summary: '喜欢咖啡',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
  }

  Future<File> writeAttachment(String relPath) async {
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}Attachments'
      '${Platform.pathSeparator}2026${Platform.pathSeparator}11',
    );
    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}${relPath.split('/').last}',
    );
    await file.writeAsBytes([1, 2, 3]);
    return file;
  }

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_data_center_test_');
    service = DataCenterService(
      db,
      root: root,
      clock: () => DateTime.utc(2026, 11, 20, 9, 30),
    );
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('状态汇总包含数据库、附件与关键计数', () async {
    await seed();
    final status = await service.loadStatus();
    expect(status.dbHealthy, isTrue);
    expect(status.schemaVersion, 1);
    expect(status.keyCounts['消息'], 1);
    expect(status.keyCounts['记忆'], 1);
    expect(status.totalRows, greaterThan(0));
    expect(status.lastBackup, isNull);
  });

  test('完整性检查发现孤立附件并可清理', () async {
    await seed();
    final orphan = await writeAttachment('Attachments/2026/11/orphan.jpg');

    final integrity = await service.runIntegrityCheck();
    expect(integrity.orphanFiles, hasLength(1));
    expect(integrity.isHealthy, isFalse);

    final deleted = await service.cleanupOrphanFiles();
    expect(deleted, 1);
    expect(await orphan.exists(), isFalse);

    final after = await service.runIntegrityCheck();
    expect(after.orphanFiles, isEmpty);
  });

  test('索引重建写入记忆索引与搜索倒排', () async {
    await seed();
    final result = await service.rebuildIndexes();
    expect(result.memoryDocs, 1);
    expect(result.contentTerms, greaterThan(0));

    final terms = await db.select(db.contentIndexTerms).get();
    expect(terms.isNotEmpty, isTrue);
  });

  test('删除范围清单与删除全部数据', () async {
    await seed();
    await writeAttachment('Attachments/2026/11/a.jpg');
    await db
        .into(db.attachments)
        .insert(
          AttachmentsCompanion.insert(
            id: 'att_1',
            ownerKind: 'message',
            ownerId: 'msg_1',
            relPath: 'Attachments/2026/11/a.jpg',
            createdAt: nowIso,
          ),
        );
    await db
        .into(db.journalLogs)
        .insert(
          JournalLogsCompanion.insert(
            op: 'create',
            entityTable: 'memories',
            entityId: 'mem_1',
            at: nowIso,
          ),
        );

    final scope = await service.deletionScope();
    expect(scope['消息'], 1);
    expect(scope['附件'], 1);

    final result = await service.deleteAllData(createSafetyBackup: false);
    expect(result.totalDeleted, greaterThan(0));
    expect(result.attachmentFilesDeleted, 1);
    expect(result.autoBackup, isNull);

    expect(await db.select(db.conversations).get(), isEmpty);
    expect(await db.select(db.memories).get(), isEmpty);
    expect(await db.select(db.attachments).get(), isEmpty);

    final attachmentDir = Directory(
      '${root.path}${Platform.pathSeparator}Attachments',
    );
    final left = await attachmentDir
        .list(recursive: true)
        .where((e) => e is File)
        .toList();
    expect(left, isEmpty);

    final firstRun = await (db.select(
      db.appSettings,
    )..where((t) => t.key.equals('app_first_run_done'))).getSingle();
    expect(firstRun.value, '0');

    // 审计日志保留
    expect(await db.select(db.journalLogs).get(), isNotEmpty);
  });

  test('删除前可自动备份', () async {
    await seed();
    final result = await service.deleteAllData(createSafetyBackup: true);
    expect(result.autoBackup, isNotNull);
    expect(await db.select(db.backupRecords).get(), isNotEmpty);
  });
}
