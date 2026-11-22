// 备份服务（T14.3）：目录包逻辑备份 → 校验 → 覆盖恢复（恢复前自动先备份）。
// 备份结构：Backups/bubble_<kind>_<stamp>/data.json + attachments/。
// sha256 取 data.json；恢复按 FK 关闭 + 事务覆盖内容表，再重建搜索索引。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../domain/backup/backup_models.dart';
import '../database/app_database.dart';
import '../search/global_search_repository.dart';
import 'database_snapshot.dart';

class BackupService {
  BackupService(
    this._db, {
    Directory? root,
    DateTime Function()? clock,
    GlobalSearchRepository? searchRepository,
  }) : _rootOverride = root,
       _clock = clock ?? DateTime.now,
       _search = searchRepository ?? GlobalSearchRepository(_db);

  final AppDatabase _db;
  final Directory? _rootOverride;
  final DateTime Function() _clock;
  final GlobalSearchRepository _search;
  static const _uuid = Uuid();

  static const backupFolder = 'Backups';
  static const dataFileName = 'data.json';
  static const attachmentsFolder = 'Attachments';

  DatabaseSnapshot get _snapshot => DatabaseSnapshot(_db);

  Directory? _resolvedRoot;

  Future<Directory> _root() async {
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    final root = _rootOverride ?? await getApplicationDocumentsDirectory();
    if (!await root.exists()) await root.create(recursive: true);
    _resolvedRoot = root;
    return root;
  }

  static String _stamp(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}${two(l.month)}${two(l.day)}_'
        '${two(l.hour)}${two(l.minute)}${two(l.second)}';
  }

  static String _newId() {
    final compact = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[-:TZ.]'),
      '',
    );
    return 'bk_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  String _nowIso() => _clock().toUtc().toIso8601String();

  // ------------------------------------------------------------ 创建

  /// 创建一次备份；附件目录存在时一并复制。
  Future<BackupArtifact> createBackup({
    BackupKind kind = BackupKind.manual,
  }) async {
    final root = await _root();
    final now = _clock();
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}$backupFolder'
      '${Platform.pathSeparator}bubble_${kind.wire}_${_stamp(now)}',
    );
    // 同一秒重复备份时追加序号，避免覆盖既有备份
    var target = dir;
    var suffix = 1;
    while (await target.exists()) {
      target = Directory('${dir.path}_${suffix++}');
    }
    await target.create(recursive: true);

    final tables = await _snapshot.dump();
    final counts = <String, int>{
      for (final entry in tables.entries) entry.key: entry.value.length,
    };
    final payload = <String, Object?>{
      'format': 'bubble-backup',
      'formatVersion': 1,
      'schemaVersion': _db.schemaVersion,
      'kind': kind.wire,
      'createdAt': _nowIso(),
      'tableCounts': counts,
      'tables': tables,
    };
    final bytes = utf8.encode(jsonEncode(payload));
    final dataFile = File(
      '${target.path}${Platform.pathSeparator}$dataFileName',
    );
    await dataFile.writeAsBytes(bytes, flush: true);
    final sha = _sha256Hex(bytes);

    await _copyAttachmentsTo(target);

    final id = _newId();
    final createdAt = _nowIso();
    await _db.transaction(() async {
      await _db
          .into(_db.backupRecords)
          .insert(
            BackupRecordsCompanion.insert(
              id: id,
              kind: Value(kind.wire),
              path: target.path,
              sizeBytes: Value(bytes.length),
              sha256: Value(sha),
              tableCounts: Value(jsonEncode(counts)),
              dbSchemaVersion: Value(_db.schemaVersion),
              createdAt: createdAt,
            ),
          );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'create',
              entityTable: 'backup_records',
              entityId: id,
              afterDigest: Value(
                '${kind.label}：${counts.values.fold(0, (s, v) => s + v)} 行',
              ),
              reason: const Value('创建备份'),
              source: const Value('user'),
              at: createdAt,
            ),
          );
    });

    return BackupArtifact(
      id: id,
      kind: kind,
      path: target.path,
      createdAt: createdAt,
      sizeBytes: bytes.length,
      sha256: sha,
      tableCounts: counts,
      dbSchemaVersion: _db.schemaVersion,
    );
  }

  /// 备份列表（新→旧）。
  Future<List<BackupArtifact>> listBackups({int limit = 50}) async {
    final rows =
        await (_db.select(_db.backupRecords)
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(limit))
            .get();
    return rows.map(_toArtifact).toList(growable: false);
  }

  Future<BackupArtifact?> byId(String id) async {
    final row = await (_db.select(
      _db.backupRecords,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toArtifact(row);
  }

  static BackupArtifact _toArtifact(BackupRecord row) {
    Map<String, int> counts = const {};
    final raw = row.tableCounts;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          counts = {
            for (final e in decoded.entries)
              e.key.toString(): (e.value as num?)?.toInt() ?? 0,
          };
        }
      } catch (_) {
        // 损坏的计数快照 → 空计数，由 verify 报告差异
      }
    }
    return BackupArtifact(
      id: row.id,
      kind: BackupKind.fromWire(row.kind),
      path: row.path,
      createdAt: row.createdAt,
      sizeBytes: row.sizeBytes,
      sha256: row.sha256,
      tableCounts: counts,
      dbSchemaVersion: row.dbSchemaVersion,
      verifiedAt: row.verifiedAt,
      status: row.status,
    );
  }

  // ------------------------------------------------------------ 校验

  /// 校验备份：data.json 存在 → sha256 一致 → schemaVersion 匹配 → 逐表行数对账。
  Future<BackupVerification> verify(BackupArtifact artifact) async {
    final dataFile = File(
      '${artifact.path}${Platform.pathSeparator}$dataFileName',
    );
    if (!await dataFile.exists()) {
      return BackupVerification.failure('备份包缺少 $dataFileName');
    }
    final bytes = await dataFile.readAsBytes();
    final actualSha = _sha256Hex(bytes);

    final Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        return BackupVerification.failure('备份格式无法识别');
      }
      payload = decoded;
    } catch (e) {
      return BackupVerification.failure('备份已损坏：$e');
    }

    final counts = <String, int>{};
    final rawCounts = payload['tableCounts'];
    if (rawCounts is Map) {
      for (final e in rawCounts.entries) {
        counts[e.key.toString()] = (e.value as num?)?.toInt() ?? 0;
      }
    }
    final tables = payload['tables'];
    if (tables is! Map) {
      return BackupVerification.failure('备份缺少表数据');
    }
    final actualCounts = <String, int>{
      for (final e in tables.entries)
        e.key.toString(): (e.value is List ? (e.value as List).length : 0),
    };

    final verification = BackupVerification(
      ok: true,
      expectedSha256: artifact.sha256,
      actualSha256: actualSha,
      expectedCounts: counts,
      actualCounts: actualCounts,
    );

    if (artifact.sha256 != null &&
        artifact.sha256!.isNotEmpty &&
        artifact.sha256 != actualSha) {
      return BackupVerification(
        ok: false,
        error: 'sha256 不一致（备份可能已损坏）',
        expectedSha256: artifact.sha256,
        actualSha256: actualSha,
        expectedCounts: counts,
        actualCounts: actualCounts,
      );
    }
    if (!verification.countsMatched) {
      return BackupVerification(
        ok: false,
        error: '行数对账不一致',
        expectedSha256: artifact.sha256,
        actualSha256: actualSha,
        expectedCounts: counts,
        actualCounts: actualCounts,
      );
    }
    final version = (payload['schemaVersion'] as num?)?.toInt();
    if (version != null && version != _db.schemaVersion) {
      return BackupVerification(
        ok: false,
        error: 'schema 版本不匹配（备份 v$version / 当前 v${_db.schemaVersion}）',
        expectedSha256: artifact.sha256,
        actualSha256: actualSha,
        expectedCounts: counts,
        actualCounts: actualCounts,
      );
    }

    // 校验通过 → 标记 verified
    await (_db.update(_db.backupRecords)
          ..where((t) => t.id.equals(artifact.id)))
        .write(BackupRecordsCompanion(verifiedAt: Value(_nowIso())));
    return verification;
  }

  // ------------------------------------------------------------ 恢复

  /// 恢复备份：先自动备份当前数据，再校验、覆盖内容表、还原附件、重建索引。
  Future<RestoreResult> restore(BackupArtifact artifact) async {
    final autoBackup = await createBackup(kind: BackupKind.auto);
    if (artifact.isCorrupt) {
      return RestoreResult(
        ok: false,
        autoBackupPath: autoBackup.path,
        error: '备份已被标记为损坏，拒绝恢复',
      );
    }
    final verification = await verify(artifact);
    if (!verification.ok) {
      return RestoreResult(
        ok: false,
        autoBackupPath: autoBackup.path,
        error: verification.error ?? '校验失败',
      );
    }

    final dataFile = File(
      '${artifact.path}${Platform.pathSeparator}$dataFileName',
    );
    final decoded = jsonDecode(await dataFile.readAsString());
    final rawTables = (decoded as Map)['tables'];
    if (rawTables is! Map) {
      return RestoreResult(
        ok: false,
        autoBackupPath: autoBackup.path,
        error: '备份缺少表数据',
      );
    }
    final tables = <String, List<Map<String, Object?>>>{};
    for (final e in rawTables.entries) {
      final rows = e.value;
      if (rows is! List) continue;
      tables[e.key.toString()] = rows
          .whereType<Map>()
          .map((r) => Map<String, Object?>.from(r))
          .toList(growable: false);
    }

    final restored = await _snapshot.restore(tables);
    await _restoreAttachmentsFrom(Directory(artifact.path));
    await _search.rebuildIndex();

    await (_db.update(_db.backupRecords)
          ..where((t) => t.id.equals(artifact.id)))
        .write(BackupRecordsCompanion(verifiedAt: Value(_nowIso())));
    await _db
        .into(_db.journalLogs)
        .insert(
          JournalLogsCompanion.insert(
            op: 'restore',
            entityTable: 'backup_records',
            entityId: artifact.id,
            afterDigest: Value('恢复 ${restored.tables} 表 / ${restored.rows} 行'),
            reason: Value('从备份恢复（自动先备份：${autoBackup.path}）'),
            source: const Value('user'),
            at: _nowIso(),
          ),
        );

    return RestoreResult(
      ok: true,
      autoBackupPath: autoBackup.path,
      restoredTables: restored.tables,
      restoredRows: restored.rows,
    );
  }

  // ------------------------------------------------------------ 文件工具

  Future<void> _copyAttachmentsTo(Directory backupDir) async {
    final root = await _root();
    final source = Directory(
      '${root.path}${Platform.pathSeparator}$attachmentsFolder',
    );
    final target = Directory(
      '${backupDir.path}${Platform.pathSeparator}attachments',
    );
    if (!await source.exists()) return;
    await _copyDirectory(source, target);
  }

  Future<void> _restoreAttachmentsFrom(Directory backupDir) async {
    final root = await _root();
    final source = Directory(
      '${backupDir.path}${Platform.pathSeparator}attachments',
    );
    final target = Directory(
      '${root.path}${Platform.pathSeparator}$attachmentsFolder',
    );
    // 备份代表全量状态：先清空当前附件目录，再复制（无附件则保持为空）
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
    if (!await source.exists()) return;
    await _copyDirectory(source, target);
  }

  Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true)) {
      final rel = entity.path
          .substring(from.path.length)
          .replaceAll('\\', '/')
          .replaceAll(RegExp('^/+'), '');
      if (entity is Directory) {
        await Directory(
          '${to.path}${Platform.pathSeparator}'
          '${rel.split('/').join(Platform.pathSeparator)}',
        ).create(recursive: true);
      } else if (entity is File) {
        final target = File(
          '${to.path}${Platform.pathSeparator}'
          '${rel.split('/').join(Platform.pathSeparator)}',
        );
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      }
    }
  }

  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
}
