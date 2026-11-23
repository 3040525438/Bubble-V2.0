// AstrBot 导入服务测试（T14.5）：预演、幂等导入、对账与批次回滚。
// 使用合成临时目录 + 注入只读 SQL，不依赖真实 AstrBot 数据与 sqlite 驱动。
import 'dart:convert';
import 'dart:io';

import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/migration/astrbot_import_service.dart';
import 'package:bubble/data/migration/astrbot_source.dart';
import 'package:bubble/domain/migration/migration_models.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

/// 注入式只读 SQL：按查询特征返回预设行。
class FakeReadOnlySql implements ReadOnlySql {
  @override
  bool get supported => true;

  @override
  List<Map<String, Object?>> query(String dbPath, String sql) {
    if (sql.contains('chat_memory_records')) {
      return [
        {
          'id': 1,
          'conversation_id': 'c1',
          'role': 'user',
          'content': '[系统通知]欢迎使用',
          'raw_timestamp': 1000,
          'created_at': '2026-10-24 10:00:00',
          'deleted_at': null,
        },
        {
          'id': 2,
          'conversation_id': 'c1',
          'role': 'user',
          'content': '今天想你了',
          'raw_timestamp': 1001,
          'created_at': '2026-10-24 10:01:00',
          'deleted_at': null,
        },
        {
          'id': 3,
          'conversation_id': 'c1',
          'role': 'assistant',
          'content': '我也想你，今天过得怎么样',
          'raw_timestamp': 1002,
          'created_at': '2026-10-24 10:02:00',
          'deleted_at': null,
        },
        {
          'id': 4,
          'conversation_id': 'c1',
          'role': 'user',
          'content': '   ',
          'raw_timestamp': 1003,
          'created_at': '2026-10-24 10:03:00',
          'deleted_at': null,
        },
      ];
    }
    if (sql.contains('chat_memory_media_archive')) {
      return [
        {'c': 2},
      ];
    }
    if (dbPath.endsWith('memory.db')) {
      return [
        {'id': 1, 'kind': 'fact', 'day': '2026-10-24', 'text': '喜欢咖啡'},
        {'id': 2, 'kind': 'chat', 'day': '2026-10-25', 'text': '一起看过海'},
      ];
    }
    if (sql.contains('FROM personas')) {
      return [
        {'persona_id': 'whale', 'system_prompt': '你是鲸鱼娘，名字叫小肥。'},
      ];
    }
    return const [];
  }

  @override
  void close() {}
}

/// 在基础假源上补充：库内日记（与 md 同日期/不同日期）与 qzone 说说。
class DiaryAndPostsFakeSql extends FakeReadOnlySql {
  @override
  List<Map<String, Object?>> query(String dbPath, String sql) {
    if (dbPath.replaceAll('\\', '/').endsWith('diary/memory.db')) {
      return [
        {'id': 1, 'kind': 'diary', 'day': '2026-10-23', 'text': '库里的日记'},
        {
          'id': 2,
          'kind': 'diary',
          'day': '2026-10-24',
          'text': '同日期库版本（应被 md 覆盖）',
        },
      ];
    }
    if (sql.contains('FROM posts')) {
      return [
        {
          'tid': 't1',
          'text': '今天趴窗边看雨',
          'create_time': 1792765922,
          'images': '[]',
        },
        {
          'tid': 't2',
          'text': '白米饭真好吃',
          'create_time': 1792766462,
          'images': '["https://example.com/1.jpg","https://example.com/2.jpg"]',
        },
      ];
    }
    return super.query(dbPath, sql);
  }
}

void main() {
  late AppDatabase db;
  late Directory root;
  late AstrBotSource source;
  late AstrBotImportService service;

  Future<void> writeFile(String relative, String content) async {
    final file = File(
      '${root.path}${Platform.pathSeparator}'
      '${relative.split('/').join(Platform.pathSeparator)}',
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_migration_test_');

    // 空文件占位：ql 读取由 FakeReadOnlySql 提供
    await writeFile('data/plugin_data/chat_memory/chat_memory.db', '');
    await writeFile('diary/memory.db', '');
    await writeFile('data/data_v4.db', '');

    await writeFile('diary/2026-10-24.md', '# 日记\n今天很开心');
    await writeFile('diary/FACTS.md', '事实汇总，不应导入');
    await writeFile('letters/2026-10-25.md', '亲爱的你，今天也想你。');
    await writeFile('letters/最新一封.md', '亲爱的你，今天也想你。');
    await writeFile('books/notes/读书笔记.md', '这是一段读书笔记的内容。');
    await writeFile(
      'data/plugin_data/astrbot_plugin_private_companion/companions.json',
      jsonEncode({
        'users': {
          'u1': {
            'nickname': '小胖',
            'relationship_role': 'friend',
            'relationship_score': 12,
            'companion_memory': {
              'items': [
                {'text': '喜欢被摸头', 'kind': 'important'},
                {'text': '不要说教', 'kind': 'boundary'},
              ],
            },
          },
        },
      }),
    );

    source = AstrBotSource(rootPath: root.path, sql: FakeReadOnlySql());
    service = AstrBotImportService(
      db,
      source: source,
      clock: () => DateTime.utc(2026, 11, 20, 9, 30),
    );
  });

  tearDown(() async {
    await db.close();
    source.dispose();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  test('预演报告逐类统计并标注不可迁移项', () async {
    final dryRun = await service.dryRun();
    expect(dryRun.sourceAvailable, isTrue);
    expect(dryRun.importableOf(MigrationCategory.chat), 2);
    expect(dryRun.importableOf(MigrationCategory.memory), 2);
    expect(dryRun.importableOf(MigrationCategory.persona), 1);
    expect(dryRun.importableOf(MigrationCategory.relation), 3);
    expect(dryRun.importableOf(MigrationCategory.diary), 1);
    expect(dryRun.importableOf(MigrationCategory.letter), 1);
    expect(dryRun.importableOf(MigrationCategory.bookNote), 1);
    expect(dryRun.importableOf(MigrationCategory.attachment), 0);

    final letterRow = dryRun.entries.firstWhere(
      (e) => e.category == MigrationCategory.letter,
    );
    expect(letterRow.sourceCount, 2);
    expect(letterRow.skipped, 1);

    final attachmentRow = dryRun.entries.firstWhere(
      (e) => e.category == MigrationCategory.attachment,
    );
    expect(attachmentRow.sourceCount, 2);
    expect(attachmentRow.note, contains('未迁移'));
  });

  test('源目录不存在时如实报告不可读', () async {
    final missing = AstrBotImportService(
      db,
      source: AstrBotSource(rootPath: '${root.path}_missing'),
    );
    final dryRun = await missing.dryRun();
    expect(dryRun.sourceAvailable, isFalse);
    expect(dryRun.hasAnything, isFalse);
    missing.source.dispose();
  });

  test('正式导入写入各域并可三向对账', () async {
    final batch = await service.run(createPreMigrationBackup: false);
    expect(batch.failed, 0);
    expect(batch.imported[MigrationCategory.chat], 2);
    expect(batch.imported[MigrationCategory.diary], 1);
    expect(batch.imported[MigrationCategory.letter], 1);
    expect(batch.imported[MigrationCategory.bookNote], 1);
    expect(batch.imported[MigrationCategory.relation], 3);
    expect(batch.imported[MigrationCategory.persona], 1);
    expect(batch.imported[MigrationCategory.memory], 2);

    final messages = await db.select(db.messages).get();
    expect(messages, hasLength(2));
    expect(messages.any((m) => m.content.contains('今天想你了')), isTrue);

    final diaries = await db.select(db.diaries).get();
    expect(diaries.single.entryDate, '2026-10-24');

    final letters = await db.select(db.letters).get();
    expect(letters, hasLength(1));

    // 2 条记忆 + 3 条关系记忆 + 1 条读书笔记
    final memories = await db.select(db.memories).get();
    expect(memories, hasLength(6));
    expect(memories.any((m) => m.type == 'knowledge'), isTrue);

    expect(await db.select(db.personaVersions).get(), hasLength(1));

    final records = await db.select(db.migrationRecords).get();
    expect(records, isNotEmpty);
    expect(records.every((r) => r.id.startsWith('${batch.batchId}:')), isTrue);

    final report = await service.reconcile(batch.batchId);
    expect(report.ok, isTrue);
    expect(report.rows, isNotEmpty);
    expect(report.totalRecords, greaterThan(0));

    final verified = await db.select(db.migrationRecords).get();
    expect(verified.any((r) => r.status == 'verified'), isTrue);
  });

  test('重复导入幂等：不重复插入', () async {
    final first = await service.run(createPreMigrationBackup: false);
    expect(first.importedTotal, greaterThan(0));

    final second = await service.run(createPreMigrationBackup: false);
    expect(second.importedTotal, 0);
    expect(second.failed, 0);

    expect(await db.select(db.messages).get(), hasLength(2));
    expect(await db.select(db.diaries).get(), hasLength(1));
    expect(await db.select(db.letters).get(), hasLength(1));
    expect(await db.select(db.memories).get(), hasLength(6));
  });

  test('批次回滚软删内容并硬删人格版本', () async {
    final batch = await service.run(createPreMigrationBackup: false);
    final rollback = await service.rollback(batch.batchId);
    expect(rollback.ok, isTrue);
    expect(rollback.affectedRecords, greaterThan(0));
    expect(rollback.softDeleted, greaterThan(0));

    final messages = await db.select(db.messages).get();
    expect(messages.every((m) => m.deletedAt != null), isTrue);

    final memories = await db.select(db.memories).get();
    expect(memories.every((m) => m.deletedAt != null), isTrue);

    expect(await db.select(db.personaVersions).get(), isEmpty);

    final logs = await db.select(db.journalLogs).get();
    expect(logs.any((l) => l.op == 'rollback'), isTrue);
  });

  test('说说与库内日记导入，无核心人格时直接生效', () async {
    await writeFile('data/plugin_data/astrbot_plugin_qzone/posts_5.db', '');
    final customSource = AstrBotSource(
      rootPath: root.path,
      sql: DiaryAndPostsFakeSql(),
    );
    final custom = AstrBotImportService(
      db,
      source: customSource,
      clock: () => DateTime.utc(2026, 11, 20, 9, 30),
    );

    final dryRun = await custom.dryRun();
    expect(dryRun.importableOf(MigrationCategory.post), 2);

    final batch = await custom.run(createPreMigrationBackup: false);
    expect(batch.failed, 0);
    expect(batch.imported[MigrationCategory.post], 2);

    final posts = await db.select(db.posts).get();
    expect(posts, hasLength(2));
    expect(posts.any((p) => p.content.contains('白米饭')), isTrue);
    expect(posts.every((p) => p.publishedAt > 0), isTrue);
    expect(posts.every((p) => p.origin == 'autonomous'), isTrue);

    // 库内日记 10-23 + md 覆盖同日的 10-24 → 共 2 篇，且 md 内容优先
    final diaries = await db.select(db.diaries).get();
    expect(diaries.map((d) => d.entryDate).toSet(), {
      '2026-10-23',
      '2026-10-24',
    });
    expect(
      diaries.firstWhere((d) => d.entryDate == '2026-10-24').content,
      contains('今天很开心'),
    );

    // 无既有核心人格：迁移版本应直接激活并回填主档案
    final profile = (await db.select(db.personaProfiles).get()).single;
    expect(profile.activeVersionId, isNotNull);
    expect(profile.coreSystemPrompt, contains('鲸鱼娘'));
    final versions = await db.select(db.personaVersions).get();
    expect(versions.single.isActive, 1);

    customSource.dispose();
  });

  test('覆盖模式会用源数据更新已导入内容（含聊天消息）', () async {
    await writeFile('data/plugin_data/astrbot_plugin_qzone/posts_5.db', '');
    final customSource = AstrBotSource(
      rootPath: root.path,
      sql: DiaryAndPostsFakeSql(),
    );
    final custom = AstrBotImportService(
      db,
      source: customSource,
      clock: () => DateTime.utc(2026, 11, 20, 9, 30),
    );

    final first = await custom.run(createPreMigrationBackup: false);
    expect(first.imported[MigrationCategory.post], 2);

    // 模拟用户本地修改导入内容，覆盖模式应恢复为源内容
    await (db.update(db.posts)..where((t) => t.id.equals('import_post_t1')))
        .write(const PostsCompanion(content: Value('本地改过的内容')));
    await (db.update(db.diaries)
          ..where((t) => t.id.equals('import_diary_2026-10-23')))
        .write(const DiariesCompanion(content: Value('本地改过的日记')));

    final beforeMessages = {
      for (final m in await db.select(db.messages).get()) m.id: m.content,
    };
    expect(beforeMessages, isNotEmpty);

    // 覆盖模式下预演应显示聊天可导入（而不是全部归为 0）
    final overwriteDryRun = await custom.dryRun(overwrite: true);
    expect(
      overwriteDryRun.importableOf(MigrationCategory.chat),
      beforeMessages.length,
    );

    final second = await custom.run(
      createPreMigrationBackup: false,
      overwrite: true,
    );
    expect(second.imported[MigrationCategory.post], 2);
    expect(second.imported[MigrationCategory.diary], 2);
    expect(second.imported[MigrationCategory.chat], beforeMessages.length);

    final post = (await db.select(db.posts).get()).firstWhere(
      (p) => p.id == 'import_post_t1',
    );
    expect(post.content, '今天趴窗边看雨');
    final diary = (await db.select(db.diaries).get()).firstWhere(
      (d) => d.entryDate == '2026-10-23',
    );
    expect(diary.content, '库里的日记');

    // 覆盖更新聊天消息但不产生重复行
    final afterMessages = {
      for (final m in await db.select(db.messages).get()) m.id: m.content,
    };
    expect(afterMessages.keys.toSet(), beforeMessages.keys.toSet());

    customSource.dispose();
  });
}
