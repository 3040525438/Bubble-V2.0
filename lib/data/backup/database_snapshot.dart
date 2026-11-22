// 数据库快照（T14.3）：逻辑备份的读写核心。
// 内容表 = 除派生索引（可重建）与系统审计表（永久保留）外的全部表；
// 恢复只覆盖内容表，审计表（journal/backup/migration/后台日志）永不被覆盖或清空。
import '../database/app_database.dart';

class DatabaseSnapshot {
  DatabaseSnapshot(this._db);

  final AppDatabase _db;

  /// 派生索引表：可重建，不参与备份与恢复。
  static const derivedTables = <String>{
    'memory_index_terms',
    'memory_index_docs',
    'content_index_terms',
  };

  /// 系统审计表：追加式记录，恢复/清空时一律保留。
  static const auditTables = <String>{
    'journal_logs',
    'backup_records',
    'migration_records',
    'background_task_logs',
  };

  /// 参与备份/恢复的内容表（按数据库声明顺序）。
  List<String> get contentTables => _db.allTables
      .map((t) => t.actualTableName)
      .where(
        (name) => !derivedTables.contains(name) && !auditTables.contains(name),
      )
      .toList(growable: false);

  /// 导出全部内容表为 表名 → 行数组。
  Future<Map<String, List<Map<String, Object?>>>> dump() async {
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in contentTables) {
      final rows = await _db.customSelect('SELECT * FROM "$table"').get();
      result[table] = rows
          .map((r) => Map<String, Object?>.from(r.data))
          .toList(growable: false);
    }
    return result;
  }

  /// 各内容表行数快照（对账依据）。
  Future<Map<String, int>> counts() async {
    final result = <String, int>{};
    for (final table in contentTables) {
      final row = await _db
          .customSelect('SELECT COUNT(*) AS c FROM "$table"')
          .getSingle();
      result[table] = row.data['c'] as int? ?? 0;
    }
    return result;
  }

  /// 单表行数（删除范围清单展示用）。
  Future<int> countOf(String table) async {
    if (!contentTables.contains(table)) return 0;
    final row = await _db
        .customSelect('SELECT COUNT(*) AS c FROM "$table"')
        .getSingle();
    return row.data['c'] as int? ?? 0;
  }

  /// 清空全部内容表（保留派生索引与审计表，由调用方决定是否重建索引）。
  Future<void> clearContentTables() async {
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        for (final table in contentTables) {
          await _db.customStatement('DELETE FROM "$table"');
        }
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
  }

  /// 用快照覆盖内容表（未知表与审计表/派生表的数据被忽略）。
  Future<({int tables, int rows})> restore(
    Map<String, List<Map<String, Object?>>> data,
  ) async {
    final allowed = contentTables.toSet();
    var tables = 0;
    var rows = 0;
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        for (final table in allowed) {
          await _db.customStatement('DELETE FROM "$table"');
        }
        for (final entry in data.entries) {
          if (!allowed.contains(entry.key)) continue;
          var written = 0;
          for (final row in entry.value) {
            if (row.isEmpty) continue;
            final columns = row.keys.toList(growable: false);
            final columnList = columns.map((c) => '"$c"').join(',');
            final placeholders = List.filled(columns.length, '?').join(',');
            await _db.customStatement(
              'INSERT OR REPLACE INTO "${entry.key}" '
              '($columnList) VALUES ($placeholders)',
              row.values.toList(growable: false),
            );
            written++;
          }
          if (written > 0) {
            tables++;
            rows += written;
          }
        }
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
    return (tables: tables, rows: rows);
  }
}
