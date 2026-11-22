// 备份服务测试（T14.3）：目录包备份、sha256 校验、覆盖恢复与损坏检测。
import 'dart:convert';
import 'dart:io';

import 'package:bubble/data/backup/backup_service.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/domain/backup/backup_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late BackupService service;
  late Directory root;
  late DateTime clockNow;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_backup_test_');
    clockNow = DateTime.utc(2026, 11, 20, 9, 30);
    service = BackupService(db, root: root, clock: () => clockNow);
    final nowIso = DateTime.utc(2026, 11, 20).toIso8601String();
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
    await db
        .into(db.appSettings)
        .insert(AppSettingsCompanion.insert(key: 'k', updatedAt: nowIso));
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('创建备份写入 data.json 与附件副本', () async {
    final attachments = Directory(
      '${root.path}${Platform.pathSeparator}Attachments${Platform.pathSeparator}2026'
      '${Platform.pathSeparator}11',
    );
    await attachments.create(recursive: true);
    final file = File('${attachments.path}${Platform.pathSeparator}a.jpg');
    await file.writeAsBytes([1, 2, 3, 4]);

    final artifact = await service.createBackup();
    expect(artifact.path, contains('bubble_manual_'));
    expect(artifact.sha256, isNotNull);
    expect(artifact.tableCounts['memories'], 1);

    final dataFile = File(
      '${artifact.path}${Platform.pathSeparator}${BackupService.dataFileName}',
    );
    expect(await dataFile.exists(), isTrue);
    final decoded = jsonDecode(await dataFile.readAsString()) as Map;
    expect(decoded['format'], 'bubble-backup');
    expect((decoded['tables'] as Map).containsKey('memories'), isTrue);

    final copied = File(
      '${artifact.path}${Platform.pathSeparator}attachments'
      '${Platform.pathSeparator}2026${Platform.pathSeparator}11'
      '${Platform.pathSeparator}a.jpg',
    );
    expect(await copied.exists(), isTrue);

    final records = await db.select(db.backupRecords).get();
    expect(records, hasLength(1));
  });

  test('校验通过后标记 verified', () async {
    final artifact = await service.createBackup();
    final verification = await service.verify(artifact);
    expect(verification.ok, isTrue);
    expect(verification.sha256Matched, isTrue);
    expect(verification.countsMatched, isTrue);

    final refreshed = await service.byId(artifact.id);
    expect(refreshed?.verifiedAt, isNotNull);
  });

  test('篡改 data.json 后校验失败', () async {
    final artifact = await service.createBackup();
    final dataFile = File(
      '${artifact.path}${Platform.pathSeparator}${BackupService.dataFileName}',
    );
    await dataFile.writeAsString('{"format":"broken"}');

    final verification = await service.verify(artifact);
    expect(verification.ok, isFalse);
    expect(verification.sha256Matched, isFalse);
  });

  test('恢复覆盖内容表并自动先备份当前数据', () async {
    final artifact = await service.createBackup();

    await (db.delete(db.memories)..where((t) => t.id.equals('mem_1'))).go();
    expect(await db.select(db.memories).get(), isEmpty);

    final result = await service.restore(artifact);
    expect(result.ok, isTrue);
    expect(result.autoBackupPath, isNotNull);

    final restored = await db.select(db.memories).get();
    expect(restored.single.id, 'mem_1');

    final records = await service.listBackups();
    expect(records.any((r) => r.kind == BackupKind.auto), isTrue);
  });

  test('列表按时间倒序且可查询单条', () async {
    final first = await service.createBackup();
    clockNow = clockNow.add(const Duration(seconds: 1));
    final second = await service.createBackup();
    final list = await service.listBackups();
    expect(list.length, 2);
    expect(list.first.id, second.id);
    expect((await service.byId(first.id))?.kind, BackupKind.manual);
  });
}
