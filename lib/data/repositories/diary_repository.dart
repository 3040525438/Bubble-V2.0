// 日记仓储（T11.1）：日期归档、版本保留、软删除与恢复、月历标记、Markdown 导出。
// 依据 DATABASE_DESIGN §2.19、REQUIREMENTS FR-DIA-01。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/diary/diary_models.dart';
import '../database/app_database.dart';

class DiaryRepository {
  DiaryRepository(this._db, {DateTime Function()? clock})
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
    return 'dia_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  static String _digest(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 160) return cleaned;
    return '${cleaned.substring(0, 160)}…';
  }

  // ------------------------------------------------------------ 创建与读取

  Future<Diary> createDiary(DiaryDraft draft) async {
    final error = DiaryRules.validateDraft(draft);
    if (error != null) throw ArgumentError(error);
    final id = _newId();
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await _db
          .into(_db.diaries)
          .insert(
            DiariesCompanion.insert(
              id: id,
              entryDate: DiaryRules.dateKey(draft.entryDate),
              content: draft.content.trim(),
              origin: Value(draft.origin.wire),
              relatedMessageIds: Value(
                draft.relatedMessageIds.isEmpty
                    ? null
                    : jsonEncode(draft.relatedMessageIds),
              ),
              relatedMemoryIds: Value(
                draft.relatedMemoryIds.isEmpty
                    ? null
                    : jsonEncode(draft.relatedMemoryIds),
              ),
              createdAt: nowIso,
              updatedAt: nowIso,
            ),
          );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'create',
              entityTable: 'diaries',
              entityId: id,
              afterDigest: Value(_digest(draft.content)),
              reason: Value(draft.origin.label),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await getDiary(id))!;
  }

  Future<Diary?> getDiary(String id) => (_db.select(
    _db.diaries,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Diary>> listDiaries({
    int? year,
    int? month,
    String? keyword,
    int limit = 200,
  }) {
    final query = _db.select(_db.diaries)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm.desc(t.entryDate),
        (t) => OrderingTerm.desc(t.createdAt),
      ])
      ..limit(limit);
    if (year != null && month != null) {
      final prefix = '$year-${month.toString().padLeft(2, '0')}-';
      query.where((t) => t.entryDate.like('$prefix%'));
    }
    final trimmed = (keyword ?? '').trim();
    if (trimmed.isNotEmpty) {
      query.where((t) => t.content.contains(trimmed));
    }
    return query.get();
  }

  Future<List<Diary>> listByDate(DateTime date, {int limit = 20}) {
    final key = DiaryRules.dateKey(date);
    return (_db.select(_db.diaries)
          ..where((t) => t.deletedAt.isNull() & t.entryDate.equals(key))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  /// 月历语义点（同一天多篇由 DiaryRules.groupByMonth 合并计数）
  Future<List<DiaryDayMark>> dayMarks({
    required int year,
    required int month,
  }) async {
    final rows = await listDiaries(year: year, month: month, limit: 500);
    return rows
        .map(
          (row) => DiaryDayMark(
            dateKey: row.entryDate,
            origin: DiaryOrigin.fromWire(row.origin),
          ),
        )
        .toList();
  }

  // ------------------------------------------------------------ 编辑与版本

  /// 编辑日记：旧内容写入 versions（只追加），当前内容更新
  Future<Diary> updateDiary(
    String id, {
    String? content,
    DiaryOrigin? origin,
    List<String>? memoryIds,
  }) async {
    final before = await getDiary(id);
    if (before == null) throw StateError('日记不存在：$id');
    final nextContent = (content ?? before.content).trim();
    if (nextContent.isEmpty) throw ArgumentError('日记内容不能为空');
    if (nextContent.length > DiaryRules.maxLength) {
      throw ArgumentError('日记不超过 ${DiaryRules.maxLength} 字');
    }
    final nowMs = _now().millisecondsSinceEpoch;
    final nowIso = _nowIso();
    final versions = DiaryRules.appendVersion(
      DiaryRules.parseVersions(before.versions),
      DiaryVersion(
        savedAtMs: nowMs,
        content: before.content,
        origin: DiaryOrigin.fromWire(before.origin),
      ),
    );
    await _db.transaction(() async {
      await (_db.update(_db.diaries)..where((t) => t.id.equals(id))).write(
        DiariesCompanion(
          content: Value(nextContent),
          origin: origin == null ? const Value.absent() : Value(origin.wire),
          relatedMemoryIds: memoryIds == null
              ? const Value.absent()
              : Value(memoryIds.isEmpty ? null : jsonEncode(memoryIds)),
          versions: Value(DiaryRules.encodeVersions(versions)),
          updatedAt: Value(nowIso),
        ),
      );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'update',
              entityTable: 'diaries',
              entityId: id,
              beforeDigest: Value(_digest(before.content)),
              afterDigest: Value(_digest(nextContent)),
              reason: const Value('用户编辑日记（保留旧版本）'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await getDiary(id))!;
  }

  Future<void> softDelete(String id) async {
    final before = await getDiary(id);
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await (_db.update(_db.diaries)..where((t) => t.id.equals(id))).write(
        DiariesCompanion(deletedAt: Value(nowIso)),
      );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'delete',
              entityTable: 'diaries',
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

  /// 从回收站恢复（FR-DIA-01 删除恢复）
  Future<void> restore(String id) async {
    final nowIso = _nowIso();
    await (_db.update(_db.diaries)..where((t) => t.id.equals(id))).write(
      DiariesCompanion(deletedAt: const Value(null), updatedAt: Value(nowIso)),
    );
  }

  // ------------------------------------------------------------ 导出

  /// 导出 Markdown（默认全部；可限定某年某月）
  Future<String> exportMarkdown({int? year, int? month}) async {
    final rows = await listDiaries(year: year, month: month, limit: 2000);
    final title = (year != null && month != null)
        ? '泡泡日记 · $year年$month月'
        : '泡泡日记';
    return DiaryRules.exportMarkdown(
      rows
          .map(
            (row) => DiaryExportEntry(
              dateKey: row.entryDate,
              content: row.content,
              origin: DiaryOrigin.fromWire(row.origin),
            ),
          )
          .toList(),
      title: title,
      exportedAt: _now(),
    );
  }

  Future<int> countDiaries() async {
    final rows = await (_db.select(
      _db.diaries,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.length;
  }
}
