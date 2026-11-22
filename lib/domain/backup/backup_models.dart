// 备份纯模型（T14.3）：目录包备份、校验与恢复对账。
// 依据 DATABASE_DESIGN §2.28、UI_PAGE_SPEC §37、MIGRATION_PLAN §3。
library;

/// 备份类型（对应 backup_records.kind）。
enum BackupKind {
  manual('manual', '手动备份'),
  auto('auto', '自动备份'),
  preMigration('pre_migration', '迁移前备份');

  const BackupKind(this.wire, this.label);

  final String wire;
  final String label;

  static BackupKind fromWire(String? value) {
    for (final k in BackupKind.values) {
      if (k.wire == value) return k;
    }
    return BackupKind.manual;
  }
}

/// 备份产物（对应 backup_records 行）。
class BackupArtifact {
  const BackupArtifact({
    required this.id,
    required this.kind,
    required this.path,
    required this.createdAt,
    this.sizeBytes,
    this.sha256,
    this.tableCounts = const {},
    this.dbSchemaVersion,
    this.verifiedAt,
    this.status = 'ok',
  });

  final String id;
  final BackupKind kind;

  /// 备份目录绝对路径（内含 data.json 与 attachments/）
  final String path;
  final String createdAt;
  final int? sizeBytes;
  final String? sha256;
  final Map<String, int> tableCounts;
  final int? dbSchemaVersion;
  final String? verifiedAt;

  /// ok / corrupt
  final String status;

  bool get isCorrupt => status == 'corrupt';

  DateTime? get createdAtTime => DateTime.tryParse(createdAt)?.toLocal();

  int get totalRows => tableCounts.values.fold(0, (sum, v) => sum + v);
}

/// 校验结果：sha256 一致 + 逐表行数对账。
class BackupVerification {
  const BackupVerification({
    required this.ok,
    this.error,
    this.expectedSha256,
    this.actualSha256,
    this.expectedCounts = const {},
    this.actualCounts = const {},
  });

  final bool ok;
  final String? error;
  final String? expectedSha256;
  final String? actualSha256;
  final Map<String, int> expectedCounts;
  final Map<String, int> actualCounts;

  bool get sha256Matched =>
      expectedSha256 != null && expectedSha256 == actualSha256;

  /// 逐表差异（表名 → 记录数差）。
  Map<String, int> get countDiffs {
    final keys = {...expectedCounts.keys, ...actualCounts.keys};
    final diffs = <String, int>{};
    for (final key in keys) {
      final diff = (expectedCounts[key] ?? 0) - (actualCounts[key] ?? 0);
      if (diff != 0) diffs[key] = diff;
    }
    return diffs;
  }

  bool get countsMatched => countDiffs.isEmpty;

  static BackupVerification failure(String error) =>
      BackupVerification(ok: false, error: error);
}

/// 恢复结果。
class RestoreResult {
  const RestoreResult({
    required this.ok,
    required this.autoBackupPath,
    this.restoredTables = 0,
    this.restoredRows = 0,
    this.error,
  });

  final bool ok;

  /// 恢复前自动生成的当前数据备份目录
  final String? autoBackupPath;
  final int restoredTables;
  final int restoredRows;
  final String? error;
}

/// 导出格式。
enum ExportFormat {
  json('json', 'JSON 全量'),
  markdown('markdown', 'Markdown 分域');

  const ExportFormat(this.wire, this.label);

  final String wire;
  final String label;
}

/// 导出结果。
class ExportResult {
  const ExportResult({
    required this.format,
    required this.paths,
    required this.byteSize,
  });

  final ExportFormat format;

  /// 生成的文件绝对路径（Markdown 一域一份）
  final List<String> paths;
  final int byteSize;
}
