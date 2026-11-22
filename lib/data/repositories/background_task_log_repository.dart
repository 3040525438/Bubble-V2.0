// 后台任务日志仓储（T13.6，FR-IOS-07）：记录 submit/start/finish/fail/expired，
// 供无 Mac 环境下的真机取证与数据中心导出（阶段 14 接入数据中心入口）。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';

class BackgroundTaskLogRepository {
  BackgroundTaskLogRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// 保留 90 天（DATABASE_DESIGN §2.24）
  static const retention = Duration(days: 90);

  Future<BackgroundTaskLog> append({
    required String event,
    String? taskType,
    Map<String, dynamic>? payload,
    int? startedAt,
    int? finishedAt,
    int? nextSubmitAt,
  }) async {
    final id = _uuid.v4();
    await _db
        .into(_db.backgroundTaskLogs)
        .insert(
          BackgroundTaskLogsCompanion.insert(
            id: id,
            taskType: Value(taskType),
            event: Value(event),
            payload: Value(payload == null ? null : jsonEncode(payload)),
            startedAt: Value(startedAt),
            finishedAt: Value(finishedAt),
            nextSubmitAt: Value(nextSubmitAt),
          ),
        );
    return (await (_db.select(
      _db.backgroundTaskLogs,
    )..where((t) => t.id.equals(id))).getSingle());
  }

  Future<List<BackgroundTaskLog>> recent({int limit = 100}) {
    return (_db.select(_db.backgroundTaskLogs)
          ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
          ..limit(limit))
        .get();
  }

  /// 清理 90 天前日志（滚动保留，避免无限增长）
  Future<int> purgeExpired({DateTime? now}) async {
    final cutoff = (now ?? DateTime.now())
        .subtract(retention)
        .millisecondsSinceEpoch;
    return (_db.delete(
      _db.backgroundTaskLogs,
    )..where((t) => t.startedAt.isSmallerThanValue(cutoff))).go();
  }

  /// 导出为可读文本（每行一条 JSON；无 Mac 时经文件 App/爱思助手取出）
  Future<String> exportText({int limit = 500}) async {
    final rows = await recent(limit: limit);
    final buffer = StringBuffer();
    buffer.writeln('# 泡泡后台任务日志（最近 ${rows.length} 条）');
    buffer.writeln('# 导出时间：${DateTime.now().toIso8601String()}');
    for (final row in rows) {
      buffer.writeln(
        jsonEncode({
          'id': row.id,
          'event': row.event,
          'taskType': row.taskType,
          'payload': row.payload,
          'startedAt': row.startedAt,
          'finishedAt': row.finishedAt,
          'nextSubmitAt': row.nextSubmitAt,
        }),
      );
    }
    return buffer.toString();
  }

  Future<int> count() async {
    final rows = await _db.select(_db.backgroundTaskLogs).get();
    return rows.length;
  }
}
