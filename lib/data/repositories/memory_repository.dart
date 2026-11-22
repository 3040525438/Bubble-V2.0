// 记忆仓储（T5.2）：生命周期、版本回放、关联、收件箱、冲突裁决与索引维护。
// 依据 DATABASE_DESIGN §2.8~§2.11、MEMORY_DESIGN §2~§6、REQUIREMENTS FR-MEM-03~06。
// 铁律：模型/规则只能提候选；所有写入经本仓储校验；索引是派生数据可重建。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/memory/memory_context.dart';
import '../../domain/memory/memory_engine.dart';
import '../../domain/memory/memory_models.dart';
import '../../domain/search/tokenizer.dart';
import '../database/app_database.dart';
import '../search/memory_index.dart';

/// 收件箱/总览计数
class MemoryCounts {
  const MemoryCounts({
    required this.inbox,
    required this.conflicts,
    required this.resident,
    required this.active,
    required this.total,
  });

  final int inbox;
  final int conflicts;
  final int resident;
  final int active;
  final int total;
}

/// 写入结果
class IngestResult {
  const IngestResult({
    required this.candidateId,
    required this.compareKind,
    required this.autoApplied,
    required this.secretRejected,
    this.memoryId,
  });

  final String candidateId;
  final CompareKind compareKind;
  final bool autoApplied;
  final bool secretRejected;
  final String? memoryId;
}

/// 关联记忆视图
class MemoryRelationEntry {
  const MemoryRelationEntry({required this.relation, required this.other});

  final MemoryRelation relation;
  final Memory other;
}

/// 记忆仓储
class MemoryRepository {
  MemoryRepository(
    this._db, {
    this.engine = const MemoryEngine(),
    this.renderer = const MemoryContextRenderer(),
    MemoryIndexWriter? indexWriter,
  }) : _index = indexWriter ?? MemoryIndexWriter(_db);

  final AppDatabase _db;
  final MemoryEngine engine;
  final MemoryContextRenderer renderer;
  final MemoryIndexWriter _index;

  static const _uuid = Uuid();

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  static String _newMemoryId() {
    final compact =
        DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[-:TZ.]'), '');
    return 'mem_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  // ------------------------------------------------------------ 读取

  Future<Memory?> getMemory(String id) =>
      (_db.select(_db.memories)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Memory>> listMemories({
    String? status,
    String? type,
    String? query,
    int limit = 300,
  }) async {
    List<Memory> rows;
    if (query != null && query.trim().isNotEmpty) {
      rows = await searchMemories(query, limit: limit);
    } else {
      final select = _db.select(_db.memories)
        ..where((t) => t.deletedAt.isNull());
      if (status != null) select.where((t) => t.status.equals(status));
      if (type != null) select.where((t) => t.type.equals(type));
      select
        ..orderBy([
          (t) => OrderingTerm.desc(t.pinned),
          (t) => OrderingTerm.desc(t.updatedAt),
        ])
        ..limit(limit);
      rows = await select.get();
    }
    if (status != null) {
      rows = rows.where((m) => m.status == status).toList();
    }
    if (type != null) {
      rows = rows.where((m) => m.type == type).toList();
    }
    return rows;
  }

  /// 倒排检索：token 命中加权 + 重要度/置顶加成。
  Future<List<Memory>> searchMemories(String query, {int limit = 100}) async {
    final tokens = tokenize(query).toSet().take(64).toList();
    if (tokens.isEmpty) return const <Memory>[];
    final terms = await (_db.select(_db.memoryIndexTerms)
          ..where((t) => t.token.isIn(tokens)))
        .get();
    if (terms.isEmpty) return const <Memory>[];
    final scores = <String, double>{};
    for (final term in terms) {
      scores[term.docId] = (scores[term.docId] ?? 0) + term.fieldWeight;
    }
    final memories = await (_db.select(_db.memories)
          ..where((t) => t.id.isIn(scores.keys.toList()) & t.deletedAt.isNull()))
        .get();
    memories.sort((a, b) {
      final scoreA = (scores[a.id] ?? 0) + a.importance / 10 + a.pinned * 20;
      final scoreB = (scores[b.id] ?? 0) + b.importance / 10 + b.pinned * 20;
      return scoreB.compareTo(scoreA);
    });
    return memories.take(limit).toList();
  }

  Future<List<MemoryCandidate>> listCandidates({String status = 'pending'}) {
    return (_db.select(_db.memoryCandidates)
          ..where((t) => t.status.equals(status))
          ..orderBy([(t) => OrderingTerm.desc(t.expiresAt)]))
        .get();
  }

  Future<MemoryCandidate?> getCandidate(String id) =>
      (_db.select(_db.memoryCandidates)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  Future<List<MemoryVersion>> versionsOf(String memoryId) {
    return (_db.select(_db.memoryVersions)
          ..where((t) => t.memoryId.equals(memoryId))
          ..orderBy([(t) => OrderingTerm.desc(t.versionNo)]))
        .get();
  }

  Future<List<MemoryRelationEntry>> relationsOf(String memoryId) async {
    final outgoing = await (_db.select(_db.memoryRelations)
          ..where((t) => t.fromMemoryId.equals(memoryId)))
        .get();
    final incoming = await (_db.select(_db.memoryRelations)
          ..where((t) => t.toMemoryId.equals(memoryId)))
        .get();
    final otherIds = <String>{
      ...outgoing.map((r) => r.toMemoryId),
      ...incoming.map((r) => r.fromMemoryId),
    };
    if (otherIds.isEmpty) return const <MemoryRelationEntry>[];
    final others = await (_db.select(_db.memories)
          ..where((t) => t.id.isIn(otherIds.toList())))
        .get();
    final byId = {for (final m in others) m.id: m};
    final entries = <MemoryRelationEntry>[];
    for (final relation in outgoing) {
      final other = byId[relation.toMemoryId];
      if (other != null) entries.add(MemoryRelationEntry(relation: relation, other: other));
    }
    for (final relation in incoming) {
      final other = byId[relation.fromMemoryId];
      if (other != null) entries.add(MemoryRelationEntry(relation: relation, other: other));
    }
    return entries;
  }

  Future<MemoryCounts> counts() async {
    final rows = await (_db.select(_db.memories)
          ..where((t) => t.deletedAt.isNull()))
        .get();
    var active = 0;
    var conflicts = 0;
    var resident = 0;
    for (final memory in rows) {
      if (memory.status == MemoryStatus.active.wire) active++;
      if (memory.status == MemoryStatus.conflict.wire) conflicts++;
      if (memory.isResident == 1 || memory.pinned == 1) resident++;
    }
    final inboxQuery = _db.selectOnly(_db.memoryCandidates)
      ..addColumns([_db.memoryCandidates.id.count()])
      ..where(_db.memoryCandidates.status.equals('pending'));
    final inboxRow = await inboxQuery.getSingle();
    return MemoryCounts(
      inbox: inboxRow.read(_db.memoryCandidates.id.count()) ?? 0,
      conflicts: conflicts,
      resident: resident,
      active: active,
      total: rows.length,
    );
  }

  // ------------------------------------------------------------ 写入（核心）

  /// 直接创建记忆（用户手动添加或候选接受后调用），生成版本并更新索引。
  Future<Memory> createMemory({
    required String type,
    required String summary,
    String? title,
    String? body,
    String confidence = 'medium',
    int importance = 50,
    bool pinned = false,
    bool isResident = false,
    String? evidence,
    String? sourceSessionId,
    String? sourceMessageIds,
    List<String> aliases = const <String>[],
    List<String> tags = const <String>[],
    List<String> sensitivity = const <String>[],
    String status = 'active',
    List<String> supersedes = const <String>[],
    List<String> conflictsWith = const <String>[],
    String reason = '创建记忆',
  }) async {
    final id = _newMemoryId();
    final now = _nowIso();
    late Memory created;
    await _db.transaction(() async {
      await _db.into(_db.memories).insert(MemoriesCompanion.insert(
            id: id,
            type: type,
            status: Value(status),
            title: Value(title),
            summary: summary,
            body: Value(body),
            confidence: Value(confidence),
            importance: Value(importance),
            pinned: Value(pinned ? 1 : 0),
            aliases: Value(aliases.isEmpty ? null : jsonEncode(aliases)),
            tags: Value(tags.isEmpty ? null : jsonEncode(tags)),
            evidence: Value(evidence),
            sourceSessionId: Value(sourceSessionId),
            sourceMessageIds: Value(sourceMessageIds),
            supersedes: Value(supersedes.isEmpty ? null : jsonEncode(supersedes)),
            conflictsWith: Value(conflictsWith.isEmpty ? null : jsonEncode(conflictsWith)),
            isResident: Value(isResident ? 1 : 0),
            sensitivity: Value(sensitivity.isEmpty ? null : jsonEncode(sensitivity)),
            createdAt: now,
            updatedAt: now,
          ));
      created = (await getMemory(id))!;
      await _writeVersion(
        memory: created,
        changeKind: 'create',
        before: null,
        after: _snapshot(created),
        reason: reason,
        versionNo: 1,
      );
      await _log('create', 'memories', id, after: summary, reason: reason);
    });
    await _index.upsertMemory(created);
    return created;
  }

  /// 处理提取草稿：机密拦截 → 比较 → 候选落库 → 策略门禁自动生效。
  Future<IngestResult> ingestDraft(
    MemoryDraft draft, {
    String? sessionId,
    String? messageIds,
    String? assistantText,
    String origin = 'rule',
  }) async {
    final secret = engine.scanSecrets(draft.rawText);
    final sensitive = engine.scanSensitivity(draft.rawText);
    final candidateId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(const Duration(days: 30)).millisecondsSinceEpoch;

    if (secret.rejected) {
      await _db.into(_db.memoryCandidates).insert(MemoryCandidatesCompanion.insert(
            id: candidateId,
            proposedTitle: Value(draft.title),
            proposedSummary: secret.maskedText,
            proposedType: draft.type.wire,
            confidence: Value(draft.confidence.wire),
            importance: Value(draft.importance),
            origin: Value(origin),
            groundingNote: Value(draft.evidence),
            scanFlags: Value(jsonEncode({
              'secret': secret.summary,
              'secretRejected': true,
              'sensitive': sensitive.categories,
              'sessionId': sessionId,
              'messageIds': messageIds,
            })),
            compareResult: const Value('create'),
            status: const Value('rejected'),
            expiresAt: Value(expiresAt),
          ));
      await _log('reject', 'memory_candidates', candidateId,
          reason: '机密信息拒绝保存', source: 'rule');
      return IngestResult(
        candidateId: candidateId,
        compareKind: CompareKind.create,
        autoApplied: false,
        secretRejected: true,
      );
    }

    final cleaned = secret.findings.isEmpty
        ? draft
        : draft.copyWith(summary: secret.maskedText, rawText: secret.maskedText);
    final briefs = await _activeBriefs(cleaned.type.wire);
    final decision = engine.compare(cleaned, briefs);
    final autoApply = MemoryEngine.canAutoActivate(cleaned, decision);

    await _db.into(_db.memoryCandidates).insert(MemoryCandidatesCompanion.insert(
          id: candidateId,
          proposedTitle: Value(cleaned.title),
          proposedSummary: cleaned.summary,
          proposedType: cleaned.type.wire,
          confidence: Value(cleaned.confidence.wire),
          importance: Value(cleaned.importance),
          origin: Value(origin),
          groundingNote: Value(cleaned.evidence),
          scanFlags: Value(jsonEncode({
            'secret': secret.summary,
            'secretRejected': false,
            'sensitive': sensitive.categories,
            'sessionId': sessionId,
            'messageIds': messageIds,
            'opinionChange': cleaned.opinionChange,
            'sharedExperience': cleaned.sharedExperience,
          })),
          compareResult: Value(decision.kind.wire),
          targetMemoryId: Value(decision.targetId),
          status: Value(autoApply ? 'applied' : 'pending'),
          expiresAt: Value(expiresAt),
        ));

    String? memoryId;
    if (autoApply) {
      memoryId = await _applyDecision(
        cleaned,
        decision,
        evidence: cleaned.evidence,
        sessionId: sessionId,
        messageIds: messageIds,
      );
    }
    return IngestResult(
      candidateId: candidateId,
      compareKind: decision.kind,
      autoApplied: autoApply,
      secretRejected: false,
      memoryId: memoryId,
    );
  }

  /// 收件箱接受（可编辑后接受）
  Future<String> acceptCandidate(
    String candidateId, {
    String? editedTitle,
    String? editedSummary,
  }) async {
    final candidate = await getCandidate(candidateId);
    if (candidate == null) throw StateError('候选不存在：$candidateId');
    if (candidate.status != 'pending') throw StateError('该候选已处理');
    final summary = (editedSummary ?? candidate.proposedSummary).trim();
    if (summary.isEmpty) throw StateError('记忆内容不能为空');
    final draft = MemoryDraft(
      type: MemoryType.fromWire(candidate.proposedType) ?? MemoryType.profile,
      title: (editedTitle ?? candidate.proposedTitle ?? summary).trim(),
      summary: summary,
      confidence: MemoryConfidence.fromWire(candidate.confidence),
      importance: candidate.importance ?? 50,
      evidence: candidate.groundingNote ?? '',
      rawText: summary,
    );
    final flags = _decodeMap(candidate.scanFlags);
    final kind = CompareKind.fromWire(candidate.compareResult);
    final decision = CompareDecision(
      kind: kind,
      overlap: 0,
      reason: '用户确认接受',
      targetId: candidate.targetMemoryId,
    );
    final memoryId = await _applyDecision(
      draft,
      decision,
      evidence: candidate.groundingNote,
      sessionId: flags['sessionId'] as String?,
      messageIds: flags['messageIds'] as String?,
      reason: '用户确认收件箱候选',
    );
    await (_db.update(_db.memoryCandidates)
          ..where((t) => t.id.equals(candidateId)))
        .write(const MemoryCandidatesCompanion(status: Value('confirmed')));
    return memoryId;
  }

  Future<void> rejectCandidate(String candidateId) async {
    await (_db.update(_db.memoryCandidates)
          ..where((t) => t.id.equals(candidateId)))
        .write(const MemoryCandidatesCompanion(status: Value('rejected')));
  }

  Future<int> acceptAllCandidates() async {
    final pending = await listCandidates();
    var count = 0;
    for (final candidate in pending) {
      try {
        await acceptCandidate(candidate.id);
        count++;
      } catch (_) {
        // 单条失败不影响其余候选
      }
    }
    return count;
  }

  Future<int> rejectAllCandidates() async {
    final pending = await listCandidates();
    for (final candidate in pending) {
      await rejectCandidate(candidate.id);
    }
    return pending.length;
  }

  /// 30 天未处理的候选自动过期（标记 rejected 并留痕）
  Future<int> expirePendingCandidates({DateTime? now}) async {
    final current = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch;
    final pending = await listCandidates();
    var count = 0;
    for (final candidate in pending) {
      final expiresAt = candidate.expiresAt;
      if (expiresAt != null && expiresAt < current) {
        await (_db.update(_db.memoryCandidates)
              ..where((t) => t.id.equals(candidate.id)))
            .write(const MemoryCandidatesCompanion(status: Value('rejected')));
        count++;
      }
    }
    return count;
  }

  // ------------------------------------------------------------ 生命周期

  Future<void> setPinned(String memoryId, bool pinned) async {
    await _mutateStatus(memoryId, pinned ? 'pinned' : 'unpinned', (before) {
      return MemoriesCompanion(pinned: Value(pinned ? 1 : 0));
    });
  }

  Future<void> setResident(String memoryId, bool resident) async {
    await _mutateStatus(memoryId, resident ? 'resident' : 'unresident', (before) {
      return MemoriesCompanion(isResident: Value(resident ? 1 : 0));
    });
  }

  Future<void> archiveMemory(String memoryId) async {
    await changeStatus(memoryId, MemoryStatus.archived, reason: '用户归档');
  }

  Future<void> activateMemory(String memoryId) async {
    await changeStatus(memoryId, MemoryStatus.active, reason: '用户恢复为生效');
  }

  /// 状态变更（写版本 + journal + 索引）
  Future<void> changeStatus(
    String memoryId,
    MemoryStatus status, {
    String? reason,
  }) async {
    final before = await getMemory(memoryId);
    if (before == null) throw StateError('记忆不存在：$memoryId');
    late Memory after;
    await _db.transaction(() async {
      await (_db.update(_db.memories)..where((t) => t.id.equals(memoryId)))
          .write(MemoriesCompanion(
        status: Value(status.wire),
        updatedAt: Value(_nowIso()),
        deletedAt: Value(status == MemoryStatus.archived ? before.deletedAt : null),
      ));
      after = (await getMemory(memoryId))!;
      await _writeVersion(
        memory: after,
        changeKind: 'status',
        before: _snapshot(before),
        after: _snapshot(after),
        reason: reason ?? '状态变更为${status.label}',
        versionNo: await _nextVersionNo(memoryId),
      );
      await _log('status', 'memories', memoryId,
          before: before.status, after: status.wire, reason: reason);
    });
    await _index.upsertMemory(after);
  }

  /// 更新摘要/标题（补充更新或用户编辑）
  Future<Memory> updateMemory(
    String memoryId, {
    String? title,
    String? summary,
    String? evidence,
    String? body,
    String changeKind = 'update',
    String reason = '更新记忆',
  }) async {
    final before = await getMemory(memoryId);
    if (before == null) throw StateError('记忆不存在：$memoryId');
    late Memory after;
    await _db.transaction(() async {
      await (_db.update(_db.memories)..where((t) => t.id.equals(memoryId)))
          .write(MemoriesCompanion(
        title: Value(title ?? before.title),
        summary: Value(summary ?? before.summary),
        evidence: Value(evidence ?? before.evidence),
        body: Value(body ?? before.body),
        updatedAt: Value(_nowIso()),
      ));
      after = (await getMemory(memoryId))!;
      await _writeVersion(
        memory: after,
        changeKind: changeKind,
        before: _snapshot(before),
        after: _snapshot(after),
        reason: reason,
        versionNo: await _nextVersionNo(memoryId),
      );
      await _log(changeKind, 'memories', memoryId,
          before: before.summary, after: after.summary, reason: reason);
    });
    await _index.upsertMemory(after);
    return after;
  }

  /// 合并：把新信息并入旧记忆（重叠摘要不重复追加）
  Future<Memory> mergeInto(
    String memoryId, {
    required String title,
    required String summary,
    String? evidence,
  }) async {
    final before = await getMemory(memoryId);
    if (before == null) throw StateError('记忆不存在：$memoryId');
    var merged = before.summary;
    if (!merged.contains(summary) && !summary.contains(merged)) {
      merged = '$merged；$summary';
    } else if (summary.contains(merged) && summary.length > merged.length) {
      merged = summary;
    }
    return updateMemory(
      memoryId,
      title: (before.title ?? '').trim().isEmpty ? title : before.title,
      summary: merged,
      evidence: evidence ?? before.evidence,
      changeKind: 'merge',
      reason: '合并去重',
    );
  }

  /// 恢复历史版本 = 基于快照生成新版本（不覆盖历史）
  Future<Memory> restoreVersion(String memoryId, String versionId) async {
    final version = await (_db.select(_db.memoryVersions)
          ..where((t) => t.id.equals(versionId)))
        .getSingleOrNull();
    if (version == null) throw StateError('版本不存在：$versionId');
    final snapshot = _decodeMap(version.afterSnapshot);
    if (snapshot.isEmpty) throw StateError('版本快照为空');
    return updateMemory(
      memoryId,
      title: snapshot['title'] as String?,
      summary: snapshot['summary'] as String?,
      body: snapshot['body'] as String?,
      evidence: snapshot['evidence'] as String?,
      changeKind: 'update',
      reason: '撤销到 v${version.versionNo}',
    );
  }

  /// 冲突裁决：keep=a/b/manual
  Future<String> resolveConflict(
    String memoryId, {
    required String keep,
    String? manualText,
  }) async {
    final a = await getMemory(memoryId);
    if (a == null) throw StateError('记忆不存在：$memoryId');
    final conflictIds = _decodeList(a.conflictsWith);
    if (conflictIds.isEmpty) throw StateError('该记忆不在冲突状态');
    final b = await getMemory(conflictIds.first);
    if (b == null) throw StateError('冲突对端记忆不存在');

    if (keep == 'a' || keep == 'b') {
      final winner = keep == 'a' ? a : b;
      final loser = keep == 'a' ? b : a;
      await _db.transaction(() async {
        await (_db.update(_db.memories)..where((t) => t.id.equals(winner.id)))
            .write(MemoriesCompanion(
          status: const Value('active'),
          conflictsWith: const Value(null),
          updatedAt: Value(_nowIso()),
        ));
        await (_db.update(_db.memories)..where((t) => t.id.equals(loser.id)))
            .write(MemoriesCompanion(
          status: const Value('superseded'),
          supersededBy: Value(winner.id),
          conflictsWith: const Value(null),
          updatedAt: Value(_nowIso()),
        ));
        final winnerAfter = (await getMemory(winner.id))!;
        final loserAfter = (await getMemory(loser.id))!;
        await _writeVersion(
          memory: winnerAfter,
          changeKind: 'status',
          before: _snapshot(winner),
          after: _snapshot(winnerAfter),
          reason: '冲突裁决保留 v${winner.id}',
          versionNo: await _nextVersionNo(winner.id),
        );
        await _writeVersion(
          memory: loserAfter,
          changeKind: 'supersede',
          before: _snapshot(loser),
          after: _snapshot(loserAfter),
          reason: '冲突裁决落选',
          versionNo: await _nextVersionNo(loser.id),
        );
        await _log('resolve_conflict', 'memories', winner.id,
            before: a.id, after: winner.id, reason: '保留 $keep');
      });
      await _index.upsertMemory((await getMemory(winner.id))!);
      await _index.upsertMemory((await getMemory(loser.id))!);
      return winner.id;
    }

    final text = (manualText ?? '').trim();
    if (text.isEmpty) throw StateError('请填写你的版本');
    final created = await createMemory(
      type: a.type,
      summary: text,
      title: a.title,
      confidence: 'high',
      importance: a.importance,
      evidence: '用户手动裁决冲突',
      supersedes: [a.id, b.id],
      reason: '冲突裁决：用户重写',
    );
    await changeStatus(a.id, MemoryStatus.superseded, reason: '被用户重写替代');
    await changeStatus(b.id, MemoryStatus.superseded, reason: '被用户重写替代');
    await (_db.update(_db.memories)..where((t) => t.id.equals(a.id)))
        .write(MemoriesCompanion(supersededBy: Value(created.id)));
    await (_db.update(_db.memories)..where((t) => t.id.equals(b.id)))
        .write(MemoriesCompanion(supersededBy: Value(created.id)));
    return created.id;
  }

  // ------------------------------------------------------------ 关联

  Future<void> addRelation({
    required String fromMemoryId,
    required String toMemoryId,
    String relationType = 'related',
    int strength = 50,
    String discoveredBy = 'user',
  }) async {
    if (fromMemoryId == toMemoryId) return;
    final existing = await (_db.select(_db.memoryRelations)
          ..where((t) =>
              t.fromMemoryId.equals(fromMemoryId) &
              t.toMemoryId.equals(toMemoryId) &
              t.relationType.equals(relationType)))
        .getSingleOrNull();
    if (existing != null) return;
    await _db.into(_db.memoryRelations).insert(MemoryRelationsCompanion.insert(
          id: _uuid.v4(),
          fromMemoryId: fromMemoryId,
          toMemoryId: toMemoryId,
          relationType: relationType,
          strength: Value(strength),
          discoveredBy: Value(discoveredBy),
          createdAt: _nowIso(),
        ));
  }

  // ------------------------------------------------------------ 注入

  /// 常驻块（standing）
  Future<MemoryBlock> standingBlock() async {
    final rows = await (_db.select(_db.memories)
          ..where((t) => t.status.equals('active') & t.deletedAt.isNull())
          ..orderBy([
            (t) => OrderingTerm.desc(t.pinned),
            (t) => OrderingTerm.desc(t.importance),
          ])
          ..limit(60))
        .get();
    return renderer.renderStanding(rows.map(_toRenderItem).toList());
  }

  /// 召回块（recall）：倒排召回 + 相关性地板 + 预算裁剪
  Future<MemoryBlock> recallBlock(String query) async {
    final tokens = similarityTokens(query).take(48).toList();
    if (tokens.isEmpty) return MemoryBlock.empty;
    final terms = await (_db.select(_db.memoryIndexTerms)
          ..where((t) => t.token.isIn(tokens)))
        .get();
    if (terms.isEmpty) return MemoryBlock.empty;
    final scores = <String, double>{};
    final matched = <String, Set<String>>{};
    for (final term in terms) {
      scores[term.docId] = (scores[term.docId] ?? 0) + term.fieldWeight;
      matched.putIfAbsent(term.docId, () => <String>{}).add(term.token);
    }
    final docs = await (_db.select(_db.memories)
          ..where((t) => t.id.isIn(scores.keys.toList()) & t.deletedAt.isNull()))
        .get();
    final candidates = <MemoryRecallItem>[];
    for (final doc in docs) {
      final base = scores[doc.id] ?? 0;
      final adjusted = base + doc.importance / 10 + (doc.pinned == 1 ? 20 : 0);
      candidates.add(MemoryRecallItem(
        item: _toRenderItem(doc),
        score: adjusted,
        matchedTokens: matched[doc.id]?.toList() ?? const <String>[],
      ));
    }
    return renderer.renderRecall(query: query, candidates: candidates);
  }

  /// 注入预览：返回两条通道结果（供 UI 展示“泡泡此刻记得什么”）
  Future<({MemoryBlock standing, MemoryBlock recall})> injectionPreview(
      String query) async {
    final standing = await standingBlock();
    final recall = await recallBlock(query);
    return (standing: standing, recall: recall);
  }

  // ------------------------------------------------------------ 索引维护

  /// 索引重建（数据中心入口）：全量重刷并校验计数
  Future<int> rebuildIndex() async {
    final count = await _index.rebuildAll();
    await _log('index_rebuild', 'memory_index_terms', '*',
        after: '$count', reason: '手动重建记忆索引', source: 'user');
    return count;
  }

  Future<bool> isIndexConsistent() => _index.isConsistent();

  // ------------------------------------------------------------ 内部

  Future<List<ExistingMemoryBrief>> _activeBriefs(String type) async {
    final rows = await (_db.select(_db.memories)
          ..where((t) =>
              t.type.equals(type) &
              t.deletedAt.isNull() &
              (t.status.equals('active') | t.status.equals('conflict')))
          ..limit(200))
        .get();
    return rows
        .map((m) => ExistingMemoryBrief(
              id: m.id,
              type: m.type,
              summary: m.summary,
              confidence: m.confidence,
              status: m.status,
            ))
        .toList();
  }

  Future<String> _applyDecision(
    MemoryDraft draft,
    CompareDecision decision, {
    String? evidence,
    String? sessionId,
    String? messageIds,
    String reason = '规则自动保存',
  }) async {
    switch (decision.kind) {
      case CompareKind.create:
        final created = await createMemory(
          type: draft.type.wire,
          summary: draft.summary,
          title: draft.title,
          confidence: draft.confidence.wire,
          importance: draft.importance,
          evidence: evidence ?? draft.evidence,
          sourceSessionId: sessionId,
          sourceMessageIds: messageIds,
          sensitivity: draft.sensitiveCategories,
          reason: reason,
        );
        return created.id;
      case CompareKind.update:
        final targetId = decision.targetId;
        if (targetId == null) {
          final created = await createMemory(
            type: draft.type.wire,
            summary: draft.summary,
            title: draft.title,
            confidence: draft.confidence.wire,
            importance: draft.importance,
            evidence: evidence ?? draft.evidence,
            sensitivity: draft.sensitiveCategories,
            reason: reason,
          );
          return created.id;
        }
        final updated = await updateMemory(
          targetId,
          title: draft.title,
          summary: draft.summary,
          evidence: evidence ?? draft.evidence,
          reason: reason,
        );
        return updated.id;
      case CompareKind.merge:
        final targetId = decision.targetId;
        if (targetId == null) {
          final created = await createMemory(
            type: draft.type.wire,
            summary: draft.summary,
            title: draft.title,
            confidence: draft.confidence.wire,
            importance: draft.importance,
            evidence: evidence ?? draft.evidence,
            reason: reason,
          );
          return created.id;
        }
        final merged = await mergeInto(
          targetId,
          title: draft.title,
          summary: draft.summary,
          evidence: evidence ?? draft.evidence,
        );
        return merged.id;
      case CompareKind.conflict:
        final targetId = decision.targetId;
        if (targetId == null) {
          final created = await createMemory(
            type: draft.type.wire,
            summary: draft.summary,
            title: draft.title,
            confidence: draft.confidence.wire,
            importance: draft.importance,
            evidence: evidence ?? draft.evidence,
            status: 'conflict',
            reason: reason,
          );
          return created.id;
        }
        final target = await getMemory(targetId);
        if (target == null) {
          return _applyDecision(draft, CompareDecision.create,
              evidence: evidence, reason: reason);
        }
        final created = await createMemory(
          type: draft.type.wire,
          summary: draft.summary,
          title: draft.title,
          confidence: draft.confidence.wire,
          importance: draft.importance,
          evidence: evidence ?? draft.evidence,
          status: 'conflict',
          conflictsWith: [target.id],
          reason: '与既有记忆冲突，待裁决',
        );
        await (_db.update(_db.memories)..where((t) => t.id.equals(target.id)))
            .write(MemoriesCompanion(
          status: const Value('conflict'),
          conflictsWith: Value(jsonEncode([created.id])),
          updatedAt: Value(_nowIso()),
        ));
        await _index.upsertMemory((await getMemory(target.id))!);
        return created.id;
    }
  }

  Future<void> _mutateStatus(
    String memoryId,
    String operation,
    MemoriesCompanion Function(Memory before) build,
  ) async {
    final before = await getMemory(memoryId);
    if (before == null) throw StateError('记忆不存在：$memoryId');
    late Memory after;
    await _db.transaction(() async {
      await (_db.update(_db.memories)..where((t) => t.id.equals(memoryId)))
          .write(build(before).copyWith(updatedAt: Value(_nowIso())));
      after = (await getMemory(memoryId))!;
      await _writeVersion(
        memory: after,
        changeKind: 'status',
        before: _snapshot(before),
        after: _snapshot(after),
        reason: operation,
        versionNo: await _nextVersionNo(memoryId),
      );
    });
    await _index.upsertMemory(after);
  }

  Future<int> _nextVersionNo(String memoryId) async {
    final last = await (_db.select(_db.memoryVersions)
          ..where((t) => t.memoryId.equals(memoryId))
          ..orderBy([(t) => OrderingTerm.desc(t.versionNo)])
          ..limit(1))
        .getSingleOrNull();
    return (last?.versionNo ?? 0) + 1;
  }

  Future<void> _writeVersion({
    required Memory memory,
    required String changeKind,
    required Map<String, dynamic>? before,
    required Map<String, dynamic>? after,
    required int versionNo,
    String? reason,
  }) async {
    await _db.into(_db.memoryVersions).insert(MemoryVersionsCompanion.insert(
          id: _uuid.v4(),
          memoryId: memory.id,
          versionNo: versionNo,
          beforeSnapshot: Value(before == null ? null : jsonEncode(before)),
          afterSnapshot: Value(after == null ? null : jsonEncode(after)),
          changeKind: changeKind,
          reason: Value(reason),
          createdAt: _nowIso(),
        ));
  }

  Future<void> _log(
    String op,
    String table,
    String entityId, {
    String? before,
    String? after,
    String? reason,
    String source = 'rule',
  }) async {
    await _db.into(_db.journalLogs).insert(JournalLogsCompanion.insert(
          op: op,
          entityTable: table,
          entityId: entityId,
          beforeDigest: Value(before == null ? null : _digest(before)),
          afterDigest: Value(after == null ? null : _digest(after)),
          reason: Value(reason),
          source: Value(source),
          at: _nowIso(),
        ));
  }

  static String _digest(String text) =>
      text.length <= 160 ? text : text.substring(0, 160);

  static Map<String, dynamic> _snapshot(Memory memory) => <String, dynamic>{
        'title': memory.title,
        'summary': memory.summary,
        'body': memory.body,
        'status': memory.status,
        'confidence': memory.confidence,
        'importance': memory.importance,
        'pinned': memory.pinned,
        'isResident': memory.isResident,
        'evidence': memory.evidence,
        'sensitivity': memory.sensitivity,
      };

  static Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static List<String> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const <String>[];
    }
  }

  static MemoryRenderItem _toRenderItem(Memory memory) => MemoryRenderItem(
        id: memory.id,
        type: memory.type,
        status: memory.status,
        title: memory.title ?? '',
        summary: memory.summary,
        confidence: memory.confidence,
        importance: memory.importance,
        pinned: memory.pinned == 1,
        isResident: memory.isResident == 1,
        updatedAt: memory.updatedAt,
      );
}
