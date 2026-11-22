// 记忆索引读写与重建协议（T1.4）：派生索引的维护层。
// 依据 DATABASE_DESIGN §2.30：索引绝非事实来源，可全量重建，零数据丢失。
// 字段权重：标题8 / 别名·标签6 / 摘要3 / 正文1。
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../domain/search/tokenizer.dart';
import '../database/app_database.dart';

class MemoryIndexWriter {
  final AppDatabase _db;

  MemoryIndexWriter(this._db);

  /// 文档 checksum：失效判定依据（§2.30）。
  static String checksumOf(String title, String summary, String body,
      List<String> aliases, List<String> tags) {
    return sha256
        .convert(utf8.encode('$title\u0000$summary\u0000$body\u0000'
            '${aliases.join('\u0001')}\u0000${tags.join('\u0001')}'))
        .toString();
  }

  /// 从记忆字段计算 (token → 最大权重) 映射。
  Map<String, int> tokensOf(String title, String summary, String body,
      List<String> aliases, List<String> tags) {
    final weights = <String, int>{};
    void put(List<String> tokens, int weight) {
      for (final t in tokens) {
        final existing = weights[t];
        if (existing == null || weight > existing) weights[t] = weight;
      }
    }

    put(tokenize(title), 8);
    put(tokenize(aliases.join(' ')), 6);
    put(tokenize(tags.join(' ')), 6);
    put(tokenize(summary), 3);
    put(tokenize(body), 1);
    return weights;
  }

  /// 单条记忆的索引更新（upsert；memory 传 null 时仅清理该 doc）。
  Future<void> upsertMemory(Memory? memory) async {
    if (memory == null) return;
    await _db.transaction(() async {
      await _db.customStatement(
          'DELETE FROM memory_index_terms WHERE doc_id = ?', [memory.id]);
      await _db.customStatement(
          'DELETE FROM memory_index_docs WHERE doc_id = ?', [memory.id]);
      await _writeMemory(memory);
    });
  }

  /// 单条记忆的索引移除。
  Future<void> removeMemory(String memoryId) async {
    await _db.customStatement(
        'DELETE FROM memory_index_terms WHERE doc_id = ?', [memoryId]);
    await _db.customStatement(
        'DELETE FROM memory_index_docs WHERE doc_id = ?', [memoryId]);
  }

  /// 全量重建（§2.30 重建协议）：清空索引表 → 从 memories 全量重刷，单事务。
  /// 返回重建的文档数。
  Future<int> rebuildAll() async {
    return _db.transaction(() async {
      await _db.customStatement('DELETE FROM memory_index_terms');
      await _db.customStatement('DELETE FROM memory_index_docs');
      final memories = await _db.select(_db.memories).get();
      for (final m in memories) {
        await _writeMemory(m);
      }
      return memories.where((m) => m.deletedAt == null).length;
    });
  }

  /// 索引完整性检查：活跃记忆数 == 索引文档数。
  Future<bool> isConsistent() async {
    final liveMemories =
        await (_db.select(_db.memories)..where((t) => t.deletedAt.isNull()))
            .get();
    final docs = await _db.select(_db.memoryIndexDocs).get();
    return liveMemories.length == docs.length;
  }

  Future<void> _writeMemory(Memory m) async {
    // 软删记忆不入索引
    if (m.deletedAt != null) return;
    List<String> parseList(String? json) {
      if (json == null || json.isEmpty) return const [];
      try {
        return (jsonDecode(json) as List).cast<String>();
      } catch (_) {
        return const [];
      }
    }

    final aliases = parseList(m.aliases);
    final tags = parseList(m.tags);
    final tokens = tokensOf(m.title ?? '', m.summary, m.body ?? '', aliases, tags);
    await _db.batch((b) {
      b.insertAll(
        _db.memoryIndexTerms,
        tokens.entries
            .map((e) => MemoryIndexTermsCompanion.insert(
                  token: e.key,
                  docId: m.id,
                  fieldWeight: e.value,
                ))
            .toList(),
        mode: InsertMode.insertOrReplace,
      );
    });
    // updatedAt（ISO-8601 TEXT）转毫秒存入 docs 表（INTEGER 约定）
    final updatedMs =
        DateTime.tryParse(m.updatedAt)?.toUtc().millisecondsSinceEpoch ?? 0;
    await _db.into(_db.memoryIndexDocs).insert(
          MemoryIndexDocsCompanion.insert(
            docId: m.id,
            type: Value(m.type),
            status: Value(m.status),
            title: Value(m.title),
            preview: Value(
                m.summary.length > 120 ? m.summary.substring(0, 120) : m.summary),
            importance: Value(m.importance),
            pinned: Value(m.pinned),
            updatedAt: Value(updatedMs),
            checksum: Value(
                checksumOf(m.title ?? '', m.summary, m.body ?? '', aliases, tags)),
          ),
          mode: InsertMode.insertOrReplace,
        );
  }
}
