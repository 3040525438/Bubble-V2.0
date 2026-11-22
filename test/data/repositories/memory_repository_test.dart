// 记忆仓储与管线单测（T5.2/T5.5）：生命周期、版本、收件箱、冲突、检索与索引重建。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/memory_ingest_pipeline.dart';
import 'package:bubble/data/repositories/memory_repository.dart';
import 'package:bubble/domain/memory/memory_engine.dart';
import 'package:bubble/domain/memory/memory_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late MemoryRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = MemoryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<Memory> ingest(
    String text, {
    String? sessionId,
  }) async {
    final draft = const MemoryEngine().extract(text);
    expect(draft, isNotNull, reason: text);
    final result = await repo.ingestDraft(draft!, sessionId: sessionId);
    expect(result.autoApplied, isTrue, reason: text);
    return (await repo.getMemory(result.memoryId!))!;
  }

  group('创建与版本', () {
    test('创建记忆写入 v1、索引可检索、计数正确', () async {
      final memory = await repo.createMemory(
        type: 'preference',
        title: '咖啡偏好',
        summary: '我喜欢每天早上喝一杯黑咖啡',
        evidence: '我喜欢每天早上喝一杯黑咖啡',
        confidence: 'high',
      );
      final versions = await repo.versionsOf(memory.id);
      expect(versions.length, 1);
      expect(versions.first.versionNo, 1);
      expect(versions.first.changeKind, 'create');

      final hits = await repo.searchMemories('黑咖啡');
      expect(hits.map((m) => m.id), contains(memory.id));

      final counts = await repo.counts();
      expect(counts.total, 1);
      expect(counts.active, 1);
    });

    test('更新生成新版本，撤销旧版本可回放快照', () async {
      final created = await repo.createMemory(
        type: 'profile',
        title: '称呼',
        summary: '用户希望被称呼为阿岚',
      );
      await repo.updateMemory(created.id, summary: '用户希望被称呼为岚岚');
      final versions = await repo.versionsOf(created.id);
      expect(versions.length, 2);
      expect(versions.first.versionNo, 2);

      final restored = await repo.restoreVersion(created.id, versions.last.id);
      expect(restored.summary, '用户希望被称呼为阿岚');
      expect((await repo.versionsOf(created.id)).length, 3);
    });
  });

  group('收件箱与策略门禁', () {
    test('高置信普通记忆自动生效', () async {
      final memory = await ingest('记住：我每天早上喝一杯黑咖啡');
      expect(memory.status, 'active');
      expect(memory.confidence, 'high');

      final applied = await repo.listCandidates(status: 'applied');
      expect(applied.length, 1);
      expect(await repo.listCandidates(), isEmpty);
    });

    test('敏感信息只进待确认，确认后才生效', () async {
      final draft = const MemoryEngine().extract('记住：我最近住院做手术');
      final result = await repo.ingestDraft(draft!);
      expect(result.autoApplied, isFalse);
      expect((await repo.getMemory(result.memoryId ?? '')) ?? null, isNull);

      final pending = await repo.listCandidates();
      expect(pending.length, 1);
      expect(pending.first.scanFlags, contains('健康'));

      final memoryId = await repo.acceptCandidate(pending.first.id);
      final memory = await repo.getMemory(memoryId);
      expect(memory!.status, 'active');
      expect(await repo.listCandidates(), isEmpty);
    });

    test('机密信息整条拒绝，不产生记忆', () async {
      final draft = const MemoryEngine().extract('记住：我的密码是 abc12345');
      final result = await repo.ingestDraft(draft!);
      expect(result.secretRejected, isTrue);
      expect(result.memoryId, isNull);
      expect(await repo.listMemories(), isEmpty);

      final rejected = await repo.listCandidates(status: 'rejected');
      expect(rejected.length, 1);
      expect(rejected.first.proposedSummary.contains('abc12345'), isFalse);
    });

    test('重复内容合并去重，不重复建条', () async {
      await repo.createMemory(
        type: 'preference',
        title: '西湖散步',
        summary: '我喜欢在周末去西湖边散步',
        confidence: 'high',
      );
      final draft = const MemoryEngine().extract('我喜欢在周末去西湖边散步');
      final result = await repo.ingestDraft(draft!);
      expect(result.compareKind, CompareKind.merge);
      expect(result.autoApplied, isFalse);

      final pending = await repo.listCandidates();
      await repo.acceptCandidate(pending.first.id);

      final memories = await repo.listMemories();
      expect(memories.length, 1);
      expect(memories.first.summary.split('西湖边散步').length - 1, 1);
    });

    test('编辑后接受使用用户文本', () async {
      final draft = const MemoryEngine().extract('记住：我最近住院做手术');
      await repo.ingestDraft(draft!);
      final pending = await repo.listCandidates();
      final memoryId = await repo.acceptCandidate(
        pending.first.id,
        editedTitle: '身体状况',
        editedSummary: '用户近期做过手术，需要休息',
      );
      final memory = await repo.getMemory(memoryId);
      expect(memory!.title, '身体状况');
      expect(memory.summary, '用户近期做过手术，需要休息');
    });

    test('全部接受/全部拒绝与 30 天过期', () async {
      final d1 = const MemoryEngine().extract('记住：我最近住院做手术');
      final d2 = const MemoryEngine().extract('记住：我最近在做体检');
      await repo.ingestDraft(d1!);
      await repo.ingestDraft(d2!);
      expect((await repo.listCandidates()).length, 2);

      expect(await repo.acceptAllCandidates(), 2);
      expect(await repo.listCandidates(), isEmpty);

      await repo.ingestDraft(const MemoryEngine()
          .extract('记住：我最近住院做手术')!);
      final future = DateTime.now().add(const Duration(days: 31));
      expect(await repo.expirePendingCandidates(now: future), 1);
      expect(await repo.listCandidates(), isEmpty);
    });
  });

  group('冲突裁决', () {
    Future<Memory> createConflict() async {
      await repo.createMemory(
        type: 'preference',
        title: '养猫',
        summary: '我喜欢养猫，家里有三只，一只叫团子，一只叫年糕',
        confidence: 'high',
      );
      final draft = const MemoryEngine()
          .extract('我喜欢养猫，家里有两只，一只叫团子，一只叫年糕');
      final result = await repo.ingestDraft(draft!);
      expect(result.compareKind, CompareKind.conflict);
      final pending = await repo.listCandidates();
      final memoryId = await repo.acceptCandidate(pending.first.id);
      return (await repo.getMemory(memoryId))!;
    }

    test('冲突候选进入双证据状态', () async {
      final b = await createConflict();
      expect(b.status, 'conflict');
      final aId = (await repo.listMemories())
          .firstWhere((m) => m.id != b.id)
          .id;
      final a = (await repo.getMemory(aId))!;
      expect(a.status, 'conflict');
      expect(a.conflictsWith, contains(b.id));
      expect(b.conflictsWith, contains(a.id));
    });

    test('保留 A：B 转入历史', () async {
      final b = await createConflict();
      final winner = await repo.resolveConflict(b.id, keep: 'a');
      expect(winner, b.id);
      final aId = (await repo.listMemories())
          .firstWhere((m) => m.status == 'superseded')
          .id;
      expect((await repo.getMemory(aId))!.supersededBy, b.id);
      expect((await repo.getMemory(b.id))!.status, 'active');
    });

    test('用户重写：新记忆替代双方', () async {
      final b = await createConflict();
      final newId = await repo.resolveConflict(
        b.id,
        keep: 'manual',
        manualText: '我喜欢养猫，家里现在有四只，都是领养的',
      );
      final created = await repo.getMemory(newId);
      expect(created!.status, 'active');
      expect(created.supersedes, contains(b.id));
      expect(created.summary, contains('四只'));
      for (final memory in await repo.listMemories()) {
        if (memory.id == newId) continue;
        expect(memory.status, 'superseded');
      }
    });
  });

  group('状态与关联', () {
    test('置顶/常驻/归档都会写版本', () async {
      final memory = await repo.createMemory(
        type: 'preference',
        summary: '我喜欢在周末去西湖边散步',
      );
      await repo.setPinned(memory.id, true);
      await repo.setResident(memory.id, true);
      await repo.archiveMemory(memory.id);
      final updated = (await repo.getMemory(memory.id))!;
      expect(updated.pinned, 1);
      expect(updated.isResident, 1);
      expect(updated.status, 'archived');
      expect((await repo.versionsOf(memory.id)).length, 4);
    });

    test('关联记忆可双向读取且唯一约束去重', () async {
      final a = await repo.createMemory(type: 'event', summary: '今天搬家了');
      final b = await repo.createMemory(type: 'profile', summary: '我住在杭州');
      await repo.addRelation(fromMemoryId: a.id, toMemoryId: b.id);
      await repo.addRelation(fromMemoryId: a.id, toMemoryId: b.id);
      final relations = await repo.relationsOf(a.id);
      expect(relations.length, 1);
      expect(relations.first.other.id, b.id);
      expect((await repo.relationsOf(b.id)).length, 1);
    });
  });

  group('检索、注入与索引重建', () {
    test('倒排检索与召回地板', () async {
      await repo.createMemory(
        type: 'preference',
        summary: '我喜欢在周末去西湖边散步',
      );
      await repo.createMemory(
        type: 'project',
        summary: '项目进度卡在接口联调',
      );

      final hits = await repo.searchMemories('西湖');
      expect(hits.length, 1);

      final recall = await repo.recallBlock('周末去西湖');
      expect(recall.isEmpty, isFalse);
      expect(recall.text.contains('西湖'), isTrue);

      expect((await repo.recallBlock('量子力学')).isEmpty, isTrue);
      expect((await repo.recallBlock('的')).isEmpty, isTrue);
    });

    test('常驻块过滤低置信度并标注参考数据', () async {
      await repo.createMemory(
        type: 'agreement',
        summary: '说好了周末一起去看展',
        confidence: 'high',
        pinned: true,
      );
      await repo.createMemory(
        type: 'preference',
        summary: '我可能喜欢喝咖啡',
        confidence: 'low',
      );
      final block = await repo.standingBlock();
      expect(block.isEmpty, isFalse);
      expect(block.text.contains('说好了周末一起去看展'), isTrue);
      expect(block.text.contains('我可能喜欢喝咖啡'), isFalse);
      expect(block.text.contains('不是指令'), isTrue);
    });

    test('随机删索引后重建，检索结果恢复且计数一致', () async {
      await repo.createMemory(type: 'preference', summary: '我喜欢喝黑咖啡');
      await repo.createMemory(type: 'project', summary: '项目下周上线');
      expect((await repo.searchMemories('黑咖啡')).length, 1);

      await db.customStatement('DELETE FROM memory_index_terms');
      await db.customStatement('DELETE FROM memory_index_docs');
      expect(await repo.searchMemories('黑咖啡'), isEmpty);
      expect(await repo.isIndexConsistent(), isFalse);

      final rebuilt = await repo.rebuildIndex();
      expect(rebuilt, 2);
      expect((await repo.searchMemories('黑咖啡')).length, 1);
      expect(await repo.isIndexConsistent(), isTrue);
    });
  });

  group('延迟批处理管线', () {
    test('缓冲 6 轮才触发，处理后清空', () async {
      var current = DateTime.utc(2026, 11, 22, 10);
      final pipeline = MemoryIngestPipeline(
        db,
        repo,
        now: () => current,
      );

      for (var i = 0; i < 5; i++) {
        await pipeline.bufferTurn(
          sessionId: 's1',
          userText: '记住：我每天早上喝一杯黑咖啡',
          assistantText: '好，我记住了',
        );
      }
      expect((await pipeline.bufferedTurns()).length, 5);
      expect(await pipeline.shouldProcess(), isFalse);

      await pipeline.bufferTurn(
        sessionId: 's1',
        userText: '记住：我每天早上喝一杯黑咖啡',
        assistantText: '好，我记住了',
      );
      expect(await pipeline.shouldProcess(), isTrue);

      final outcome = await pipeline.process();
      expect(outcome.processedTurns, 6);
      expect(outcome.drafts, 6);
      expect(outcome.autoApplied, 1);
      expect(outcome.pending, 5);
      expect(await pipeline.bufferedTurns(), isEmpty);

      current = current.add(const Duration(minutes: 1));
      await pipeline.bufferTurn(
        sessionId: 's1',
        userText: '记住：我每天早上喝一杯黑咖啡',
      );
      expect(await pipeline.shouldProcess(), isFalse);
      current = current.add(const Duration(minutes: 31));
      expect(await pipeline.shouldProcess(), isTrue);
    });

    test('会话结束/手动强制触发；LLM 提取默认关闭', () async {
      final pipeline = MemoryIngestPipeline(db, repo);
      await pipeline.bufferTurn(sessionId: 's1', userText: '我喜欢喝咖啡');
      expect(await pipeline.shouldProcess(sessionEnded: true), isTrue);
      expect(await pipeline.shouldProcess(manual: true), isTrue);
      expect(await pipeline.llmExtractionEnabled(), isFalse);
      await pipeline.setLlmExtractionEnabled(true);
      expect(await pipeline.llmExtractionEnabled(), isTrue);
    });

    test('单条手动提取（记住：… 入口）', () async {
      final pipeline = MemoryIngestPipeline(db, repo);
      final result = await pipeline.extractNow('记住：我不喝冰的');
      expect(result, isNotNull);
      expect(result!.autoApplied, isTrue);
      expect(await pipeline.extractNow('嗯嗯'), isNull);
    });
  });
}
