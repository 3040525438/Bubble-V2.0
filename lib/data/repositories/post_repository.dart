// 说说仓储（T10.1）：发布、编辑（写编辑历史）、软删除、心情筛选与去重数据源。
// 依据 DATABASE_DESIGN §2.18、REQUIREMENTS FR-POST。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/post/post_models.dart';
import '../database/app_database.dart';

class PostRepository {
  PostRepository(this._db, {DateTime Function()? clock})
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
    return 'post_${compact}_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
  }

  static String _digest(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 160) return cleaned;
    return '${cleaned.substring(0, 160)}…';
  }

  Future<Post> createPost(PostDraft draft) async {
    final error = PostRules.validateDraft(draft);
    if (error != null) throw ArgumentError(error);
    final id = _newId();
    final nowMs = _now().millisecondsSinceEpoch;
    final nowIso = _nowIso();
    late Post created;
    await _db.transaction(() async {
      await _db
          .into(_db.posts)
          .insert(
            PostsCompanion.insert(
              id: id,
              content: draft.content.trim(),
              mood: Value(draft.mood?.wire),
              topic: Value(draft.topic?.trim()),
              imageIds: Value(
                draft.imageIds.isEmpty ? null : jsonEncode(draft.imageIds),
              ),
              origin: Value(draft.origin.wire),
              relatedMemoryIds: Value(
                draft.relatedMemoryIds.isEmpty
                    ? null
                    : jsonEncode(draft.relatedMemoryIds),
              ),
              relatedConversationId: Value(draft.relatedConversationId),
              publishedAt: nowMs,
            ),
          );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'create',
              entityTable: 'posts',
              entityId: id,
              afterDigest: Value(_digest(draft.content)),
              reason: Value(draft.origin.label),
              source: Value('user'),
              at: nowIso,
            ),
          );
      created = (await getPost(id))!;
    });
    return created;
  }

  Future<Post?> getPost(String id) =>
      (_db.select(_db.posts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<Post>> listPosts({PostMood? mood, int limit = 100}) {
    final query = _db.select(_db.posts)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.publishedAt)])
      ..limit(limit);
    if (mood != null) query.where((t) => t.mood.equals(mood.wire));
    return query.get();
  }

  /// 最近说说正文（去重数据源）
  Future<List<String>> recentContents({int limit = 20}) async {
    final rows = await listPosts(limit: limit);
    return rows.map((row) => row.content).toList();
  }

  Future<Post> updatePost(
    String id, {
    String? content,
    PostMood? mood,
    String? topic,
  }) async {
    final before = await getPost(id);
    if (before == null) throw StateError('说说不存在：$id');
    final nextContent = (content ?? before.content).trim();
    if (nextContent.isEmpty) throw ArgumentError('说说内容不能为空');
    if (nextContent.length > PostRules.maxLength) {
      throw ArgumentError('说说不超过 ${PostRules.maxLength} 字');
    }
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await (_db.update(_db.posts)..where((t) => t.id.equals(id))).write(
        PostsCompanion(
          content: Value(nextContent),
          mood: mood == null ? const Value.absent() : Value(mood.wire),
          topic: topic == null ? const Value.absent() : Value(topic.trim()),
          editedAt: Value(_now().millisecondsSinceEpoch),
        ),
      );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'update',
              entityTable: 'posts',
              entityId: id,
              beforeDigest: Value(_digest(before.content)),
              afterDigest: Value(_digest(nextContent)),
              reason: const Value('用户编辑'),
              source: const Value('user'),
              at: nowIso,
            ),
          );
    });
    return (await getPost(id))!;
  }

  Future<void> softDelete(String id) async {
    final before = await getPost(id);
    final nowIso = _nowIso();
    await _db.transaction(() async {
      await (_db.update(_db.posts)..where((t) => t.id.equals(id))).write(
        PostsCompanion(deletedAt: Value(nowIso)),
      );
      await _db
          .into(_db.journalLogs)
          .insert(
            JournalLogsCompanion.insert(
              op: 'delete',
              entityTable: 'posts',
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

  /// 编辑历史（来自追加式 journal_logs，不新增表）
  Future<List<JournalLog>> editHistory(String id, {int limit = 20}) {
    return (_db.select(_db.journalLogs)
          ..where((t) => t.entityTable.equals('posts') & t.entityId.equals(id))
          ..orderBy([(t) => OrderingTerm.desc(t.at)])
          ..limit(limit))
        .get();
  }

  Future<int> countPosts() async {
    final rows = await (_db.select(
      _db.posts,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.length;
  }
}
