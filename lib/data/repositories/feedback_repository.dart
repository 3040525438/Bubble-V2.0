// 反馈仓储（T14.2）：记录、历史、撤销与统计；撤销写 journal_logs 留痕。
// 依据 DATABASE_DESIGN §2.21、REQUIREMENTS FR-FBK-01/02。
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/feedback/feedback_models.dart';
import '../database/app_database.dart';

class FeedbackRepository {
  FeedbackRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  static String _newId() {
    final compact = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[-:TZ.]'),
      '',
    );
    return 'fb_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  String _nowIso() => _clock().toUtc().toIso8601String();

  /// 记录一条反馈。返回落库后的视图对象。
  Future<FeedbackEntry> record({
    required FeedbackTargetKind kind,
    required String targetId,
    required FeedbackVerdict verdict,
    String? note,
    String? actionTaken,
  }) async {
    final error = validateFeedback(
      kind: kind,
      targetId: targetId,
      verdict: verdict,
      note: note,
    );
    if (error != null) throw ArgumentError(error);

    final id = _newId();
    final nowIso = _nowIso();
    final trimmedNote = note?.trim();
    await _db.transaction(() async {
      await _db
          .into(_db.feedbackRecords)
          .insert(
            FeedbackRecordsCompanion.insert(
              id: id,
              targetKind: kind.wire,
              targetId: targetId.trim(),
              verdict: verdict.wire,
              note: Value(
                trimmedNote == null || trimmedNote.isEmpty ? null : trimmedNote,
              ),
              actionTaken: Value(actionTaken),
              createdAt: nowIso,
            ),
          );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'create',
              entityTable: 'feedback_records',
              entityId: id,
              afterDigest: Value(
                '${kind.label}·${verdict.label}'
                '${trimmedNote == null || trimmedNote.isEmpty ? '' : '：$trimmedNote'}',
              ),
              reason: const Value('用户反馈'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await byId(id))!;
  }

  Future<FeedbackEntry?> byId(String id) async {
    final row = await (_db.select(
      _db.feedbackRecords,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _toEntry(row);
  }

  /// 最近反馈（默认含已撤销）；可按目标类型过滤。
  Future<List<FeedbackEntry>> recent({
    int limit = 100,
    FeedbackTargetKind? kind,
    bool includeReverted = true,
  }) async {
    final query = _db.select(_db.feedbackRecords)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit);
    if (kind != null) query.where((t) => t.targetKind.equals(kind.wire));
    if (!includeReverted) query.where((t) => t.revertedAt.isNull());
    final rows = await query.get();
    return rows.map(_toEntry).toList(growable: false);
  }

  /// 某目标的历史反馈（倒序）。
  Future<List<FeedbackEntry>> historyOf(
    FeedbackTargetKind kind,
    String targetId, {
    int limit = 50,
  }) async {
    final rows =
        await (_db.select(_db.feedbackRecords)
              ..where(
                (t) =>
                    t.targetKind.equals(kind.wire) &
                    t.targetId.equals(targetId),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(limit))
            .get();
    return rows.map(_toEntry).toList(growable: false);
  }

  /// 某目标最新一条未撤销反馈（无则 null）。
  Future<FeedbackEntry?> latestFor(
    FeedbackTargetKind kind,
    String targetId,
  ) async {
    final row =
        await (_db.select(_db.feedbackRecords)
              ..where(
                (t) =>
                    t.targetKind.equals(kind.wire) &
                    t.targetId.equals(targetId) &
                    t.revertedAt.isNull(),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(1))
            .getSingleOrNull();
    return row == null ? null : _toEntry(row);
  }

  /// 撤销一条反馈（幂等：已撤销则直接返回当前状态）。
  Future<FeedbackEntry> revert(String id) async {
    final before = await byId(id);
    if (before == null) throw StateError('反馈不存在：$id');
    if (before.isReverted) return before;
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await (_db.update(_db.feedbackRecords)..where((t) => t.id.equals(id)))
          .write(FeedbackRecordsCompanion(revertedAt: Value(nowIso)));
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'update',
              entityTable: 'feedback_records',
              entityId: id,
              beforeDigest: Value(
                '${before.targetKind.label}·${before.verdict.label}',
              ),
              afterDigest: const Value('已撤销'),
              reason: const Value('用户撤销反馈'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await byId(id))!;
  }

  /// 反馈统计（总数/生效/已撤销/分类计数）。
  Future<FeedbackSummary> summary() async {
    final rows = await _db.select(_db.feedbackRecords).get();
    if (rows.isEmpty) return FeedbackSummary.empty();
    final byKind = <FeedbackTargetKind, int>{};
    var reverted = 0;
    for (final row in rows) {
      final kind = FeedbackTargetKind.fromWire(row.targetKind);
      if (kind != null) {
        byKind[kind] = (byKind[kind] ?? 0) + 1;
      }
      if (row.revertedAt != null) reverted++;
    }
    return FeedbackSummary(
      total: rows.length,
      active: rows.length - reverted,
      reverted: reverted,
      byKind: byKind,
    );
  }

  static FeedbackEntry _toEntry(FeedbackRecord row) {
    return FeedbackEntry(
      id: row.id,
      targetKind:
          FeedbackTargetKind.fromWire(row.targetKind) ??
          FeedbackTargetKind.expressionStyle,
      targetId: row.targetId,
      verdict: FeedbackVerdict.fromWire(row.verdict) ?? FeedbackVerdict.like,
      createdAt: row.createdAt,
      note: row.note,
      actionTaken: row.actionTaken,
      revertedAt: row.revertedAt,
    );
  }
}
