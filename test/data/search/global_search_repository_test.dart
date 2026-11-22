// 全局搜索仓储测试（T14.1）：索引重建、分区命中、深链与空索引自愈。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/search/global_search_repository.dart';
import 'package:bubble/domain/search/search_models.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late GlobalSearchRepository repo;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    repo = GlobalSearchRepository(db);
    final nowIso = DateTime.utc(2026, 11, 20).toIso8601String();
    await db
        .into(db.memories)
        .insert(
          MemoriesCompanion.insert(
            id: 'mem_1',
            type: 'preference',
            summary: '喜欢在周末去咖啡店看书',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
    await db
        .into(db.posts)
        .insert(
          PostsCompanion.insert(
            id: 'post_1',
            content: '今天路过咖啡店，想起你',
            publishedAt: 1000,
          ),
        );
    await db
        .into(db.diaries)
        .insert(
          DiariesCompanion.insert(
            id: 'diary_1',
            entryDate: '2026-11-20',
            content: '咖啡店的那本书读完了',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
    await db
        .into(db.letters)
        .insert(
          LettersCompanion.insert(
            id: 'letter_1',
            direction: 'bubble_to_user',
            title: const Value('写给你的一封信'),
            content: '咖啡店门口等你',
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  test('重建索引后按分区命中并给出深链', () async {
    final written = await repo.rebuildIndex();
    expect(written, greaterThan(0));

    final result = await repo.search('咖啡');
    expect(result.query, '咖啡');
    expect(result.total, greaterThanOrEqualTo(3));

    final hits = result.sections.expand((s) => s.hits).toList();

    final memoryHit = hits.firstWhere((h) => h.domain == SearchDomain.memory);
    expect(memoryHit.docId, 'mem_1');
    expect(memoryHit.anchorPath, '/memory/detail/mem_1');
    expect(memoryHit.snippet.contains('咖啡'), isTrue);

    final postHit = hits.firstWhere((h) => h.domain == SearchDomain.post);
    expect(postHit.anchorPath, '/post/post_1');

    final letterHit = hits.firstWhere((h) => h.domain == SearchDomain.letter);
    expect(letterHit.anchorPath, '/letters/letter_1');
    expect(letterHit.section, SearchSection.journal);
  });

  test('索引为空时搜索自动重建', () async {
    final result = await repo.search('咖啡店');
    expect(result.indexWasEmpty, isTrue);
    expect(result.total, greaterThan(0));
  });

  test('空查询直接返回空结果', () async {
    final result = await repo.search('   ');
    expect(result.total, 0);
    expect(result.sections, isEmpty);
  });

  test('无命中词返回空分区', () async {
    await repo.rebuildIndex();
    final result = await repo.search('完全不存在的词条');
    expect(result.total, 0);
  });

  test('重建可限定域', () async {
    final written = await repo.rebuildIndex(domains: {SearchDomain.post});
    expect(written, greaterThan(0));
    final rows = await db.select(db.contentIndexTerms).get();
    expect(rows.every((r) => r.docKind == 'post'), isTrue);
  });
}
