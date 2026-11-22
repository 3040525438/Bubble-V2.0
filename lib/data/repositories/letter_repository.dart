// 信件仓储（T11.2）：草稿/已寄出、双向筛选、7 天写信冷却、软删除。
// 依据 DATABASE_DESIGN §2.20、REQUIREMENTS FR-LET-01。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/letter/letter_models.dart';
import '../database/app_database.dart';

class LetterRepository {
  LetterRepository(this._db, {DateTime Function()? clock})
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
    return 'let_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  static String _digest(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 160) return cleaned;
    return '${cleaned.substring(0, 160)}…';
  }

  // ------------------------------------------------------------ 创建与读取

  /// 新建草稿
  Future<Letter> createDraft(LetterDraft draft) async {
    final error = LetterRules.validateDraft(draft);
    if (error != null) throw ArgumentError(error);
    final id = _newId();
    final nowIso = _nowIso();
    final title = (draft.title ?? '').trim();
    await _db.transaction(() async {
      await _db
          .into(_db.letters)
          .insert(
            LettersCompanion.insert(
              id: id,
              direction: draft.direction.wire,
              title: Value(
                title.isEmpty ? LetterRules.deriveTitle(draft.content) : title,
              ),
              content: draft.content.trim(),
              relatedMemoryIds: Value(
                draft.relatedMemoryIds.isEmpty
                    ? null
                    : jsonEncode(draft.relatedMemoryIds),
              ),
              relatedExperienceIds: Value(
                draft.relatedExperienceIds.isEmpty
                    ? null
                    : jsonEncode(draft.relatedExperienceIds),
              ),
            ),
          );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'create',
              entityTable: 'letters',
              entityId: id,
              afterDigest: Value(_digest(draft.content)),
              reason: Value('${draft.direction.label}草稿'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await getLetter(id))!;
  }

  /// 新建并直接寄出（泡泡主动来信走这里，冷却校验在 sendLetter 内）
  Future<Letter> createAndSend(LetterDraft draft) async {
    final created = await createDraft(draft);
    return sendLetter(created.id);
  }

  Future<Letter?> getLetter(String id) => (_db.select(
    _db.letters,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 列表：草稿在前，已寄出按时间倒序
  Future<List<Letter>> listLetters({
    LetterFilter filter = LetterFilter.all,
    int limit = 200,
  }) async {
    final rows =
        await (_db.select(_db.letters)
              ..where((t) => t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.desc(t.sentAt)])
              ..limit(limit))
            .get();
    final filtered = rows
        .where(
          (row) => filter.matches(
            LetterDirection.fromWire(row.direction),
            LetterState.fromWire(row.state),
          ),
        )
        .toList();
    filtered.sort((a, b) {
      final aDraft = LetterState.fromWire(a.state).isDraft;
      final bDraft = LetterState.fromWire(b.state).isDraft;
      if (aDraft != bDraft) return aDraft ? -1 : 1;
      final aAt = a.sentAt ?? 0;
      final bAt = b.sentAt ?? 0;
      if (aAt != bAt) return bAt - aAt;
      return b.id.compareTo(a.id);
    });
    return filtered;
  }

  Future<List<Letter>> listDrafts({int limit = 50}) =>
      listLetters(filter: LetterFilter.drafts, limit: limit);

  // ------------------------------------------------------------ 编辑与寄出

  /// 编辑草稿（已寄出的信不可改，只可删除）
  Future<Letter> updateDraft(
    String id, {
    String? content,
    String? title,
    List<String>? memoryIds,
    List<String>? experienceIds,
  }) async {
    final before = await getLetter(id);
    if (before == null) throw StateError('信件不存在：$id');
    if (!LetterState.fromWire(before.state).isDraft) {
      throw StateError('已寄出的信不能修改');
    }
    final nextContent = (content ?? before.content).trim();
    if (nextContent.isEmpty) throw ArgumentError('信的内容不能为空');
    if (nextContent.length > LetterRules.maxLength) {
      throw ArgumentError('信件不超过 ${LetterRules.maxLength} 字');
    }
    final nowIso = _nowIso();
    final nextTitle = (title ?? before.title ?? '').trim();
    await _db.transaction(() async {
      await (_db.update(_db.letters)..where((t) => t.id.equals(id))).write(
        LettersCompanion(
          content: Value(nextContent),
          title: Value(
            nextTitle.isEmpty
                ? LetterRules.deriveTitle(nextContent)
                : nextTitle,
          ),
          relatedMemoryIds: memoryIds == null
              ? const Value.absent()
              : Value(memoryIds.isEmpty ? null : jsonEncode(memoryIds)),
          relatedExperienceIds: experienceIds == null
              ? const Value.absent()
              : Value(experienceIds.isEmpty ? null : jsonEncode(experienceIds)),
        ),
      );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'update',
              entityTable: 'letters',
              entityId: id,
              beforeDigest: Value(_digest(before.content)),
              afterDigest: Value(_digest(nextContent)),
              reason: const Value('用户编辑信件草稿'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await getLetter(id))!;
  }

  /// 寄出草稿；泡泡来信受 7 天冷却限制
  Future<Letter> sendLetter(String id) async {
    final before = await getLetter(id);
    if (before == null) throw StateError('信件不存在：$id');
    if (!LetterState.fromWire(before.state).isDraft) {
      throw StateError('这封信已经寄出了');
    }
    final direction = LetterDirection.fromWire(before.direction);
    final nowMs = _now().millisecondsSinceEpoch;
    if (direction.isFromBubble) {
      final last = await lastBubbleSentAtMs(excludingId: id);
      if (!LetterRules.canBubbleSend(lastSentAtMs: last, nowMs: nowMs)) {
        final nextAt = LetterRules.nextBubbleSendAtMs(last!);
        throw StateError(
          '泡泡的信至少间隔 ${LetterRules.cooldownDays} 天，'
          '${LetterRules.cooldownLabel(nextAt)}之后才能再写',
        );
      }
    }
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await (_db.update(_db.letters)..where((t) => t.id.equals(id))).write(
        LettersCompanion(state: const Value('sent'), sentAt: Value(nowMs)),
      );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'send',
              entityTable: 'letters',
              entityId: id,
              afterDigest: Value(_digest(before.content)),
              reason: Value('${direction.routeLabel} · 已寄出'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await getLetter(id))!;
  }

  /// 最近一封已寄出的泡泡来信时间
  Future<int?> lastBubbleSentAtMs({String? excludingId}) async {
    final query = _db.select(_db.letters)
      ..where(
        (t) =>
            t.deletedAt.isNull() &
            t.direction.equals(LetterDirection.bubbleToUser.wire) &
            t.state.equals(LetterState.sent.wire) &
            t.sentAt.isNotNull(),
      )
      ..orderBy([(t) => OrderingTerm.desc(t.sentAt)])
      ..limit(5);
    final rows = await query.get();
    for (final row in rows) {
      if (excludingId != null && row.id == excludingId) continue;
      return row.sentAt;
    }
    return null;
  }

  /// 泡泡此刻是否可以写新信
  Future<bool> canBubbleSendNow() async {
    final last = await lastBubbleSentAtMs();
    return LetterRules.canBubbleSend(
      lastSentAtMs: last,
      nowMs: _now().millisecondsSinceEpoch,
    );
  }

  /// 最近信件正文（写信去重数据源）
  Future<List<String>> recentContents({int limit = 5}) async {
    final rows = await listLetters(limit: limit);
    return rows.map((row) => row.content).toList();
  }

  Future<void> softDelete(String id) async {
    final before = await getLetter(id);
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await (_db.update(_db.letters)..where((t) => t.id.equals(id))).write(
        LettersCompanion(deletedAt: Value(nowIso)),
      );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'delete',
              entityTable: 'letters',
              entityId: id,
              beforeDigest: Value(
                before == null ? '' : _digest(before.content),
              ),
              reason: const Value('移入回收站（30 天）'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
  }

  Future<int> countLetters() async {
    final rows = await (_db.select(
      _db.letters,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.length;
  }
}
