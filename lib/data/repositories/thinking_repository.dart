// 思考仓储（T7.1）：任务状态与检查点、想法史（thinking_results）、主动候选落库。
// 依据 DATABASE_DESIGN §2.12~§2.14；想法永久保留，候选由阶段 8 决策中心消费。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/thinking/thinking_models.dart';
import '../database/app_database.dart';

class ThinkingRepository {
  ThinkingRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  static String _newTaskId() {
    final compact = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[-:TZ.]'), '');
    return 'thk_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  // ------------------------------------------------------------ 任务

  Future<ThinkingTask> createTask({
    required String trigger,
    String initialState = 'loading',
    String? scopeNote,
  }) async {
    final id = _newTaskId();
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.into(_db.thinkingTasks).insert(ThinkingTasksCompanion.insert(
          id: id,
          trigger: Value(trigger),
          state: Value(initialState),
          scopeNote: Value(scopeNote),
          startedAt: Value(now),
          checkpoint: const Value(null),
        ));
    return (await getTask(id))!;
  }

  Future<ThinkingTask?> getTask(String id) =>
      (_db.select(_db.thinkingTasks)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  Future<ThinkingTask?> latestTask() => (_db.select(_db.thinkingTasks)
        ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
        ..limit(1))
      .getSingleOrNull();

  Future<List<ThinkingTask>> listTasks({int limit = 20}) =>
      (_db.select(_db.thinkingTasks)
            ..orderBy([(t) => OrderingTerm.desc(t.startedAt)])
            ..limit(limit))
          .get();

  /// 非终态任务（启动/回前台恢复扫描，FR-IOS-07）
  Future<List<ThinkingTask>> resumableTasks() => (_db.select(_db.thinkingTasks)
        ..where((t) =>
            t.state.isIn(const [
              'created',
              'loading',
              'reviewing',
              'analyzing',
              'saving',
              'deciding',
              'interrupted',
            ]))
        ..orderBy([(t) => OrderingTerm.asc(t.startedAt)]))
      .get();

  Future<void> updateTask(
    String taskId, {
    String? state,
    ThinkingCheckpoint? checkpoint,
    int? reviewedUntil,
    int? finishedAt,
    int? interruptedAt,
    int? resultCount,
    String? scopeNote,
  }) async {
    await (_db.update(_db.thinkingTasks)
          ..where((t) => t.id.equals(taskId)))
        .write(ThinkingTasksCompanion(
      state: state == null ? const Value.absent() : Value(state),
      checkpoint: checkpoint == null
          ? const Value.absent()
          : Value(jsonEncode(checkpoint.toJson())),
      reviewedUntil: reviewedUntil == null
          ? const Value.absent()
          : Value(reviewedUntil),
      finishedAt:
          finishedAt == null ? const Value.absent() : Value(finishedAt),
      interruptedAt:
          interruptedAt == null ? const Value.absent() : Value(interruptedAt),
      resultCount:
          resultCount == null ? const Value.absent() : Value(resultCount),
      scopeNote: scopeNote == null ? const Value.absent() : Value(scopeNote),
    ));
  }

  // ------------------------------------------------------------ 想法史

  /// 结果 id 由任务+序号确定，重复写入自动忽略（恢复幂等）。
  Future<bool> insertResult({
    required String id,
    required String taskId,
    required ThinkingInsight insight,
    required String createdAt,
    String? forcedContent,
  }) async {
    await _db.into(_db.thinkingResults).insert(
          ThinkingResultsCompanion.insert(
            id: id,
            taskId: taskId,
            resultKind: insight.kind.wire,
            content: forcedContent ?? insight.content,
            relatedMemoryIds: Value(insight.relatedMemoryIds.isEmpty
                ? null
                : jsonEncode(insight.relatedMemoryIds)),
            relatedMessageIds: Value(insight.relatedMessageIds.isEmpty
                ? null
                : jsonEncode(insight.relatedMessageIds)),
            confidence: Value(insight.confidence),
            createdAt: createdAt,
          ),
          mode: InsertMode.insertOrIgnore,
        );
    return true;
  }

  Future<List<ThinkingResult>> listResults({int limit = 50, String? kind}) {
    final query = _db.select(_db.thinkingResults)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit);
    if (kind != null) query.where((t) => t.resultKind.equals(kind));
    return query.get();
  }

  Future<int> countResults(String taskId) async {
    final rows = await (_db.select(_db.thinkingResults)
          ..where((t) => t.taskId.equals(taskId)))
        .get();
    return rows.length;
  }

  /// 内容级判重（跨任务），避免同一想法反复入库。
  Future<bool> hasResultContent(String content) async {
    final row = await (_db.select(_db.thinkingResults)
          ..where((t) => t.content.equals(content))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  // ------------------------------------------------------------ 主动候选

  Future<bool> hasCandidateDedup(String dedupKey) async {
    final row = await (_db.select(_db.proactiveCandidates)
          ..where((t) => t.dedupKey.equals(dedupKey))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  Future<void> insertCandidate({
    required String id,
    required ThinkingInsight insight,
    required String relatedTaskId,
    required int expiresAt,
  }) async {
    final now = _nowIso();
    await _db.into(_db.proactiveCandidates).insert(
          ProactiveCandidatesCompanion.insert(
            id: id,
            actionKind: Value(insight.actionKind.wire),
            title: Value(insight.title ?? insight.kind.label),
            contentDraft: Value(insight.content),
            sourceKind: Value(insight.sourceKind),
            relatedMemoryIds: Value(insight.relatedMemoryIds.isEmpty
                ? null
                : jsonEncode(insight.relatedMemoryIds)),
            relatedTaskId: Value(relatedTaskId),
            priority: Value(insight.priority),
            status: const Value('pending'),
            dedupKey: Value(insight.effectiveDedupKey),
            expiresAt: Value(expiresAt),
            createdAt: now,
            updatedAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  Future<List<ProactiveCandidate>> listCandidates(
      {String status = 'pending'}) {
    return (_db.select(_db.proactiveCandidates)
          ..where((t) => t.status.equals(status))
          ..orderBy([(t) => OrderingTerm.desc(t.priority)]))
        .get();
  }
}
