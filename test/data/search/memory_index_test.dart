// 索引读写与重建协议单测（T1.4）
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/search/memory_index.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late MemoryIndexWriter writer;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    writer = MemoryIndexWriter(db);
  });

  tearDown(() async => db.close());

  Memory companion({String id = 'mem_1', String? deletedAt}) => Memory(
        id: id,
        type: 'preference',
        status: 'active',
        title: '喜欢清晨咖啡',
        summary: '用户喜欢在清晨喝一杯咖啡，尤其是拿铁。',
        body: '补充：不加糖。',
        confidence: 'high',
        importance: 60,
        pinned: 0,
        isResident: 0,
        recallCount: 0,
        schemaVersion: 1,
        createdAt: '2026-11-22T00:00:00Z',
        updatedAt: '2026-11-22T00:00:00Z',
        deletedAt: deletedAt,
      );

  test('rebuildAll：插入记忆后索引含 token 与文档', () async {
    await db.into(db.memories).insert(companion(), mode: InsertMode.replace);
    final count = await writer.rebuildAll();
    expect(count, 1);

    final docs = await db.select(db.memoryIndexDocs).get();
    expect(docs.length, 1);
    expect(docs.first.docId, 'mem_1');
    expect(docs.first.type, 'preference');
    expect(docs.first.checksum, isNotEmpty);

    // 标题 token 权重 8
    final titleToken = await (db.select(db.memoryIndexTerms)
          ..where((t) => t.token.equals('咖啡') & t.docId.equals('mem_1')))
        .getSingle();
    expect(titleToken.fieldWeight, 8);

    // 正文 token 权重 1（糖 只出现在正文）
    final bodyToken = await (db.select(db.memoryIndexTerms)
          ..where((t) => t.token.equals('糖') & t.docId.equals('mem_1')))
        .getSingle();
    expect(bodyToken.fieldWeight, 1);
  });

  test('软删记忆不入索引', () async {
    await db.into(db.memories).insert(
        companion(deletedAt: '2026-11-22T01:00:00Z'),
        mode: InsertMode.replace);
    await writer.rebuildAll();
    final docs = await db.select(db.memoryIndexDocs).get();
    expect(docs, isEmpty);
  });

  test('upsertMemory 更新 checksum', () async {
    await db.into(db.memories).insert(companion(), mode: InsertMode.replace);
    await writer.upsertMemory(companion());
    final before = (await db.select(db.memoryIndexDocs).getSingle()).checksum;

    final updated = Memory(
      id: 'mem_1',
      type: 'preference',
      status: 'active',
      title: '喜欢清晨咖啡',
      summary: '更新摘要：清晨改到上午九点。',
      body: '',
      confidence: 'high',
      importance: 60,
      pinned: 0,
      isResident: 0,
      recallCount: 0,
      schemaVersion: 1,
      createdAt: '2026-11-22T00:00:00Z',
      updatedAt: '2026-11-22T02:00:00Z',
    );
    await writer.upsertMemory(updated);
    final after = (await db.select(db.memoryIndexDocs).getSingle()).checksum;
    expect(after, isNot(before));
  });

  test('removeMemory 清理索引', () async {
    await db.into(db.memories).insert(companion(), mode: InsertMode.replace);
    await writer.rebuildAll();
    await writer.removeMemory('mem_1');
    final docs = await db.select(db.memoryIndexDocs).get();
    expect(docs, isEmpty);
    final terms = await db.select(db.memoryIndexTerms).get();
    expect(terms, isEmpty);
  });

  test('isConsistent 一致性检查', () async {
    await db.into(db.memories).insert(companion(), mode: InsertMode.replace);
    // 未建索引 → 不一致
    expect(await writer.isConsistent(), isFalse);
    await writer.rebuildAll();
    expect(await writer.isConsistent(), isTrue);
  });
}
