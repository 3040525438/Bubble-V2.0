// 数据中心服务（T14.4）：状态汇总、完整性检查、索引重建、孤立附件清理、删除全部数据。
// 依据 UI_PAGE_SPEC §25/§38、REQUIREMENTS FR-MISC、SECURITY_AND_PRIVACY §删除与审计。
import 'dart:io';

import 'package:drift/drift.dart';

import '../../domain/backup/backup_models.dart';
import '../../domain/feedback/feedback_models.dart';
import '../attachment/attachment_store.dart';
import '../backup/backup_service.dart';
import '../backup/database_snapshot.dart';
import '../database/app_database.dart';
import '../repositories/attachment_repository.dart';
import '../repositories/feedback_repository.dart';
import '../search/global_search_repository.dart';
import '../search/memory_index.dart';

/// 数据中心状态汇总。
class DataCenterStatus {
  const DataCenterStatus({
    required this.dbHealthy,
    required this.schemaVersion,
    required this.orphanFiles,
    required this.missingFiles,
    required this.indexConsistent,
    required this.pendingMemoryCount,
    required this.attachmentBytes,
    required this.totalRows,
    required this.keyCounts,
    this.lastBackup,
  });

  final bool dbHealthy;
  final int schemaVersion;
  final int orphanFiles;
  final int missingFiles;
  final bool indexConsistent;
  final int pendingMemoryCount;
  final int attachmentBytes;

  /// 内容表总行数（不含派生索引与审计表）
  final int totalRows;

  /// 关键域计数（会话/消息/记忆/说说/日记/信件/经历/附件）
  final Map<String, int> keyCounts;

  final BackupArtifact? lastBackup;

  static DataCenterStatus empty() => const DataCenterStatus(
    dbHealthy: true,
    schemaVersion: 1,
    orphanFiles: 0,
    missingFiles: 0,
    indexConsistent: true,
    pendingMemoryCount: 0,
    attachmentBytes: 0,
    totalRows: 0,
    keyCounts: {},
  );
}

/// 完整性检查结果。
class DataCenterIntegrity {
  const DataCenterIntegrity({
    required this.dbHealthy,
    required this.orphanFiles,
    required this.missingRecordIds,
    required this.indexConsistent,
    required this.contentIndexTerms,
  });

  final bool dbHealthy;
  final List<String> orphanFiles;
  final List<String> missingRecordIds;
  final bool indexConsistent;
  final int contentIndexTerms;

  bool get isHealthy =>
      dbHealthy &&
      orphanFiles.isEmpty &&
      missingRecordIds.isEmpty &&
      indexConsistent;
}

/// 删除全部数据结果（删除范围清单 + 实际删除计数）。
class DeleteAllDataResult {
  const DeleteAllDataResult({
    required this.deletedCounts,
    required this.attachmentFilesDeleted,
    this.autoBackup,
  });

  final Map<String, int> deletedCounts;
  final int attachmentFilesDeleted;
  final BackupArtifact? autoBackup;

  int get totalDeleted => deletedCounts.values.fold(0, (s, v) => s + v);
}

class DataCenterService {
  DataCenterService(
    this._db, {
    Directory? root,
    AttachmentRepository? attachments,
    BackupService? backupService,
    GlobalSearchRepository? searchRepository,
    DateTime Function()? clock,
  }) : _attachments =
           attachments ??
           AttachmentRepository(_db, store: AttachmentStore(root: root)),
       _backup = backupService ?? BackupService(_db, root: root, clock: clock),
       _search = searchRepository ?? GlobalSearchRepository(_db),
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final AttachmentRepository _attachments;
  final BackupService _backup;
  final GlobalSearchRepository _search;
  final DateTime Function() _clock;

  /// 汇总状态。
  Future<DataCenterStatus> loadStatus() async {
    final healthy = await _db.quickCheck();
    final integrity = await _attachments.checkIntegrity();
    final memoryIndexConsistent = await MemoryIndexWriter(_db).isConsistent();
    final snapshot = DatabaseSnapshot(_db);
    final counts = await snapshot.counts();
    final backups = await _backup.listBackups(limit: 1);

    final pendingRow = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM memory_candidates WHERE status = ?',
          variables: [Variable.withString('pending')],
        )
        .getSingle();

    var attachmentBytes = 0;
    await _attachments.store.ensureReady();
    for (final relPath in await _attachments.store.listStoredRelPaths()) {
      final file = _attachments.store.fileOf(relPath);
      if (await file.exists()) {
        attachmentBytes += await file.length();
      }
    }

    return DataCenterStatus(
      dbHealthy: healthy,
      schemaVersion: _db.schemaVersion,
      orphanFiles: integrity.orphanFiles.length,
      missingFiles: integrity.missingRecords.length,
      indexConsistent: memoryIndexConsistent,
      pendingMemoryCount: pendingRow.data['c'] as int? ?? 0,
      attachmentBytes: attachmentBytes,
      totalRows: counts.values.fold(0, (s, v) => s + v),
      keyCounts: {
        '会话': counts['conversations'] ?? 0,
        '消息': counts['messages'] ?? 0,
        '记忆': counts['memories'] ?? 0,
        '说说': counts['posts'] ?? 0,
        '日记': counts['diaries'] ?? 0,
        '信件': counts['letters'] ?? 0,
        '经历': counts['shared_experiences'] ?? 0,
        '附件': counts['attachments'] ?? 0,
      },
      lastBackup: backups.isEmpty ? null : backups.first,
    );
  }

  /// 完整性检查（数据库 quick_check + 附件 + 记忆索引）。
  Future<DataCenterIntegrity> runIntegrityCheck() async {
    final healthy = await _db.quickCheck();
    final integrity = await _attachments.checkIntegrity();
    final indexConsistent = await MemoryIndexWriter(_db).isConsistent();
    final row = await _db
        .customSelect('SELECT COUNT(*) AS c FROM content_index_terms')
        .getSingle();
    return DataCenterIntegrity(
      dbHealthy: healthy,
      orphanFiles: integrity.orphanFiles,
      missingRecordIds: integrity.missingRecords
          .map((a) => a.id)
          .toList(growable: false),
      indexConsistent: indexConsistent,
      contentIndexTerms: row.data['c'] as int? ?? 0,
    );
  }

  /// 重建全部派生索引（记忆索引 + 全局搜索倒排）。返回写入的搜索 token 行数。
  Future<({int memoryDocs, int contentTerms})> rebuildIndexes() async {
    final memoryDocs = await MemoryIndexWriter(_db).rebuildAll();
    final contentTerms = await _search.rebuildIndex();
    return (memoryDocs: memoryDocs, contentTerms: contentTerms);
  }

  /// 清理孤立附件文件（磁盘有文件但无数据库记录）。返回删除数量。
  Future<int> cleanupOrphanFiles() async {
    final integrity = await _attachments.checkIntegrity();
    var deleted = 0;
    for (final path in integrity.orphanFiles) {
      await _attachments.store.deleteFile(path);
      deleted++;
    }
    if (deleted > 0) {
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'cleanup',
              entityTable: 'attachments',
              entityId: 'orphans',
              afterDigest: Value('清理孤立附件文件 $deleted 个'),
              reason: const Value('完整性检查清理'),
              source: const Value('user'),
              at: _now(),
            ),
          );
    }
    return deleted;
  }

  /// 删除范围清单（三重门第一屏展示，不执行删除）。
  Future<Map<String, int>> deletionScope() async {
    final counts = await DatabaseSnapshot(_db).counts();
    return {
      '会话': counts['conversations'] ?? 0,
      '消息': counts['messages'] ?? 0,
      '附件': counts['attachments'] ?? 0,
      '人格版本': counts['persona_versions'] ?? 0,
      '记忆': counts['memories'] ?? 0,
      '记忆候选': counts['memory_candidates'] ?? 0,
      '说说': counts['posts'] ?? 0,
      '日记': counts['diaries'] ?? 0,
      '信件': counts['letters'] ?? 0,
      '经历': counts['shared_experiences'] ?? 0,
      '反馈': counts['feedback_records'] ?? 0,
      '思考产出': counts['thinking_results'] ?? 0,
      '主动记录': counts['proactive_actions'] ?? 0,
      '通知设置': counts['notification_settings'] ?? 0,
    };
  }

  /// 删除全部内容数据：内容表 → 附件文件 → 派生索引 → 回首次启动态。
  /// 保留 journal_logs / backup_records / migration_records / background_task_logs。
  Future<DeleteAllDataResult> deleteAllData({
    bool createSafetyBackup = true,
  }) async {
    final before = await DatabaseSnapshot(_db).counts();
    BackupArtifact? autoBackup;
    if (createSafetyBackup) {
      autoBackup = await _backup.createBackup(kind: BackupKind.auto);
    }

    final attachmentStore = _attachments.store;
    await attachmentStore.ensureReady();
    final files = await attachmentStore.listStoredRelPaths();

    await DatabaseSnapshot(_db).clearContentTables();

    // 附件磁盘文件一并删除（记录已随内容表清空）
    var filesDeleted = 0;
    for (final relPath in files) {
      await attachmentStore.deleteFile(relPath);
      filesDeleted++;
    }

    // 派生索引清空（内容已不存在）
    await _db.customStatement('DELETE FROM memory_index_terms');
    await _db.customStatement('DELETE FROM memory_index_docs');
    await _db.customStatement('DELETE FROM content_index_terms');

    // 回到首次启动引导态
    final nowIso = _now();
    await _db
        .into(_db.appSettings)
        .insert(
          AppSettingsCompanion.insert(
            key: 'app_first_run_done',
            value: const Value('0'),
            updatedAt: nowIso,
          ),
          mode: InsertMode.insertOrReplace,
        );

    await _db
        .into(_db.journalLogs)
        .insert(
          JournalLogsCompanion.insert(
            op: 'delete_all',
            entityTable: 'all_content',
            entityId: 'delete_all',
            beforeDigest: Value(
              '删除内容 ${before.values.fold(0, (s, v) => s + v)} 行 / '
              '$filesDeleted 个附件文件'
              '${autoBackup == null ? '' : '（删除前备份：${autoBackup.path}）'}',
            ),
            reason: const Value('用户删除全部数据（三重门确认）'),
            source: const Value('user'),
            at: nowIso,
          ),
        );

    return DeleteAllDataResult(
      deletedCounts: before,
      attachmentFilesDeleted: filesDeleted,
      autoBackup: autoBackup,
    );
  }

  /// 反馈摘要（数据中心/反馈历史页用）。
  Future<FeedbackSummary> feedbackSummary() =>
      FeedbackRepository(_db).summary();

  String _now() => _clock().toUtc().toIso8601String();
}
