// AstrBot 导入服务（T14.5）：预演 → 正式导入（幂等）→ 三向对账 → 批次回滚。
// 约束：源只读、API Key 不迁移、导入数据带 import_ 前缀与 migration_records 批次记录。
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/backup/backup_models.dart';
import '../../domain/migration/migration_models.dart';
import '../backup/backup_service.dart';
import '../database/app_database.dart';
import 'astrbot_source.dart';

class AstrBotImportService {
  AstrBotImportService(
    this._db, {
    required this.source,
    BackupService? backupService,
    DateTime Function()? clock,
  }) : _backup = backupService,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final AstrBotSource source;
  final BackupService? _backup;
  final DateTime Function() _clock;

  static const sourceName = 'astrbot';

  /// 源中存在但无法迁移的固定说明（如实报告，不假装导入）。
  static const mediaArchiveNote = '源仅保存图片/语音归档元数据，媒体文件不在库内，未迁移（可在旧目录手动归档）';
  static const configNote = 'API Key 一律不迁移；模型地址与参数需在新 App 重新录入';
  static const experienceNote = '源账本为关系分数事件，无结构化经历字段，未导入';
  static const pluginArchiveNote = '插件行为资料原样保留在源目录（只读），不导入';

  DateTime _now() => _clock();
  String _nowIso() => _now().toUtc().toIso8601String();

  // ------------------------------------------------------------ 预演

  Future<MigrationDryRun> dryRun() async {
    if (!await source.available) {
      return MigrationDryRun.unavailable(source.rootPath);
    }
    final existing = await _existingSourceRefs();
    final entries = <MigrationDryRunEntry>[];

    // 聊天
    final messages = await _readableChatMessages();
    final conversations = messages.map((m) => m.conversationId).toSet();
    final chatImportable = messages
        .where((m) => !existing.contains('chat:<${m.sourceId}>'))
        .where((m) => !existing.contains('chat_conv:<${m.conversationId}>'))
        .length;
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.chat,
        sourceCount: messages.length,
        importable: chatImportable,
        skipped: messages.length - chatImportable,
        note: '${conversations.length} 个会话；已导入的消息自动跳过',
      ),
    );

    // 长期记忆
    final memories = await _readableMemories();
    final memoryImportable = memories
        .where((m) => !existing.contains('memory:<${m.id}>'))
        .length;
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.memory,
        sourceCount: memories.length,
        importable: memoryImportable,
        skipped: memories.length - memoryImportable,
        note: 'fact→偏好 / diary→共同经历 / chat→事件',
      ),
    );

    // 人格
    final personas = await source.personas();
    final hasCore = await _hasActiveCorePersona();
    final personaImportable = personas
        .where((p) => !existing.contains('persona:<${p.personaId}>'))
        .length;
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.persona,
        sourceCount: personas.length,
        importable: personaImportable,
        needsManual: hasCore ? personaImportable : 0,
        note: hasCore ? '已存在核心人格：导入为未激活版本，需人工选择' : '无核心人格：导入并直接生效',
      ),
    );

    // 关系
    final companions = await source.companions();
    final relationTotal = companions.fold<int>(
      0,
      (sum, c) => sum + 1 + c.items.length,
    );
    final relationImportable = companions.fold<int>(0, (sum, c) {
      var count = existing.contains('relation:<${c.userId}>') ? 0 : 1;
      for (var i = 0; i < c.items.length; i++) {
        if (!existing.contains('relation_item:<${c.userId}>:$i')) count++;
      }
      return sum + count;
    });
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.relation,
        sourceCount: relationTotal,
        importable: relationImportable,
        skipped: relationTotal - relationImportable,
        note: '关系摘要 1 条 + 伴侣记忆条目',
      ),
    );

    // 说说（qzone 插件）
    final posts = await source.posts();
    final postImportable = posts
        .where((p) => !existing.contains('post:<${p.tid}>'))
        .length;
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.post,
        sourceCount: posts.length,
        importable: postImportable,
        skipped: posts.length - postImportable,
        note: '来自 qzone 插件（仅 approved）；外链图片不下载，仅如实计数',
      ),
    );

    // 日记
    final diaries = await source.diaries();
    final diaryDates = await _existingDiaryDates();
    final diaryImportable = diaries
        .where((d) => !existing.contains('diary:<${d.name}>'))
        .where((d) => !diaryDates.contains(d.date))
        .length;
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.diary,
        sourceCount: diaries.length,
        importable: diaryImportable,
        skipped: diaries.length - diaryImportable,
        note: '同日期已有日记时进入人工处理（不覆盖）',
      ),
    );

    // 信件
    final letters = await source.letters();
    final deduped = _dedupeLetters(letters);
    final letterImportable = deduped.chosen
        .where((d) => !existing.contains('letter:<${d.sha256}>'))
        .length;
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.letter,
        sourceCount: letters.length,
        importable: letterImportable,
        skipped: letters.length - letterImportable,
        note: '按内容 sha256 去重（如「最新一封.md」与日期文件重复）',
      ),
    );

    // 读书笔记
    final books = await source.bookNotes();
    final bookImportable = books
        .where((d) => !existing.contains('book:<${d.sha256}>'))
        .length;
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.bookNote,
        sourceCount: books.length,
        importable: bookImportable,
        skipped: books.length - bookImportable,
        note: '导入为「知识」类记忆',
      ),
    );

    // 经历
    entries.add(
      const MigrationDryRunEntry(
        category: MigrationCategory.experience,
        sourceCount: 0,
        importable: 0,
        note: experienceNote,
      ),
    );

    // 附件
    final mediaCount = await source.mediaArchiveCount();
    entries.add(
      MigrationDryRunEntry(
        category: MigrationCategory.attachment,
        sourceCount: mediaCount,
        importable: 0,
        skipped: mediaCount,
        note: mediaArchiveNote,
      ),
    );

    // 配置
    entries.add(
      const MigrationDryRunEntry(
        category: MigrationCategory.config,
        sourceCount: 0,
        importable: 0,
        note: configNote,
      ),
    );

    // 插件资料
    entries.add(
      const MigrationDryRunEntry(
        category: MigrationCategory.archive,
        sourceCount: 0,
        importable: 0,
        note: pluginArchiveNote,
      ),
    );

    return MigrationDryRun(
      sourceRoot: source.rootPath,
      entries: entries,
      sourceAvailable: true,
      generatedAt: _nowIso(),
    );
  }

  // ------------------------------------------------------------ 正式导入

  Future<ImportBatchResult> run({
    bool createPreMigrationBackup = true,
    void Function(int done, int total, String phase)? onProgress,
  }) async {
    final startedAt = _nowIso();
    final batchId = 'batch_${_now().millisecondsSinceEpoch}';
    final recorder = _Recorder(batchId, startedAt);
    final imported = <MigrationCategory, int>{};
    final skipped = <MigrationCategory, int>{};
    final needsManual = <MigrationCategory, int>{};
    final errors = <String>[];
    var failed = 0;

    String? backupPath;
    if (createPreMigrationBackup && _backup != null) {
      final backup = await _backup.createBackup(kind: BackupKind.preMigration);
      backupPath = backup.path;
    }

    void bump(Map<MigrationCategory, int> map, MigrationCategory c) {
      map[c] = (map[c] ?? 0) + 1;
    }

    final existing = await _existingSourceRefs();
    final totalSteps = 9;
    var step = 0;
    void progress(String phase) {
      step++;
      onProgress?.call(step, totalSteps, phase);
    }

    // ① 聊天
    try {
      final messages = await _readableChatMessages();
      final result = await _importChat(messages, batchId, recorder, existing);
      imported[MigrationCategory.chat] = result.imported;
      skipped[MigrationCategory.chat] = result.skipped;
      failed += result.failed;
      errors.addAll(result.errors);
    } catch (e) {
      failed++;
      errors.add('聊天导入失败：$e');
    }
    progress('聊天消息');

    // ② 长期记忆
    try {
      final memories = await _readableMemories();
      final result = await _importMemories(memories, recorder, existing);
      imported[MigrationCategory.memory] = result.imported;
      skipped[MigrationCategory.memory] = result.skipped;
      failed += result.failed;
      errors.addAll(result.errors);
    } catch (e) {
      failed++;
      errors.add('记忆导入失败：$e');
    }
    progress('长期记忆');

    // ③ 人格
    try {
      final personas = await source.personas();
      final hasCore = await _hasActiveCorePersona();
      var count = 0;
      for (final persona in personas) {
        final ref = 'persona:<${persona.personaId}>';
        if (existing.contains(ref)) {
          if (!hasCore) {
            // 旧批次可能「已导入但未激活」：无核心人格时补一次激活（幂等）
            await _activateImportedPersona(persona);
          }
          bump(skipped, MigrationCategory.persona);
          recorder.add(
            category: MigrationCategory.persona,
            status: 'skipped',
            sourceRef: ref,
            notes: '已导入，幂等跳过',
          );
          continue;
        }
        await _importPersona(persona, hasCore: hasCore);
        count++;
        bump(imported, MigrationCategory.persona);
        if (hasCore) {
          bump(needsManual, MigrationCategory.persona);
          recorder.add(
            category: MigrationCategory.persona,
            status: 'migrated',
            sourceRef: ref,
            targetTable: 'persona_versions',
            targetId: _personaVersionId(persona.personaId),
            notes: '导入为未激活版本，需人工选择是否启用',
          );
        } else {
          recorder.add(
            category: MigrationCategory.persona,
            status: 'migrated',
            sourceRef: ref,
            targetTable: 'persona_versions',
            targetId: _personaVersionId(persona.personaId),
          );
        }
      }
      imported[MigrationCategory.persona] = count;
    } catch (e) {
      failed++;
      errors.add('人格导入失败：$e');
    }
    progress('人格提示词');

    // ④ 关系
    try {
      final companions = await source.companions();
      final result = await _importRelations(companions, recorder, existing);
      imported[MigrationCategory.relation] = result.imported;
      skipped[MigrationCategory.relation] = result.skipped;
      failed += result.failed;
      errors.addAll(result.errors);
    } catch (e) {
      failed++;
      errors.add('关系导入失败：$e');
    }
    progress('关系设定');

    // ⑤ 说说（qzone 插件 posts_*.db）
    try {
      final posts = await source.posts();
      final result = await _importPosts(posts, recorder, existing);
      imported[MigrationCategory.post] = result.imported;
      skipped[MigrationCategory.post] = result.skipped;
      failed += result.failed;
      errors.addAll(result.errors);
    } catch (e) {
      failed++;
      errors.add('说说导入失败：$e');
    }
    progress('说说');

    // ⑥ 日记
    try {
      final diaries = await source.diaries();
      final result = await _importDiaries(diaries, recorder, existing);
      imported[MigrationCategory.diary] = result.imported;
      skipped[MigrationCategory.diary] = result.skipped;
      failed += result.failed;
      errors.addAll(result.errors);
    } catch (e) {
      failed++;
      errors.add('日记导入失败：$e');
    }
    progress('日记');

    // ⑦ 信件
    try {
      final letters = await source.letters();
      final result = await _importLetters(letters, recorder, existing);
      imported[MigrationCategory.letter] = result.imported;
      skipped[MigrationCategory.letter] = result.skipped;
      failed += result.failed;
      errors.addAll(result.errors);
    } catch (e) {
      failed++;
      errors.add('信件导入失败：$e');
    }
    progress('信件');

    // ⑧ 读书笔记
    try {
      final books = await source.bookNotes();
      final result = await _importBooks(books, recorder, existing);
      imported[MigrationCategory.bookNote] = result.imported;
      skipped[MigrationCategory.bookNote] = result.skipped;
      failed += result.failed;
      errors.addAll(result.errors);
    } catch (e) {
      failed++;
      errors.add('读书笔记导入失败：$e');
    }
    progress('读书笔记');

    // ⑨ 如实记录未迁移的源（附件/经历/配置/插件资料）
    final mediaCount = await source.mediaArchiveCount();
    if (mediaCount > 0) {
      skipped[MigrationCategory.attachment] = mediaCount;
      recorder.add(
        category: MigrationCategory.attachment,
        status: 'skipped',
        sourceRef: 'media_archive:<$mediaCount>',
        notes: mediaArchiveNote,
      );
    }
    recorder.add(
      category: MigrationCategory.experience,
      status: 'skipped',
      sourceRef: 'experience_ledger',
      notes: experienceNote,
    );
    recorder.add(
      category: MigrationCategory.config,
      status: 'skipped',
      sourceRef: 'config',
      notes: configNote,
    );
    recorder.add(
      category: MigrationCategory.archive,
      status: 'skipped',
      sourceRef: 'plugin_data',
      notes: pluginArchiveNote,
    );
    progress('附件与配置');

    // ⑩ 落库迁移记录
    await recorder.flush(_db);
    progress('迁移记录');

    final finishedAt = _nowIso();
    await _db
        .into(_db.journalLogs)
        .insert(
          JournalLogsCompanion.insert(
            op: 'migration',
            entityTable: 'migration_records',
            entityId: batchId,
            afterDigest: Value(
              '导入 ${imported.values.fold(0, (s, v) => s + v)} 条 / '
              '跳过 ${skipped.values.fold(0, (s, v) => s + v)} 条',
            ),
            reason: const Value('AstrBot 迁移导入'),
            source: const Value('migration'),
            at: finishedAt,
          ),
        );

    return ImportBatchResult(
      batchId: batchId,
      imported: imported,
      skipped: skipped,
      needsManual: needsManual,
      failed: failed,
      startedAt: startedAt,
      finishedAt: finishedAt,
      errors: errors.take(20).toList(growable: false),
      preMigrationBackupPath: backupPath,
    );
  }

  // ------------------------------------------------------------ 对账

  /// 三向对账：migration_records 记录数 vs 目标表现存行数 vs 已核验数。
  Future<ReconcileReport> reconcile(String batchId) async {
    final rows =
        await (_db.select(_db.migrationRecords)
              ..where((t) => t.id.like('$batchId:%'))
              ..where((t) => t.status.isIn(const ['migrated', 'verified'])))
            .get();
    final grouped = <MigrationCategory, List<MigrationRecord>>{};
    for (final row in rows) {
      final category = MigrationCategory.fromWire(row.category);
      if (category == null) continue;
      grouped.putIfAbsent(category, () => []).add(row);
    }

    final resultRows = <ReconcileRow>[];
    var ok = true;
    for (final category in MigrationCategory.values) {
      final records = grouped[category];
      if (records == null || records.isEmpty) continue;
      var targetCount = 0;
      var verified = 0;
      for (final record in records) {
        if (record.status == 'verified') verified++;
        final table = record.targetTable;
        final id = record.targetId;
        if (table == null || id == null) continue;
        if (!_isKnownContentTable(table)) continue;
        final row = await _db
            .customSelect(
              'SELECT 1 AS ok FROM "$table" WHERE id = ? LIMIT 1',
              variables: [Variable.withString(id)],
            )
            .getSingleOrNull();
        if (row != null) targetCount++;
      }
      final matched = targetCount == records.length;
      if (!matched) ok = false;
      resultRows.add(
        ReconcileRow(
          category: category,
          recordCount: records.length,
          targetCount: targetCount,
          verifiedCount: verified,
        ),
      );
    }

    // 对账通过的记录标记 verified
    if (ok) {
      await (_db.update(_db.migrationRecords)
            ..where((t) => t.id.like('$batchId:%'))
            ..where((t) => t.status.equals('migrated')))
          .write(
            MigrationRecordsCompanion(
              status: const Value('verified'),
              notes: Value('对账通过 ${_nowIso()}'),
            ),
          );
    }

    return ReconcileReport(batchId: batchId, rows: resultRows, ok: ok);
  }

  // ------------------------------------------------------------ 回滚

  /// 按批次回滚：有 deleted_at 的表软删，无软删的表（人格版本）硬删。
  Future<RollbackResult> rollback(String batchId) async {
    final rows =
        await (_db.select(_db.migrationRecords)
              ..where((t) => t.id.like('$batchId:%'))
              ..where((t) => t.targetId.isNotNull()))
            .get();
    if (rows.isEmpty) {
      return RollbackResult(
        batchId: batchId,
        affectedRecords: 0,
        softDeleted: 0,
        hardDeleted: 0,
        error: '该批次没有可回滚的目标记录',
      );
    }
    var soft = 0;
    var hard = 0;
    final nowIso = _nowIso();
    await _db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      await _db.transaction(() async {
        for (final record in rows) {
          final table = record.targetTable;
          final id = record.targetId;
          if (table == null || id == null) continue;
          if (!_isKnownContentTable(table)) continue;
          final hasDeletedAt = _softDeletableTables.contains(table);
          if (hasDeletedAt) {
            await _db.customStatement(
              'UPDATE "$table" SET deleted_at = ? WHERE id = ?',
              [nowIso, id],
            );
            soft++;
          } else {
            await _db.customStatement('DELETE FROM "$table" WHERE id = ?', [
              id,
            ]);
            hard++;
          }
        }
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON');
    }
    await _db
        .into(_db.journalLogs)
        .insert(
          JournalLogsCompanion.insert(
            op: 'rollback',
            entityTable: 'migration_records',
            entityId: batchId,
            afterDigest: Value('软删 $soft 条 / 硬删 $hard 条'),
            reason: const Value('用户回滚迁移批次'),
            source: const Value('user'),
            at: nowIso,
          ),
        );
    return RollbackResult(
      batchId: batchId,
      affectedRecords: rows.length,
      softDeleted: soft,
      hardDeleted: hard,
    );
  }

  /// 历史批次（从 migration_records 聚合）。
  Future<List<String>> batches({int limit = 20}) async {
    final rows = await _db
        .customSelect(
          "SELECT DISTINCT substr(id, 1, instr(id, ':') - 1) AS b "
          'FROM migration_records WHERE source = ? AND instr(id, \':\') > 0 '
          'ORDER BY b DESC LIMIT ?',
          variables: [Variable.withString(sourceName), Variable.withInt(limit)],
        )
        .get();
    final result = <String>[];
    for (final row in rows) {
      final batch = row.data['b']?.toString() ?? '';
      if (batch.isNotEmpty && !result.contains(batch)) result.add(batch);
    }
    return result;
  }

  // ------------------------------------------------------------ 内部：聊天

  Future<List<AstrChatMessage>> _readableChatMessages() async {
    final all = await source.chatMessages();
    return [
      for (final m in all)
        if (!m.deleted &&
            m.content.trim().isNotEmpty &&
            !m.content.trimLeft().startsWith('[系统通知]') &&
            (m.role == 'user' || m.role == 'assistant'))
          m,
    ];
  }

  Future<({int imported, int skipped, int failed, List<String> errors})>
  _importChat(
    List<AstrChatMessage> messages,
    String batchId,
    _Recorder recorder,
    Set<String> existing,
  ) async {
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];

    final grouped = <String, List<AstrChatMessage>>{};
    for (final m in messages) {
      grouped.putIfAbsent(m.conversationId, () => []).add(m);
    }

    for (final entry in grouped.entries) {
      final conversationId = entry.key.isEmpty ? 'unknown' : entry.key;
      final list = entry.value;
      final targetConversationId = 'import_conv_$conversationId';
      final conversationRef = 'chat_conv:<$conversationId>';
      if (!existing.contains(conversationRef)) {
        final first = list.first;
        final lastMs = list.last.createdAtMs;
        await _db
            .into(_db.conversations)
            .insert(
              ConversationsCompanion.insert(
                id: targetConversationId,
                title: _titleFrom(first.content),
                lastMessageAt: Value(
                  lastMs > 0 ? lastMs : _now().millisecondsSinceEpoch,
                ),
                messageCount: Value(0),
                createdAt: _iso(first.createdAtMs),
                updatedAt: _iso(lastMs > 0 ? lastMs : first.createdAtMs),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        recorder.add(
          category: MigrationCategory.chat,
          status: 'migrated',
          sourceRef: conversationRef,
          targetTable: 'conversations',
          targetId: targetConversationId,
          notes: '会话（${list.length} 条消息）',
        );
      }

      final companions = <MessagesCompanion>[];
      var seq = 0;
      for (final m in list) {
        seq++;
        final ref = 'chat:<${m.sourceId}>';
        if (existing.contains(ref)) {
          skipped++;
          recorder.add(
            category: MigrationCategory.chat,
            status: 'skipped',
            sourceRef: ref,
            notes: '已导入，幂等跳过',
          );
          continue;
        }
        final messageId = 'import_msg_${m.sourceId}';
        companions.add(
          MessagesCompanion.insert(
            id: messageId,
            conversationId: targetConversationId,
            role: m.role,
            seq: seq,
            content: m.content,
            status: 'sent',
            createdAt: _iso(m.createdAtMs),
            updatedAt: _iso(m.createdAtMs),
          ),
        );
        recorder.add(
          category: MigrationCategory.chat,
          status: 'migrated',
          sourceRef: ref,
          targetTable: 'messages',
          targetId: messageId,
        );
        imported++;
      }
      if (companions.isNotEmpty) {
        try {
          await _db.batch((batch) {
            batch.insertAll(
              _db.messages,
              companions,
              mode: InsertMode.insertOrIgnore,
            );
          });
        } catch (e) {
          failed += companions.length;
          errors.add('会话 $conversationId 消息写入失败：$e');
        }
      }
      // 回填会话统计
      await _db.customStatement(
        'UPDATE conversations SET message_count = '
        '(SELECT COUNT(*) FROM messages WHERE conversation_id = ?) '
        'WHERE id = ?',
        [targetConversationId, targetConversationId],
      );
    }

    return (
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  static String _titleFrom(String content) {
    final cleaned = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return 'AstrBot 导入的会话';
    final title = cleaned.length <= 24
        ? cleaned
        : '${cleaned.substring(0, 24)}…';
    return '$title（导入）';
  }

  // ------------------------------------------------------------ 内部：记忆

  Future<List<AstrMemoryRow>> _readableMemories() async {
    final all = await source.memories();
    return [
      for (final m in all)
        if (m.text.trim().isNotEmpty) m,
    ];
  }

  Future<({int imported, int skipped, int failed, List<String> errors})>
  _importMemories(
    List<AstrMemoryRow> memories,
    _Recorder recorder,
    Set<String> existing,
  ) async {
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];

    final existingSummaries = <String>{};
    final rows = await (_db.select(
      _db.memories,
    )..where((t) => t.deletedAt.isNull())).get();
    for (final row in rows) {
      existingSummaries.add(row.summary.trim());
    }

    final companions = <MemoriesCompanion>[];
    for (final memory in memories) {
      final ref = 'memory:<${memory.id}>';
      if (existing.contains(ref)) {
        skipped++;
        recorder.add(
          category: MigrationCategory.memory,
          status: 'skipped',
          sourceRef: ref,
          notes: '已导入，幂等跳过',
        );
        continue;
      }
      final summary = _truncate(memory.text, 200);
      if (existingSummaries.contains(summary.trim())) {
        skipped++;
        recorder.add(
          category: MigrationCategory.memory,
          status: 'skipped',
          sourceRef: ref,
          notes: '与现有记忆摘要重复，未导入',
        );
        continue;
      }
      final id = 'import_mem_${memory.id}';
      final type = switch (memory.kind) {
        'fact' => 'preference',
        'diary' => 'experience_joint',
        _ => 'event',
      };
      final createdAt = _dayIso(memory.day);
      companions.add(
        MemoriesCompanion.insert(
          id: id,
          type: type,
          status: const Value('active'),
          title: Value('${memory.day} · ${memory.kind}'),
          summary: summary,
          body: Value(memory.text),
          confidence: const Value('medium'),
          importance: const Value(50),
          evidence: Value('astrbot:mem:${memory.id}'),
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      );
      existingSummaries.add(summary.trim());
      imported++;
      recorder.add(
        category: MigrationCategory.memory,
        status: 'migrated',
        sourceRef: ref,
        targetTable: 'memories',
        targetId: id,
        notes: 'type=$type',
      );
    }

    if (companions.isNotEmpty) {
      try {
        await _db.batch((batch) {
          batch.insertAll(
            _db.memories,
            companions,
            mode: InsertMode.insertOrIgnore,
          );
        });
      } catch (e) {
        failed += companions.length;
        errors.add('记忆写入失败：$e');
      }
    }
    return (
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  // ------------------------------------------------------------ 内部：人格

  static String _personaVersionId(String personaId) =>
      'import_persona_${_sanitize(personaId)}';

  Future<void> _importPersona(
    AstrPersonaRow persona, {
    required bool hasCore,
  }) async {
    final row = await _db
        .customSelect(
          'SELECT COALESCE(MAX(version_no), 0) AS n FROM persona_versions '
          "WHERE layer = 'core'",
        )
        .getSingle();
    final nextNo = (row.data['n'] as int? ?? 0) + 1;
    final content = jsonEncode({
      'name': persona.personaId,
      'systemPrompt': persona.systemPrompt,
      'source': 'astrbot',
    });
    await _db
        .into(_db.personaVersions)
        .insert(
          PersonaVersionsCompanion.insert(
            id: _personaVersionId(persona.personaId),
            versionNo: nextNo,
            layer: 'core',
            content: content,
            changeReason: Value(
              hasCore ? 'AstrBot 迁移（未激活，需人工选择）' : 'AstrBot 迁移（核心人格来源）',
            ),
            confirmedBy: const Value('migration'),
            isActive: const Value(0),
            createdAt: _nowIso(),
          ),
          mode: InsertMode.insertOrIgnore,
        );
    if (!hasCore) {
      // 无既有核心人格：迁移版本直接生效并回填主档案，
      // 否则人格中心仍显示空/默认内容，用户会以为「没导入」。
      await _activateImportedPersona(persona);
    }
  }

  /// 把已导入的人格版本设为生效版本并回填主档案（仅用于「无核心人格」场景）。
  /// 幂等：重复导入时会自愈旧批次「已导入但未激活」的情况。
  Future<void> _activateImportedPersona(AstrPersonaRow persona) async {
    final versionId = _personaVersionId(persona.personaId);
    final version =
        await (_db.select(_db.personaVersions)
              ..where((t) => t.id.equals(versionId))
              ..limit(1))
            .getSingleOrNull();
    if (version == null) return;
    if (version.isActive != 1) {
      await (_db.update(_db.personaVersions)
            ..where((t) => t.id.equals(versionId)))
          .write(const PersonaVersionsCompanion(isActive: Value(1)));
    }
    final profile = await (_db.select(
      _db.personaProfiles,
    )..limit(1)).getSingleOrNull();
    if (profile == null) {
      await _db
          .into(_db.personaProfiles)
          .insert(
            PersonaProfilesCompanion.insert(
              id: 'persona_main',
              name: Value(persona.personaId),
              intro: const Value('由 AstrBot 迁移导入'),
              coreSystemPrompt: Value(persona.systemPrompt),
              activeVersionId: Value(versionId),
              updatedAt: _nowIso(),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    } else if (profile.activeVersionId != versionId) {
      await (_db.update(
        _db.personaProfiles,
      )..where((t) => t.id.equals(profile.id))).write(
        PersonaProfilesCompanion(
          activeVersionId: Value(versionId),
          coreSystemPrompt: Value(persona.systemPrompt),
          updatedAt: Value(_nowIso()),
        ),
      );
    }
  }

  Future<bool> _hasActiveCorePersona() async {
    final profile = await (_db.select(
      _db.personaProfiles,
    )..limit(1)).getSingleOrNull();
    if (profile == null) return false;
    if (profile.activeVersionId == null || profile.activeVersionId!.isEmpty) {
      return false;
    }
    final version =
        await (_db.select(_db.personaVersions)
              ..where((t) => t.id.equals(profile.activeVersionId!))
              ..limit(1))
            .getSingleOrNull();
    return version != null;
  }

  // ------------------------------------------------------------ 内部：关系

  Future<({int imported, int skipped, int failed, List<String> errors})>
  _importRelations(
    List<AstrCompanion> companions,
    _Recorder recorder,
    Set<String> existing,
  ) async {
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    final rows = <MemoriesCompanion>[];

    for (final companion in companions) {
      final ref = 'relation:<${companion.userId}>';
      if (existing.contains(ref)) {
        skipped++;
        recorder.add(
          category: MigrationCategory.relation,
          status: 'skipped',
          sourceRef: ref,
          notes: '已导入，幂等跳过',
        );
      } else {
        final id = 'import_rel_${_sanitize(companion.userId)}';
        final name = companion.nickname == null || companion.nickname!.isEmpty
            ? companion.userId
            : companion.nickname!;
        final summary = _truncate(
          '与 $name 的关系：${companion.role}；关系分 ${companion.score}',
          200,
        );
        final createdAt = _nowIso();
        rows.add(
          MemoriesCompanion.insert(
            id: id,
            type: 'profile',
            status: const Value('active'),
            title: Value('与 $name 的关系'),
            summary: summary,
            body: Value(null),
            confidence: const Value('medium'),
            importance: const Value(60),
            evidence: Value('astrbot:companion:${companion.userId}'),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
        imported++;
        recorder.add(
          category: MigrationCategory.relation,
          status: 'migrated',
          sourceRef: ref,
          targetTable: 'memories',
          targetId: id,
          notes: '关系摘要',
        );
      }

      for (var i = 0; i < companion.items.length; i++) {
        final item = companion.items[i];
        final ref = 'relation_item:<${companion.userId}>:$i';
        if (existing.contains(ref)) {
          skipped++;
          recorder.add(
            category: MigrationCategory.relation,
            status: 'skipped',
            sourceRef: ref,
            notes: '已导入，幂等跳过',
          );
          continue;
        }
        final id = 'import_cm_${_sanitize(companion.userId)}_$i';
        final type = switch (item.kind) {
          'boundary' => 'preference',
          'important' => 'event',
          _ => 'profile',
        };
        final createdAt = _nowIso();
        rows.add(
          MemoriesCompanion.insert(
            id: id,
            type: type,
            status: const Value('active'),
            title: Value('伴侣记忆 · ${item.kind}'),
            summary: _truncate(item.text, 200),
            body: Value(item.text),
            confidence: const Value('medium'),
            importance: Value(item.kind == 'important' ? 70 : 50),
            evidence: Value('astrbot:companion:${companion.userId}:item:$i'),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );
        imported++;
        recorder.add(
          category: MigrationCategory.relation,
          status: 'migrated',
          sourceRef: ref,
          targetTable: 'memories',
          targetId: id,
          notes: '伴侣记忆条目（${item.kind}）',
        );
      }
    }

    if (rows.isNotEmpty) {
      try {
        await _db.batch((batch) {
          batch.insertAll(_db.memories, rows, mode: InsertMode.insertOrIgnore);
        });
      } catch (e) {
        failed += rows.length;
        errors.add('关系记忆写入失败：$e');
      }
    }
    return (
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  // ------------------------------------------------------------ 内部：日记/信件/笔记

  Future<Set<String>> _existingDiaryDates() async {
    final rows = await _db
        .customSelect('SELECT entry_date FROM diaries WHERE deleted_at IS NULL')
        .get();
    return {
      for (final row in rows)
        if (row.data['entry_date'] != null) row.data['entry_date']! as String,
    };
  }

  /// 说说导入：按 tid 幂等；外链图片不下载，写入记录里如实标注。
  Future<({int imported, int skipped, int failed, List<String> errors})>
  _importPosts(
    List<AstrPostRow> rows,
    _Recorder recorder,
    Set<String> existing,
  ) async {
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    for (final post in rows) {
      final ref = 'post:<${post.tid}>';
      if (existing.contains(ref)) {
        skipped++;
        recorder.add(
          category: MigrationCategory.post,
          status: 'skipped',
          sourceRef: ref,
          notes: '已导入，幂等跳过',
        );
        continue;
      }
      final id = 'import_post_${_sanitize(post.tid)}';
      try {
        await _db
            .into(_db.posts)
            .insert(
              PostsCompanion.insert(
                id: id,
                content: post.content,
                origin: const Value('autonomous'),
                publishedAt: post.createdAtMs > 0
                    ? post.createdAtMs
                    : DateTime.now().millisecondsSinceEpoch,
              ),
              mode: InsertMode.insertOrIgnore,
            );
        imported++;
        recorder.add(
          category: MigrationCategory.post,
          status: 'migrated',
          sourceRef: ref,
          targetTable: 'posts',
          targetId: id,
          notes: post.imageCount > 0 ? '外链图片 ${post.imageCount} 张未下载' : null,
        );
      } catch (e) {
        failed++;
        errors.add('说说 ${post.tid} 写入失败：$e');
      }
    }
    return (
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  Future<({int imported, int skipped, int failed, List<String> errors})>
  _importDiaries(
    List<AstrTextDoc> docs,
    _Recorder recorder,
    Set<String> existing,
  ) async {
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    final dates = await _existingDiaryDates();

    for (final doc in docs) {
      final ref = 'diary:<${doc.name}>';
      if (existing.contains(ref)) {
        skipped++;
        recorder.add(
          category: MigrationCategory.diary,
          status: 'skipped',
          sourceRef: ref,
          notes: '已导入，幂等跳过',
        );
        continue;
      }
      final date = doc.date;
      if (date == null) continue;
      if (dates.contains(date)) {
        skipped++;
        recorder.add(
          category: MigrationCategory.diary,
          status: 'skipped',
          sourceRef: ref,
          notes: '同日期已有日记，进入人工处理（不覆盖）',
        );
        continue;
      }
      final id = 'import_diary_$date';
      final createdAt = _dayIso(date);
      try {
        await _db
            .into(_db.diaries)
            .insert(
              DiariesCompanion.insert(
                id: id,
                entryDate: date,
                content: doc.content.trim(),
                origin: const Value('ai_organized'),
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
              mode: InsertMode.insertOrIgnore,
            );
        dates.add(date);
        imported++;
        recorder.add(
          category: MigrationCategory.diary,
          status: 'migrated',
          sourceRef: ref,
          targetTable: 'diaries',
          targetId: id,
        );
      } catch (e) {
        failed++;
        errors.add('日记 $date 写入失败：$e');
      }
    }
    return (
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  ({List<AstrTextDoc> chosen, int skipped}) _dedupeLetters(
    List<AstrTextDoc> docs,
  ) {
    final grouped = <String, List<AstrTextDoc>>{};
    for (final doc in docs) {
      grouped.putIfAbsent(doc.sha256, () => []).add(doc);
    }
    final chosen = <AstrTextDoc>[];
    var skipped = 0;
    for (final group in grouped.values) {
      group.sort((a, b) {
        final aDate = a.date == null ? 1 : 0;
        final bDate = b.date == null ? 1 : 0;
        if (aDate != bDate) return aDate.compareTo(bDate);
        return a.name.compareTo(b.name);
      });
      chosen.add(group.first);
      skipped += group.length - 1;
    }
    chosen.sort((a, b) => (a.date ?? a.name).compareTo(b.date ?? b.name));
    return (chosen: chosen, skipped: skipped);
  }

  Future<({int imported, int skipped, int failed, List<String> errors})>
  _importLetters(
    List<AstrTextDoc> docs,
    _Recorder recorder,
    Set<String> existing,
  ) async {
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    final deduped = _dedupeLetters(docs);
    skipped += deduped.skipped;
    if (deduped.skipped > 0) {
      recorder.add(
        category: MigrationCategory.letter,
        status: 'skipped',
        sourceRef: 'letter_dedup:<${deduped.skipped}>',
        notes: '内容重复的信件已去重 ${deduped.skipped} 封',
      );
    }

    for (final doc in deduped.chosen) {
      final ref = 'letter:<${doc.sha256}>';
      if (existing.contains(ref)) {
        skipped++;
        recorder.add(
          category: MigrationCategory.letter,
          status: 'skipped',
          sourceRef: ref,
          notes: '已导入，幂等跳过',
        );
        continue;
      }
      final id = 'import_letter_${doc.sha256.substring(0, 16)}';
      final title = doc.name.replaceAll(RegExp(r'\.md$'), '');
      final sentMs = doc.date == null
          ? _now().millisecondsSinceEpoch
          : (DateTime.tryParse(doc.date!)?.millisecondsSinceEpoch ??
                _now().millisecondsSinceEpoch);
      try {
        await _db
            .into(_db.letters)
            .insert(
              LettersCompanion.insert(
                id: id,
                direction: 'bubble_to_user',
                state: const Value('sent'),
                title: Value(title),
                content: doc.content.trim(),
                sentAt: Value(sentMs),
              ),
              mode: InsertMode.insertOrIgnore,
            );
        imported++;
        recorder.add(
          category: MigrationCategory.letter,
          status: 'migrated',
          sourceRef: ref,
          targetTable: 'letters',
          targetId: id,
        );
      } catch (e) {
        failed++;
        errors.add('信件 ${doc.name} 写入失败：$e');
      }
    }
    return (
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  Future<({int imported, int skipped, int failed, List<String> errors})>
  _importBooks(
    List<AstrTextDoc> docs,
    _Recorder recorder,
    Set<String> existing,
  ) async {
    var imported = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    for (final doc in docs) {
      final ref = 'book:<${doc.sha256}>';
      if (existing.contains(ref)) {
        skipped++;
        recorder.add(
          category: MigrationCategory.bookNote,
          status: 'skipped',
          sourceRef: ref,
          notes: '已导入，幂等跳过',
        );
        continue;
      }
      final id = 'import_book_${doc.sha256.substring(0, 16)}';
      final title = doc.name.replaceAll(RegExp(r'\.md$'), '');
      final createdAt = _nowIso();
      try {
        await _db
            .into(_db.memories)
            .insert(
              MemoriesCompanion.insert(
                id: id,
                type: 'knowledge',
                status: const Value('active'),
                title: Value(title),
                summary: _truncate(doc.content, 200),
                body: Value(doc.content),
                confidence: const Value('medium'),
                importance: const Value(40),
                evidence: Value('astrbot:book:${doc.sha256}'),
                createdAt: createdAt,
                updatedAt: createdAt,
              ),
              mode: InsertMode.insertOrIgnore,
            );
        imported++;
        recorder.add(
          category: MigrationCategory.bookNote,
          status: 'migrated',
          sourceRef: ref,
          targetTable: 'memories',
          targetId: id,
        );
      } catch (e) {
        failed++;
        errors.add('读书笔记 ${doc.name} 写入失败：$e');
      }
    }
    return (
      imported: imported,
      skipped: skipped,
      failed: failed,
      errors: errors,
    );
  }

  // ------------------------------------------------------------ 工具

  Future<Set<String>> _existingSourceRefs() async {
    final rows = await _db
        .customSelect(
          'SELECT source_ref FROM migration_records '
          'WHERE source = ? AND source_ref IS NOT NULL',
          variables: [Variable.withString(sourceName)],
        )
        .get();
    return {
      for (final row in rows)
        if (row.data['source_ref'] != null) row.data['source_ref']! as String,
    };
  }

  static const _softDeletableTables = {
    'conversations',
    'messages',
    'attachments',
    'memories',
    'posts',
    'diaries',
    'letters',
    'shared_experiences',
    'expression_samples',
  };

  static bool _isKnownContentTable(String table) {
    return _softDeletableTables.contains(table) || table == 'persona_versions';
  }

  static String _iso(int ms) => DateTime.fromMillisecondsSinceEpoch(
    ms <= 0 ? DateTime.now().millisecondsSinceEpoch : ms,
  ).toUtc().toIso8601String();

  static String _dayIso(String day) {
    final parsed = DateTime.tryParse(day);
    return (parsed ?? DateTime.now()).toUtc().toIso8601String();
  }

  static String _truncate(String text, int max) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= max) return cleaned;
    return '${cleaned.substring(0, max)}…';
  }

  static String _sanitize(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
}

/// 迁移记录收集器：批量写入 migration_records。
class _Recorder {
  _Recorder(this.batchId, this.nowIso);

  final String batchId;
  final String nowIso;
  final List<MigrationRecordsCompanion> _pending = [];
  int _seq = 0;

  void add({
    required MigrationCategory category,
    required String status,
    String? sourceRef,
    String? targetTable,
    String? targetId,
    String? notes,
  }) {
    _pending.add(
      MigrationRecordsCompanion.insert(
        id: '$batchId:${_seq++}',
        source: const Value('astrbot'),
        sourceRef: Value(sourceRef),
        targetTable: Value(targetTable),
        targetId: Value(targetId),
        category: Value(category.wire),
        status: Value(status),
        notes: Value(notes),
        migratedAt: nowIso,
      ),
    );
  }

  Future<void> flush(AppDatabase db) async {
    if (_pending.isEmpty) return;
    const chunkSize = 500;
    for (var i = 0; i < _pending.length; i += chunkSize) {
      final chunk = _pending.sublist(
        i,
        (i + chunkSize).clamp(0, _pending.length),
      );
      await db.batch((batch) {
        batch.insertAll(
          db.migrationRecords,
          chunk,
          mode: InsertMode.insertOrIgnore,
        );
      });
    }
    _pending.clear();
  }
}
