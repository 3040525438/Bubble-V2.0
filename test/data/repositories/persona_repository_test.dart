// 人格仓储测试（T4.2）：核心门禁、成长审批、版本恢复、表达样本。
// 关键断言：任何未经用户确认的路径都不能写入 core 层（FR-PER-02）。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/data/repositories/persona_repository.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

Future<PersonaRepository> _newRepo() async {
  final db = AppDatabase(openInMemoryDatabase());
  final repo = PersonaRepository(db);
  await repo.ensureSeed();
  return repo;
}

void main() {
  group('初始化', () {
    test('首次建库生成单行档案、core v1(init) 与快照', () async {
      final db = AppDatabase(openInMemoryDatabase());
      addTearDown(db.close);
      final repo = PersonaRepository(db);
      await repo.ensureSeed();
      await repo.ensureSeed(); // 幂等

      final profiles = await db.select(db.personaProfiles).get();
      expect(profiles.length, 1);
      expect(profiles.first.name, '泡泡');

      final core = await repo.activeVersion('core');
      expect(core, isNotNull);
      expect(core!.versionNo, 1);
      expect(core.confirmedBy, 'init');
      expect(core.isActive, 1);

      final growth = await repo.activeVersion('growth');
      expect(growth, isNotNull);
      expect(growth!.confirmedBy, 'init');

      final prompt = profiles.first.coreSystemPrompt ?? '';
      expect(prompt, contains('【核心人格 v1】'));
      expect(prompt, contains('【表达约束】'));
      expect(prompt, contains('禁止客服腔'));
    });
  });

  group('核心人格门禁', () {
    test('未确认的保存被拒绝且不产生版本', () async {
      final repo = await _newRepo();
      final before = (await repo.versions()).length;
      final edited = (await repo.coreFields()).copyWith(personality: '被模型偷偷改掉');

      await expectLater(
        repo.saveCore(edited),
        throwsA(isA<StateError>()),
      );
      expect((await repo.versions()).length, before);
      expect((await repo.coreFields()).personality, isNot('被模型偷偷改掉'));
    });

    test('用户确认后生成新版本、旧版本失活、快照更新', () async {
      final repo = await _newRepo();
      final original = await repo.coreFields();
      final edited = original.copyWith(speakingStyle: '更短、更轻，偶尔用语气词。');

      final created = await repo.saveCore(
        edited,
        userConfirmed: true,
        reason: '测试修改说话习惯',
      );

      expect(created.versionNo, 3); // v1 核心 + v2 成长基线后全局递增
      expect(created.layer, 'core');
      expect(created.confirmedBy, 'user');
      expect(created.isActive, 1);

      final versions = await repo.versions(layer: 'core');
      final v1 = versions.firstWhere((v) => v.versionNo == 1);
      expect(v1.isActive, 0);

      final active = await repo.activeVersion('core');
      expect(active!.id, created.id);
      expect((await repo.coreFields()).speakingStyle, '更短、更轻，偶尔用语气词。');

      final profile = await repo.profile();
      expect(profile.activeVersionId, created.id);
      expect(profile.coreSystemPrompt, contains('更短、更轻'));
    });
  });

  group('成长建议审批', () {
    test('提议不生成版本，接受后仅改成长层并生成新版本', () async {
      final repo = await _newRepo();
      final coreCountBefore = (await repo.versions(layer: 'core')).length;
      final growthCountBefore = (await repo.versions(layer: 'growth')).length;

      final id = await repo.proposeGrowth(
        growthType: '称呼',
        beforeValue: '你',
        afterValue: '阿岚',
        reason: '你希望我这样叫你',
      );
      expect(await repo.pendingGrowthCount(), 1);
      expect((await repo.versions()).length,
          coreCountBefore + growthCountBefore);

      final version = await repo.acceptGrowth(id);
      expect(version.layer, 'growth');
      expect(version.versionNo, greaterThan(1));
      expect((await repo.versions(layer: 'growth')).length,
          growthCountBefore + 1);
      // 核心层完全不受影响
      expect((await repo.versions(layer: 'core')).length, coreCountBefore);
      expect((await repo.growthValues()).valueOf('称呼'), '阿岚');
      expect(await repo.pendingGrowthCount(), 0);

      final record = await repo.getGrowthRecord(id);
      expect(record!.status, 'confirmed');
      expect(record.confirmedAt, isNotNull);
      expect(record.versionId, version.id);
    });

    test('编辑后接受使用用户版本', () async {
      final repo = await _newRepo();
      final id = await repo.proposeGrowth(
        growthType: '口头禅',
        afterValue: '好耶',
        reason: '常出现',
      );
      await repo.acceptGrowth(id, editedAfterValue: '好呀');
      expect((await repo.growthValues()).valueOf('口头禅'), '好呀');
      expect((await repo.getGrowthRecord(id))!.afterValue, '好呀');
    });

    test('拒绝留痕且不改成长层', () async {
      final repo = await _newRepo();
      final before = (await repo.growthValues()).values;
      final id = await repo.proposeGrowth(
        growthType: '观点变化',
        beforeValue: '喜欢雨天',
        afterValue: '不喜欢雨天',
        reason: '推测',
      );
      await repo.rejectGrowth(id);
      final record = await repo.getGrowthRecord(id);
      expect(record!.status, 'reverted');
      expect(await repo.pendingGrowthCount(), 0);
      expect((await repo.growthValues()).values, before);
    });
  });

  group('版本恢复', () {
    test('恢复生成新版本且内容等于历史版本', () async {
      final repo = await _newRepo();
      final v1 = await repo.activeVersion('core');
      final v1Content = (await repo.coreFields()).personality;

      await repo.saveCore(
        (await repo.coreFields()).copyWith(personality: '临时改动'),
        userConfirmed: true,
      );
      expect((await repo.coreFields()).personality, '临时改动');

      final restored = await repo.restoreVersion(v1!.id);
      expect(restored.versionNo, 4);
      expect(restored.content, v1.content);
      expect(restored.confirmedBy, 'user');
      expect((await repo.coreFields()).personality, v1Content);
      expect((await repo.versions()).first.id, restored.id);
    });
  });

  group('表达样本', () {
    test('添加/置顶/软删', () async {
      final repo = await _newRepo();
      final id = await repo.addSample(
        content: '“慢一点也没关系，我等你。”',
        contextNote: '安慰你时',
        pinned: true,
      );
      var samples = await repo.listSamples();
      expect(samples.length, 1);
      expect(samples.first.pinned, 1);

      await repo.setSamplePinned(id, false);
      samples = await repo.listSamples();
      expect(samples.first.pinned, 0);

      await repo.deleteSample(id);
      expect(await repo.listSamples(), isEmpty);
      expect((await repo.listSamples(includeDeleted: true)).length, 1);
    });

    test('最近助手消息可用于沉淀样本', () async {
      final db = AppDatabase(openInMemoryDatabase());
      addTearDown(db.close);
      final repo = PersonaRepository(db);
      await repo.ensureSeed();
      final conversation = await ConversationRepository(db)
          .createConversation(title: '样本来源');

      final now = DateTime.now().toUtc().toIso8601String();
      await db.into(db.messages).insert(MessagesCompanion.insert(
            id: 'm_sample_1',
            conversationId: conversation.id,
            role: 'assistant',
            seq: 1,
            content: '今天的云很好看。',
            status: 'sent',
            createdAt: now,
            updatedAt: now,
          ));
      await db.into(db.messages).insert(MessagesCompanion.insert(
            id: 'm_sample_2',
            conversationId: conversation.id,
            role: 'assistant',
            seq: 2,
            content: '已删除的旧回复',
            status: 'deleted',
            deletedAt: Value(now),
            createdAt: now,
            updatedAt: now,
          ));

      final recent = await repo.recentAssistantMessages();
      expect(recent.map((m) => m.id), contains('m_sample_1'));
      expect(recent.map((m) => m.id), isNot(contains('m_sample_2')));
    });
  });

  group('提示词快照', () {
    test('置顶样本参与组装且不超过 6 条', () async {
      final repo = await _newRepo();
      for (var i = 1; i <= 8; i++) {
        await repo.addSample(content: '样本句子 $i', pinned: true);
      }
      final prompt = await repo.rebuildPromptSnapshot();
      expect(RegExp('样本句子').allMatches(prompt).length, 6);
      expect(prompt, contains('【表达风格参照'));
      expect((await repo.profile()).coreSystemPrompt, prompt);
    });
  });
}
