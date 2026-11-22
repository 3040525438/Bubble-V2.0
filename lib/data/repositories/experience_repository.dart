// 共同经历仓储（T9.1/T9.2）：历史事实只写一次、视角可补、回顾只追加、记忆/思考提名。
// 依据 DATABASE_DESIGN §2.17、REQUIREMENTS FR-EXP-01~04。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/experience/experience_models.dart';
import '../database/app_database.dart';

class ExperienceRepository {
  ExperienceRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  DateTime _now() => _clock();
  String _nowIso() => _now().toUtc().toIso8601String();

  static String _newId() {
    final compact = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[-:TZ.]'),
      '',
    );
    return 'exp_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  static int _msOf(String iso) =>
      DateTime.tryParse(iso)?.millisecondsSinceEpoch ?? 0;

  // ------------------------------------------------------------ 创建与读取

  Future<SharedExperience> createExperience(ExperienceDraft draft) async {
    final error = ExperienceRules.validateDraft(draft);
    if (error != null) {
      throw ArgumentError(error);
    }
    final id = _newId();
    final nowIso = _nowIso();
    await _db
        .into(_db.sharedExperiences)
        .insert(
          SharedExperiencesCompanion.insert(
            id: id,
            name: draft.name.trim(),
            occurredAt: draft.occurredAtMs,
            eventContent: draft.eventContent.trim(),
            relatedConversationIds: Value(
              draft.relatedConversationIds.isEmpty
                  ? null
                  : jsonEncode(draft.relatedConversationIds),
            ),
            relatedMemoryIds: Value(
              draft.relatedMemoryIds.isEmpty
                  ? null
                  : jsonEncode(draft.relatedMemoryIds),
            ),
            importance: Value(draft.importance),
            userPerspective: Value(draft.userPerspective),
            bubblePerspective: Value(draft.bubblePerspective),
            reviewLog: const Value(null),
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
    return (await getExperience(id))!;
  }

  Future<SharedExperience?> getExperience(String id) => (_db.select(
    _db.sharedExperiences,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<SharedExperience>> listExperiences({int limit = 100}) {
    return (_db.select(_db.sharedExperiences)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.occurredAt),
            (t) => OrderingTerm.desc(t.importance),
          ])
          ..limit(limit))
        .get();
  }

  Future<int> countExperiences() async {
    final rows = await (_db.select(
      _db.sharedExperiences,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.length;
  }

  // ------------------------------------------------------------ 视角 / 回顾 / 关联

  /// 只更新双视角：历史事实字段不在写入范围内（防篡改）
  Future<void> updatePerspectives(
    String id, {
    String? userPerspective,
    String? bubblePerspective,
  }) async {
    await (_db.update(
      _db.sharedExperiences,
    )..where((t) => t.id.equals(id))).write(
      SharedExperiencesCompanion(
        userPerspective: userPerspective == null
            ? const Value.absent()
            : Value(userPerspective.trim()),
        bubblePerspective: bubblePerspective == null
            ? const Value.absent()
            : Value(bubblePerspective.trim()),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 追加一条回顾记录（只追加，不提供修改/删除接口）
  Future<SharedExperience> appendReview(
    String id,
    ExperienceReviewEntry entry,
  ) async {
    final row = await getExperience(id);
    if (row == null) throw StateError('经历不存在：$id');
    final existing = ExperienceRules.parseReviewLog(row.reviewLog);
    final next = ExperienceRules.appendReview(existing, entry);
    await (_db.update(
      _db.sharedExperiences,
    )..where((t) => t.id.equals(id))).write(
      SharedExperiencesCompanion(
        reviewLog: Value(ExperienceRules.encodeReviewLog(next)),
        updatedAt: Value(_nowIso()),
      ),
    );
    return (await getExperience(id))!;
  }

  Future<void> relate(
    String id, {
    List<String>? memoryIds,
    List<String>? conversationIds,
  }) async {
    await (_db.update(
      _db.sharedExperiences,
    )..where((t) => t.id.equals(id))).write(
      SharedExperiencesCompanion(
        relatedMemoryIds: memoryIds == null
            ? const Value.absent()
            : Value(memoryIds.isEmpty ? null : jsonEncode(memoryIds)),
        relatedConversationIds: conversationIds == null
            ? const Value.absent()
            : Value(
                conversationIds.isEmpty ? null : jsonEncode(conversationIds),
              ),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  Future<void> softDelete(String id) async {
    await (_db.update(
      _db.sharedExperiences,
    )..where((t) => t.id.equals(id))).write(
      SharedExperiencesCompanion(
        deletedAt: Value(_nowIso()),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  // ------------------------------------------------------------ 自动提名

  /// 从记忆流提名值得记为共同经历的内容（只提名，不落库）
  Future<List<ExperienceNomination>> nominateFromMemories({
    int limit = 10,
  }) async {
    final experiences = await (_db.select(
      _db.sharedExperiences,
    )..where((t) => t.deletedAt.isNull())).get();
    final usedMemoryIds = <String>{};
    for (final experience in experiences) {
      usedMemoryIds.addAll(_decodeIds(experience.relatedMemoryIds));
    }

    final rows =
        await (_db.select(_db.memories)
              ..where(
                (t) =>
                    t.deletedAt.isNull() &
                    t.status.equals('active') &
                    t.type.isIn(const ['experience_joint', 'event']) &
                    t.sensitivity.isNull(),
              )
              ..orderBy([
                (t) => OrderingTerm.desc(t.importance),
                (t) => OrderingTerm.desc(t.updatedAt),
              ])
              ..limit(limit * 3))
            .get();

    final nominations = <ExperienceNomination>[];
    for (final row in rows) {
      if (usedMemoryIds.contains(row.id)) continue;
      final summary = row.summary.trim();
      if (summary.isEmpty) continue;
      final title = (row.title ?? '').trim();
      nominations.add(
        ExperienceNomination(
          sourceKind: 'memory',
          sourceId: row.id,
          suggestedName: title.isEmpty ? _shortName(summary) : title,
          occurredAtMs: _msOf(row.createdAt),
          eventContent: summary,
          reason: row.type == 'experience_joint'
              ? '这段共同经历还没有写进时间线'
              : '这件发生过的事也许值得一起记住',
          importance: row.importance,
          relatedMemoryIds: [row.id],
        ),
      );
      if (nominations.length >= limit) break;
    }
    return nominations;
  }

  /// 从思考产出提名（share_worthy / reunderstanding 且带记忆引用）
  Future<List<ExperienceNomination>> nominateFromThinking({
    int limit = 5,
  }) async {
    final rows =
        await (_db.select(_db.thinkingResults)
              ..where(
                (t) => t.resultKind.isIn(const [
                  'share_worthy',
                  'reunderstanding',
                ]),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(limit * 2))
            .get();
    final nominations = <ExperienceNomination>[];
    for (final row in rows) {
      final memoryIds = _decodeIds(row.relatedMemoryIds);
      if (memoryIds.isEmpty) continue;
      final content = row.content.trim();
      if (content.isEmpty) continue;
      nominations.add(
        ExperienceNomination(
          sourceKind: 'thinking',
          sourceId: row.id,
          suggestedName: _shortName(content),
          occurredAtMs: _msOf(row.createdAt),
          eventContent: content,
          reason: '泡泡在回顾时觉得这段值得记住',
          importance: 60,
          relatedMemoryIds: memoryIds,
        ),
      );
      if (nominations.length >= limit) break;
    }
    return nominations;
  }

  /// 用户确认提名后创建共同经历
  Future<SharedExperience> createFromNomination(
    ExperienceNomination nomination, {
    String? name,
    String? eventContent,
  }) {
    final draft = nomination.toDraft();
    return createExperience(
      ExperienceDraft(
        name: (name ?? '').trim().isEmpty ? draft.name : name!.trim(),
        occurredAtMs: draft.occurredAtMs <= 0
            ? _now().millisecondsSinceEpoch
            : draft.occurredAtMs,
        eventContent: (eventContent ?? '').trim().isEmpty
            ? draft.eventContent
            : eventContent!.trim(),
        relatedMemoryIds: draft.relatedMemoryIds,
        importance: draft.importance,
      ),
    );
  }

  static String _shortName(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 14) return cleaned;
    return '${cleaned.substring(0, 14)}…';
  }

  static List<String> _decodeIds(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 忽略损坏的关联字段
    }
    return const <String>[];
  }
}
