// 主动行为仓储（T8.1）：候选池、执行记录、每日计数、设置持久化、反馈闭环。
// 依据 DATABASE_DESIGN §2.14~§2.15 / §2.21、REQUIREMENTS FR-DEC-02 / FR-FBK-01。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/proactive/proactive_models.dart';
import '../database/app_database.dart';

class ProactiveRepository {
  ProactiveRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  /// app_settings 键：主动行为设置（含反馈累计调整）
  static const settingsKey = 'proactive_settings';

  DateTime _now() => _clock();
  String _nowIso() => _now().toUtc().toIso8601String();

  static String _newId(String prefix) {
    final compact = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[-:TZ.]'),
      '',
    );
    return '${prefix}_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  // ------------------------------------------------------------ 设置

  Future<ProactiveSettings> loadSettings() async {
    final row =
        await (_db.select(_db.appSettings)
              ..where((t) => t.key.equals(settingsKey))
              ..limit(1))
            .getSingleOrNull();
    final raw = row?.value;
    if (raw == null || raw.trim().isEmpty) return const ProactiveSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ProactiveSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        return ProactiveSettings.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 配置损坏时回退默认（默认积极档，硬限制全保留）
    }
    return const ProactiveSettings();
  }

  Future<void> saveSettings(ProactiveSettings settings) async {
    final value = jsonEncode(settings.toJson());
    await _db
        .into(_db.appSettings)
        .insert(
          AppSettingsCompanion.insert(
            key: settingsKey,
            value: Value(value),
            updatedAt: _nowIso(),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }

  // ------------------------------------------------------------ 候选池

  Future<List<ProactiveCandidate>> pendingCandidates({int limit = 50}) {
    return (_db.select(_db.proactiveCandidates)
          ..where((t) => t.status.equals('pending'))
          ..orderBy([
            (t) => OrderingTerm.desc(t.priority),
            (t) => OrderingTerm.asc(t.createdAt),
          ])
          ..limit(limit))
        .get();
  }

  Future<List<ProactiveCandidate>> candidatesByStatus(
    String status, {
    int limit = 50,
  }) {
    return (_db.select(_db.proactiveCandidates)
          ..where((t) => t.status.equals(status))
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(limit))
        .get();
  }

  Future<ProactiveCandidate?> getCandidate(String id) => (_db.select(
    _db.proactiveCandidates,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 过期候选统一置 expired（决策运行前先扫描）
  Future<int> expireDueCandidates(int nowMs) async {
    final due =
        await (_db.select(_db.proactiveCandidates)..where(
              (t) =>
                  t.status.equals('pending') &
                  t.expiresAt.isSmallerOrEqualValue(nowMs),
            ))
            .get();
    if (due.isEmpty) return 0;
    final ids = due.map((e) => e.id).toList();
    await (_db.update(
      _db.proactiveCandidates,
    )..where((t) => t.id.isIn(ids))).write(
      ProactiveCandidatesCompanion(
        status: const Value('expired'),
        updatedAt: Value(_nowIso()),
      ),
    );
    return ids.length;
  }

  /// 顺延：保留 pending，仅记录最早可执行时间（不丢弃候选）
  Future<void> deferCandidate(
    String candidateId, {
    required int nextEligibleAtMs,
    required String note,
  }) async {
    await (_db.update(
      _db.proactiveCandidates,
    )..where((t) => t.id.equals(candidateId))).write(
      ProactiveCandidatesCompanion(
        cooldownUntil: Value(nextEligibleAtMs),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  Future<void> rejectCandidate(
    String candidateId, {
    required String note,
  }) async {
    await (_db.update(
      _db.proactiveCandidates,
    )..where((t) => t.id.equals(candidateId))).write(
      ProactiveCandidatesCompanion(
        status: const Value('rejected'),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  Future<void> cancelCandidate(String candidateId) async {
    await (_db.update(
      _db.proactiveCandidates,
    )..where((t) => t.id.equals(candidateId))).write(
      ProactiveCandidatesCompanion(
        status: const Value('cancelled'),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 候选更新（优先级/内容/状态等，用户手动修正用）
  Future<void> updateCandidate(
    String candidateId, {
    String? title,
    String? contentDraft,
    int? priority,
    String? status,
  }) async {
    await (_db.update(
      _db.proactiveCandidates,
    )..where((t) => t.id.equals(candidateId))).write(
      ProactiveCandidatesCompanion(
        title: title == null ? const Value.absent() : Value(title),
        contentDraft: contentDraft == null
            ? const Value.absent()
            : Value(contentDraft),
        priority: priority == null ? const Value.absent() : Value(priority),
        status: status == null ? const Value.absent() : Value(status),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  // ------------------------------------------------------------ 执行记录

  /// 记录一次执行：写 proactive_actions + 候选置 executed（同一事务）
  Future<ProactiveAction> recordExecution({
    required ProactiveCandidate candidate,
    required String decisionNote,
    String? deliverableType,
    String? deliverableId,
  }) async {
    final actionId = _newId('act');
    final nowMs = _now().millisecondsSinceEpoch;
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await _db
          .into(_db.proactiveActions)
          .insert(
            ProactiveActionsCompanion.insert(
              id: actionId,
              candidateId: candidate.id,
              actionKind: candidate.actionKind,
              executedAt: nowMs,
              deliverableType: Value(deliverableType),
              deliverableId: Value(deliverableId),
              decisionNote: Value(decisionNote),
              createdAt: nowIso,
            ),
          );
      await (_db.update(
        _db.proactiveCandidates,
      )..where((t) => t.id.equals(candidate.id))).write(
        ProactiveCandidatesCompanion(
          status: const Value('executed'),
          cooldownUntil: const Value(null),
          updatedAt: Value(nowIso),
        ),
      );
    });
    return (await (_db.select(
      _db.proactiveActions,
    )..where((t) => t.id.equals(actionId))).getSingle());
  }

  Future<List<ProactiveAction>> recentActions({int limit = 20}) {
    return (_db.select(_db.proactiveActions)
          ..orderBy([(t) => OrderingTerm.desc(t.executedAt)])
          ..limit(limit))
        .get();
  }

  /// 当日 0 点（本地时区）毫秒
  int startOfTodayMs() {
    final now = _now();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
  }

  Future<int> executedTodayTotal() async {
    final rows = await (_db.select(
      _db.proactiveActions,
    )..where((t) => t.executedAt.isBiggerOrEqualValue(startOfTodayMs()))).get();
    // 安静决策不计入「打扰次数」
    return rows.where((row) => row.actionKind != 'quiet').length;
  }

  Future<Map<String, int>> executedTodayByKind() async {
    final rows = await (_db.select(
      _db.proactiveActions,
    )..where((t) => t.executedAt.isBiggerOrEqualValue(startOfTodayMs()))).get();
    final counts = <String, int>{};
    for (final row in rows) {
      counts[row.actionKind] = (counts[row.actionKind] ?? 0) + 1;
    }
    return counts;
  }

  Future<int?> lastProactiveAtMs() async {
    final row =
        await (_db.select(_db.proactiveActions)
              ..where((t) => t.actionKind.equals('quiet').not())
              ..orderBy([(t) => OrderingTerm.desc(t.executedAt)])
              ..limit(1))
            .getSingleOrNull();
    return row?.executedAt;
  }

  /// 近期已执行候选（重复检测数据源）：近 [days] 天的内容与去重键
  Future<List<RecentProactiveOutput>> recentOutputs({int days = 30}) async {
    final cutoffIso = _now()
        .toUtc()
        .subtract(Duration(days: days))
        .toIso8601String();
    final rows =
        await (_db.select(_db.proactiveCandidates)
              ..where(
                (t) =>
                    t.status.equals('executed') &
                    t.updatedAt.isBiggerOrEqualValue(cutoffIso),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)]))
            .get();
    return rows
        .map(
          (row) => RecentProactiveOutput(
            kind: ProactiveActionKind.fromWire(row.actionKind),
            text: row.contentDraft ?? '',
            atMs: DateTime.tryParse(row.updatedAt)?.millisecondsSinceEpoch ?? 0,
            dedupKey: row.dedupKey,
          ),
        )
        .toList();
  }

  // ------------------------------------------------------------ 反馈闭环

  /// 记录用户对一次主动行为的反馈，并只调整优先级/冷却（不改核心人格）。
  Future<FeedbackRecord> recordFeedback({
    required String candidateId,
    required String actionId,
    required String verdict,
    String? note,
  }) async {
    final candidate = await getCandidate(candidateId);
    final kind = ProactiveActionKind.fromWire(candidate?.actionKind);
    final delta = _feedbackPriorityDelta(verdict);
    final multiplier = _feedbackCooldownMultiplier(verdict);

    final settings = await loadSettings();
    final current =
        settings.adjustments[kind.wire] ?? const ProactiveAdjustment();
    final updated = current.merge(
      priorityDelta: delta,
      cooldownMultiplier: multiplier,
    );
    final nextAdjustments = Map<String, ProactiveAdjustment>.from(
      settings.adjustments,
    );
    if (updated.priorityDelta == 0 && updated.cooldownMultiplier == 1.0) {
      nextAdjustments.remove(kind.wire);
    } else {
      nextAdjustments[kind.wire] = updated;
    }
    await saveSettings(settings.copyWith(adjustments: nextAdjustments));

    final feedbackId = _newId('fbk');
    final actionTaken = jsonEncode(<String, dynamic>{
      'kind': kind.wire,
      'priorityDelta': delta,
      'cooldownMultiplier': multiplier,
      'source': 'proactive_behavior',
    });
    final createdAt = _nowIso();
    await _db
        .into(_db.feedbackRecords)
        .insert(
          FeedbackRecordsCompanion.insert(
            id: feedbackId,
            targetKind: 'proactive_behavior',
            targetId: candidateId,
            verdict: verdict,
            note: Value(note),
            actionTaken: Value(actionTaken),
            createdAt: createdAt,
          ),
        );
    await (_db.update(_db.proactiveActions)
          ..where((t) => t.id.equals(actionId)))
        .write(ProactiveActionsCompanion(userFeedbackId: Value(feedbackId)));
    return (await (_db.select(
      _db.feedbackRecords,
    )..where((t) => t.id.equals(feedbackId))).getSingle());
  }

  Future<List<FeedbackRecord>> recentFeedback({int limit = 20}) {
    return (_db.select(_db.feedbackRecords)
          ..where((t) => t.targetKind.equals('proactive_behavior'))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  /// 撤销反馈：标记 reverted_at 并反向回滚优先级/冷却调整（保留历史）
  Future<void> revertFeedback(String feedbackId) async {
    final row = await (_db.select(
      _db.feedbackRecords,
    )..where((t) => t.id.equals(feedbackId))).getSingleOrNull();
    if (row == null || row.revertedAt != null) return;
    final raw = row.actionTaken;
    if (raw == null || raw.trim().isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    final kindWire = decoded['kind']?.toString() ?? '';
    final delta = (decoded['priorityDelta'] as num?)?.toInt() ?? 0;
    final multiplier =
        (decoded['cooldownMultiplier'] as num?)?.toDouble() ?? 1.0;

    final settings = await loadSettings();
    final current = settings.adjustments[kindWire];
    if (current != null) {
      final restored = ProactiveAdjustment(
        priorityDelta: (current.priorityDelta - delta).clamp(-50, 50),
        cooldownMultiplier: (current.cooldownMultiplier / multiplier).clamp(
          1.0,
          3.0,
        ),
      );
      final nextAdjustments = Map<String, ProactiveAdjustment>.from(
        settings.adjustments,
      );
      if (restored.priorityDelta == 0 && restored.cooldownMultiplier == 1.0) {
        nextAdjustments.remove(kindWire);
      } else {
        nextAdjustments[kindWire] = restored;
      }
      await saveSettings(settings.copyWith(adjustments: nextAdjustments));
    }

    await (_db.update(_db.feedbackRecords)
          ..where((t) => t.id.equals(feedbackId)))
        .write(FeedbackRecordsCompanion(revertedAt: Value(_nowIso())));
  }

  static int _feedbackPriorityDelta(String verdict) {
    switch (verdict) {
      case 'like':
        return 5;
      case 'dislike':
        return -10;
      case 'correct':
        return -15;
      default:
        return 0; // adjust
    }
  }

  static double _feedbackCooldownMultiplier(String verdict) {
    switch (verdict) {
      case 'dislike':
        return 1.5;
      case 'adjust':
        return 2.0;
      case 'correct':
        return 1.5;
      default:
        return 1.0;
    }
  }
}
