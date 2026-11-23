// 迁移纯模型（T14.5）：预演报告、批次结果、对账与回滚。
// 依据 MIGRATION_PLAN §2/§3、UI_PAGE_SPEC §26、REQUIREMENTS FR-MIG-01/02。
library;

/// 迁移分类（对应 migration_records.category）。
enum MigrationCategory {
  chat('chat', '聊天消息'),
  persona('persona', '人格提示词'),
  relation('relation', '关系设定'),
  memory('memory', '长期记忆'),
  post('post', '说说'),
  diary('diary', '日记'),
  letter('letter', '信件'),
  bookNote('book_note', '读书笔记'),
  experience('experience', '共同经历'),
  attachment('attachment', '图片附件'),
  config('config', '可复用配置'),
  archive('archive', '插件资料');

  const MigrationCategory(this.wire, this.label);

  final String wire;
  final String label;

  static MigrationCategory? fromWire(String? value) {
    for (final c in MigrationCategory.values) {
      if (c.wire == value) return c;
    }
    return null;
  }
}

/// 预演报告的单项（每类源一行）。
class MigrationDryRunEntry {
  const MigrationDryRunEntry({
    required this.category,
    required this.sourceCount,
    required this.importable,
    this.skipped = 0,
    this.needsManual = 0,
    this.note,
  });

  final MigrationCategory category;

  /// 源数据条数
  final int sourceCount;

  /// 可自动导入条数
  final int importable;

  /// 预计跳过条数（重复/无效/源文件缺失）
  final int skipped;

  /// 需人工选择条数（如人格冲突）
  final int needsManual;
  final String? note;

  bool get hasData => sourceCount > 0;
}

/// 预演报告。
class MigrationDryRun {
  const MigrationDryRun({
    required this.sourceRoot,
    required this.entries,
    required this.sourceAvailable,
    this.generatedAt,
  });

  final String sourceRoot;
  final List<MigrationDryRunEntry> entries;

  /// 源目录是否可读（不可读时 entries 为空并提示）
  final bool sourceAvailable;
  final String? generatedAt;

  int importableOf(MigrationCategory category) {
    for (final e in entries) {
      if (e.category == category) return e.importable;
    }
    return 0;
  }

  int get totalImportable => entries.fold(0, (sum, e) => sum + e.importable);

  int get totalSkipped => entries.fold(0, (sum, e) => sum + e.skipped);

  bool get hasManualConflicts => entries.any((e) => e.needsManual > 0);

  bool get hasAnything => totalImportable > 0;

  static MigrationDryRun unavailable(String sourceRoot) => MigrationDryRun(
    sourceRoot: sourceRoot,
    entries: const [],
    sourceAvailable: false,
  );
}

/// 正式导入结果。
class ImportBatchResult {
  const ImportBatchResult({
    required this.batchId,
    required this.imported,
    required this.skipped,
    required this.needsManual,
    required this.failed,
    required this.startedAt,
    required this.finishedAt,
    this.errors = const [],
    this.preMigrationBackupPath,
  });

  final String batchId;
  final Map<MigrationCategory, int> imported;
  final Map<MigrationCategory, int> skipped;
  final Map<MigrationCategory, int> needsManual;
  final int failed;
  final String startedAt;
  final String finishedAt;

  /// 前 20 条失败原因（完整记录在 migration_records）
  final List<String> errors;

  final String? preMigrationBackupPath;

  int get importedTotal => imported.values.fold(0, (s, v) => s + v);

  int get skippedTotal => skipped.values.fold(0, (s, v) => s + v);
}

/// 对账单行。
class ReconcileRow {
  const ReconcileRow({
    required this.category,
    required this.recordCount,
    required this.targetCount,
    required this.verifiedCount,
  });

  final MigrationCategory category;

  /// migration_records 中该批次的 migrated 记录数
  final int recordCount;

  /// 目标表中这些 target_id 实际存在的行数
  final int targetCount;

  /// migration_records 中 status=verified 的数量
  final int verifiedCount;

  bool get matched => recordCount == targetCount;
}

/// 三向对账报告（源/目标/记录）。
class ReconcileReport {
  const ReconcileReport({
    required this.batchId,
    required this.rows,
    required this.ok,
  });

  final String batchId;
  final List<ReconcileRow> rows;
  final bool ok;

  int get totalRecords => rows.fold(0, (s, r) => s + r.recordCount);

  int get totalTargets => rows.fold(0, (s, r) => s + r.targetCount);
}

/// 回滚结果。
class RollbackResult {
  const RollbackResult({
    required this.batchId,
    required this.affectedRecords,
    required this.softDeleted,
    required this.hardDeleted,
    this.error,
  });

  final String batchId;
  final int affectedRecords;
  final int softDeleted;
  final int hardDeleted;
  final String? error;

  bool get ok => error == null;
}
