// 全局搜索仓储（T14.1）：维护 content_index_terms 六域倒排，并提供带分区的检索。
// 索引是可重建派生数据（DATABASE_DESIGN §2.30）；搜索不依赖索引以外的任何写入。
import 'package:drift/drift.dart';

import '../../domain/search/search_models.dart';
import '../../domain/search/tokenizer.dart';
import '../database/app_database.dart';

class GlobalSearchRepository {
  GlobalSearchRepository(this._db);

  final AppDatabase _db;

  static const _allKinds = <String>[
    'chat',
    'memory',
    'post',
    'diary',
    'letter',
    'experience',
    'attachment',
  ];

  static const _maxQueryTokens = 64;

  /// 全量重建倒排索引；可指定只重建部分域。返回写入的 token 行数。
  Future<int> rebuildIndex({Set<SearchDomain>? domains}) async {
    final kinds = domains == null
        ? _allKinds
        : domains.map((d) => d.wire).toList(growable: false);
    if (kinds.isEmpty) return 0;

    var written = 0;
    await _db.transaction(() async {
      await (_db.delete(
        _db.contentIndexTerms,
      )..where((t) => t.docKind.isIn(kinds))).go();

      Future<void> write(
        String kind,
        String docId,
        Map<String, int> tokens,
      ) async {
        if (tokens.isEmpty) return;
        final entries = tokens.entries.toList(growable: false);
        const batchSize = 200;
        for (var i = 0; i < entries.length; i += batchSize) {
          final chunk = entries.sublist(
            i,
            (i + batchSize).clamp(0, entries.length),
          );
          final placeholders = List.filled(chunk.length, '(?,?,?,?)').join(',');
          final args = <Object?>[];
          for (final e in chunk) {
            args
              ..add(e.key)
              ..add(kind)
              ..add(docId)
              ..add(e.value);
          }
          await _db.customStatement(
            'INSERT OR IGNORE INTO ${_db.contentIndexTerms.actualTableName} '
            '(token, doc_kind, doc_id, field_weight) VALUES $placeholders',
            args,
          );
          written += chunk.length;
        }
      }

      void put(Map<String, int> out, String? text, int weight) {
        if (text == null || text.trim().isEmpty) return;
        for (final token in tokenize(text)) {
          if (token.isEmpty) continue;
          final existing = out[token];
          if (existing == null || existing < weight) out[token] = weight;
        }
      }

      if (kinds.contains('chat')) {
        final messages =
            await (_db.select(_db.messages)..where(
                  (t) =>
                      t.deletedAt.isNull() &
                      t.content.isNotValue('') &
                      t.role.isIn(const ['user', 'assistant']),
                ))
                .get();
        for (final m in messages) {
          final tokens = <String, int>{};
          put(tokens, m.content, 1);
          await write('chat', m.id, tokens);
        }
      }

      if (kinds.contains('memory')) {
        final rows = await (_db.select(
          _db.memories,
        )..where((t) => t.deletedAt.isNull())).get();
        for (final m in rows) {
          final tokens = <String, int>{};
          put(tokens, m.title, 8);
          put(tokens, m.summary, 3);
          put(tokens, m.body, 1);
          await write('memory', m.id, tokens);
        }
      }

      if (kinds.contains('post')) {
        final rows = await (_db.select(
          _db.posts,
        )..where((t) => t.deletedAt.isNull())).get();
        for (final p in rows) {
          final tokens = <String, int>{};
          put(tokens, p.topic, 6);
          put(tokens, p.mood, 3);
          put(tokens, p.content, 1);
          await write('post', p.id, tokens);
        }
      }

      if (kinds.contains('diary')) {
        final rows = await (_db.select(
          _db.diaries,
        )..where((t) => t.deletedAt.isNull())).get();
        for (final d in rows) {
          final tokens = <String, int>{};
          put(tokens, d.entryDate, 3);
          put(tokens, d.content, 1);
          await write('diary', d.id, tokens);
        }
      }

      if (kinds.contains('letter')) {
        final rows = await (_db.select(
          _db.letters,
        )..where((t) => t.deletedAt.isNull())).get();
        for (final l in rows) {
          final tokens = <String, int>{};
          put(tokens, l.title, 6);
          put(tokens, l.content, 1);
          await write('letter', l.id, tokens);
        }
      }

      if (kinds.contains('experience')) {
        final rows = await (_db.select(
          _db.sharedExperiences,
        )..where((t) => t.deletedAt.isNull())).get();
        for (final e in rows) {
          final tokens = <String, int>{};
          put(tokens, e.name, 8);
          put(tokens, e.eventContent, 1);
          put(tokens, e.userPerspective, 1);
          put(tokens, e.bubblePerspective, 1);
          await write('experience', e.id, tokens);
        }
      }

      if (kinds.contains('attachment')) {
        final rows = await (_db.select(
          _db.attachments,
        )..where((t) => t.deletedAt.isNull())).get();
        for (final a in rows) {
          final tokens = <String, int>{};
          put(tokens, a.aiCaption, 3);
          put(tokens, a.ocrText, 1);
          await write('attachment', a.id, tokens);
        }
      }
    });
    return written;
  }

  /// 索引为空时自动全量重建（首次搜索或索引丢失）。
  Future<bool> ensureIndex() async {
    final row = await _db
        .customSelect(
          'SELECT COUNT(*) AS c FROM ${_db.contentIndexTerms.actualTableName}',
        )
        .getSingle();
    final count = row.data['c'] as int? ?? 0;
    if (count > 0) return false;
    await rebuildIndex();
    return true;
  }

  /// 检索入口：返回按分区聚合的命中。
  Future<GlobalSearchResult> search(String query, {int perDomain = 8}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return GlobalSearchResult.empty(trimmed);
    final started = DateTime.now();

    final indexWasEmpty = await ensureIndex();

    var tokens = similarityTokens(trimmed).toList();
    if (tokens.isEmpty) {
      tokens = tokenize(trimmed).toSet().toList();
    }
    if (tokens.isEmpty) {
      return GlobalSearchResult(
        query: trimmed,
        sections: const [],
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
        indexWasEmpty: indexWasEmpty,
      );
    }
    if (tokens.length > _maxQueryTokens) {
      tokens = tokens.take(_maxQueryTokens).toList();
    }

    final rows = await (_db.select(
      _db.contentIndexTerms,
    )..where((t) => t.token.isIn(tokens))).get();

    final matched = <String, Set<String>>{};
    final weights = <String, int>{};
    final kinds = <String, String>{};
    final ids = <String, String>{};
    for (final r in rows) {
      final key = '${r.docKind}|${r.docId}';
      matched.putIfAbsent(key, () => <String>{}).add(r.token);
      weights[key] = (weights[key] ?? 0) + r.fieldWeight;
      kinds[key] = r.docKind;
      ids[key] = r.docId;
    }
    if (matched.isEmpty) {
      return GlobalSearchResult(
        query: trimmed,
        sections: const [],
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
        indexWasEmpty: indexWasEmpty,
      );
    }

    final candidates = weights.keys.toList()
      ..sort((a, b) {
        final sa = weights[a]! + 50 * (matched[a]!.length / tokens.length);
        final sb = weights[b]! + 50 * (matched[b]!.length / tokens.length);
        return sb.compareTo(sa);
      });

    // 按域收集候选 ID（多取一些以便精确子串加权后截断）。
    final byDomain = <SearchDomain, List<String>>{};
    for (final key in candidates) {
      final domain = SearchDomain.fromWire(kinds[key]);
      if (domain == null) continue;
      final bucket = byDomain.putIfAbsent(domain, () => <String>[]);
      if (bucket.length < perDomain * 3) bucket.add(ids[key]!);
    }

    final sections = <SearchSectionResult>[];
    for (final section in SearchSection.values) {
      final hits = <SearchHit>[];
      for (final domain in section.domains) {
        final domainIds = byDomain[domain];
        if (domainIds == null || domainIds.isEmpty) continue;
        hits.addAll(
          await _loadHits(domain, domainIds, trimmed, weights, matched, tokens),
        );
      }
      if (hits.isEmpty) continue;
      hits.sort((a, b) => b.score.compareTo(a.score));
      sections.add(
        SearchSectionResult(
          section: section,
          hits: hits.take(perDomain).toList(growable: false),
        ),
      );
    }

    return GlobalSearchResult(
      query: trimmed,
      sections: sections,
      elapsedMs: DateTime.now().difference(started).inMilliseconds,
      indexWasEmpty: indexWasEmpty,
    );
  }

  Future<List<SearchHit>> _loadHits(
    SearchDomain domain,
    List<String> ids,
    String query,
    Map<String, int> weights,
    Map<String, Set<String>> matched,
    List<String> tokens,
  ) async {
    final hits = <SearchHit>[];
    final lowerQuery = query.toLowerCase();

    double scoreOf(String id) {
      final key = '${domain.wire}|$id';
      final weight = weights[key] ?? 0;
      final coverage = (matched[key]?.length ?? 0) / tokens.length;
      return weight + 50 * coverage;
    }

    switch (domain) {
      case SearchDomain.chat:
        final rows = await (_db.select(
          _db.messages,
        )..where((t) => t.id.isIn(ids))).get();
        final conversationIds = rows.map((r) => r.conversationId).toSet();
        final conversations = await (_db.select(
          _db.conversations,
        )..where((t) => t.id.isIn(conversationIds))).get();
        final titles = {for (final c in conversations) c.id: c.title};
        for (final m in rows) {
          var score = scoreOf(m.id);
          if (m.content.toLowerCase().contains(lowerQuery)) score += 100;
          hits.add(
            SearchHit(
              domain: domain,
              docId: m.id,
              title: titles[m.conversationId] ?? '聊天',
              subtitle: m.role == 'user' ? '你说' : '泡泡说',
              snippet: buildSnippet(m.content, query),
              anchorPath: '/chat/${m.conversationId}?focus=${m.id}',
              score: score,
            ),
          );
        }
      case SearchDomain.memory:
        final rows = await (_db.select(
          _db.memories,
        )..where((t) => t.id.isIn(ids))).get();
        for (final m in rows) {
          var score = scoreOf(m.id);
          final text = '${m.title ?? ''}\n${m.summary}\n${m.body ?? ''}';
          if (text.toLowerCase().contains(lowerQuery)) score += 100;
          hits.add(
            SearchHit(
              domain: domain,
              docId: m.id,
              title: (m.title?.trim().isNotEmpty ?? false)
                  ? m.title!.trim()
                  : _firstLine(m.summary),
              subtitle: m.type,
              snippet: buildSnippet(
                (m.body?.trim().isNotEmpty ?? false) ? m.body! : m.summary,
                query,
              ),
              anchorPath: '/memory/detail/${m.id}',
              score: score,
            ),
          );
        }
      case SearchDomain.post:
        final rows = await (_db.select(
          _db.posts,
        )..where((t) => t.id.isIn(ids))).get();
        for (final p in rows) {
          var score = scoreOf(p.id);
          if (p.content.toLowerCase().contains(lowerQuery)) score += 100;
          hits.add(
            SearchHit(
              domain: domain,
              docId: p.id,
              title: (p.topic?.trim().isNotEmpty ?? false)
                  ? p.topic!.trim()
                  : '说说',
              subtitle: _formatMs(p.publishedAt),
              snippet: buildSnippet(p.content, query),
              anchorPath: '/post/${p.id}',
              score: score,
            ),
          );
        }
      case SearchDomain.diary:
        final rows = await (_db.select(
          _db.diaries,
        )..where((t) => t.id.isIn(ids))).get();
        for (final d in rows) {
          var score = scoreOf(d.id);
          if (d.content.toLowerCase().contains(lowerQuery)) score += 100;
          hits.add(
            SearchHit(
              domain: domain,
              docId: d.id,
              title: d.entryDate,
              subtitle: '日记',
              snippet: buildSnippet(d.content, query),
              anchorPath: '/diary/${d.id}',
              score: score,
            ),
          );
        }
      case SearchDomain.letter:
        final rows = await (_db.select(
          _db.letters,
        )..where((t) => t.id.isIn(ids))).get();
        for (final l in rows) {
          var score = scoreOf(l.id);
          if (l.content.toLowerCase().contains(lowerQuery)) score += 100;
          hits.add(
            SearchHit(
              domain: domain,
              docId: l.id,
              title: (l.title?.trim().isNotEmpty ?? false)
                  ? l.title!.trim()
                  : (l.direction == 'bubble_to_user' ? '泡泡的来信' : '我写的信'),
              subtitle: l.state == 'draft' ? '草稿' : '已寄出',
              snippet: buildSnippet(l.content, query),
              anchorPath: '/letters/${l.id}',
              score: score,
            ),
          );
        }
      case SearchDomain.experience:
        final rows = await (_db.select(
          _db.sharedExperiences,
        )..where((t) => t.id.isIn(ids))).get();
        for (final e in rows) {
          var score = scoreOf(e.id);
          if (e.eventContent.toLowerCase().contains(lowerQuery)) score += 100;
          hits.add(
            SearchHit(
              domain: domain,
              docId: e.id,
              title: e.name,
              subtitle: _formatMs(e.occurredAt),
              snippet: buildSnippet(e.eventContent, query),
              anchorPath: '/experience/${e.id}',
              score: score,
            ),
          );
        }
      case SearchDomain.attachment:
        final rows = await (_db.select(
          _db.attachments,
        )..where((t) => t.id.isIn(ids))).get();
        for (final a in rows) {
          var score = scoreOf(a.id);
          final text = '${a.aiCaption ?? ''}\n${a.ocrText ?? ''}';
          if (text.toLowerCase().contains(lowerQuery)) score += 100;
          hits.add(
            SearchHit(
              domain: domain,
              docId: a.id,
              title: (a.aiCaption?.trim().isNotEmpty ?? false)
                  ? a.aiCaption!.trim()
                  : '图片',
              subtitle: a.ocrText == null || a.ocrText!.isEmpty
                  ? '无文字识别结果'
                  : '图中文字',
              snippet: buildSnippet(
                (a.ocrText?.trim().isNotEmpty ?? false)
                    ? a.ocrText!
                    : (a.aiCaption ?? ''),
                query,
              ),
              anchorPath: '/gallery',
              score: score,
            ),
          );
        }
    }
    return hits;
  }

  String _firstLine(String text) {
    final first = text.split('\n').first.trim();
    if (first.isEmpty) return '记忆';
    return first.length <= 24 ? first : '${first.substring(0, 24)}…';
  }

  String _formatMs(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}
