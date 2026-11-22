// 主动决策中心端到端单测（T8.1~T8.4）：候选池 → 过滤 → 执行留痕 → 反馈闭环。
// 使用内存数据库 + 注入固定时钟，验证任何候选都无法绕过用户硬限制。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/proactive/proactive_decision_center.dart';
import 'package:bubble/data/repositories/proactive_repository.dart';
import 'package:bubble/data/repositories/thinking_repository.dart';
import 'package:bubble/domain/proactive/proactive_models.dart';
import 'package:bubble/domain/thinking/thinking_models.dart';
import 'package:drift/drift.dart' show InsertMode, Value;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ProactiveRepository repo;
  late ThinkingRepository thinking;
  late ProactiveDecisionCenter center;
  late DateTime now;
  var counter = 0;

  DateTime clock() => now;
  int ms(DateTime value) => value.millisecondsSinceEpoch;

  setUp(() {
    now = DateTime(2026, 5, 20, 10, 0);
    counter = 0;
    db = AppDatabase(openInMemoryDatabase());
    repo = ProactiveRepository(db, clock: clock);
    thinking = ThinkingRepository(db);
    center = ProactiveDecisionCenter(
      db,
      repository: repo,
      clock: clock,
      deliverer: (candidate) async =>
          const ProactiveDelivery(deliverableType: 'record', note: '测试投递'),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<String> insertPending({
    ProactiveActionKind kind = ProactiveActionKind.chat,
    String draft = '想问问你今天过得怎么样',
    String? dedupKey = 'chat:hello',
    int priority = 60,
    DateTime? expiresAt,
    String sourceKind = 'history_chat',
  }) async {
    final id = 'cand_${counter++}';
    await thinking.insertCandidate(
      id: id,
      insight: ThinkingInsight(
        kind: ThinkingResultKind.newConnection,
        content: draft,
        actionKind: kind,
        priority: priority,
        dedupKey: dedupKey,
        sourceKind: sourceKind,
        title: '主动候选 $id',
      ),
      relatedTaskId: 'task_test',
      expiresAt: ms(expiresAt ?? now.add(const Duration(days: 7))),
    );
    return id;
  }

  group('执行与留痕', () {
    test('满足条件时执行一次并写执行记录', () async {
      final id = await insertPending();
      final result = await center.runOnce();

      expect(result.executed, 1);
      expect(result.executedCandidateId, id);
      expect(result.decisions.single.reason, ProactiveReason.eligible);

      final candidate = await repo.getCandidate(id);
      expect(candidate?.status, 'executed');
      final actions = await repo.recentActions();
      expect(actions.length, 1);
      expect(actions.single.actionKind, 'chat');
      expect(actions.single.deliverableType, 'record');
      expect(await repo.executedTodayTotal(), 1);
    });

    test('过期候选在运行前被置为 expired', () async {
      final id = await insertPending(expiresAt: DateTime(2026, 5, 20, 9, 0));
      final result = await center.runOnce();
      expect(result.expired, 1);
      expect(result.executed, 0);
      expect((await repo.getCandidate(id))?.status, 'expired');
    });

    test('优先级排序：高优先级候选先执行', () async {
      final low = await insertPending(
        draft: '明天一起看场电影吧',
        dedupKey: 'chat:low',
        priority: 20,
      );
      final high = await insertPending(
        draft: '今天想听你说说工作里的事',
        dedupKey: 'chat:high',
        priority: 90,
      );
      final result = await center.runOnce();
      expect(result.executedCandidateId, high);
      expect((await repo.getCandidate(high))?.status, 'executed');
      expect((await repo.getCandidate(low))?.status, 'pending');
    });
  });

  group('硬限制不可绕过', () {
    test('总开关关闭：高优先级候选也不会执行', () async {
      await repo.saveSettings(const ProactiveSettings(enabled: false));
      final id = await insertPending(priority: 100);
      final result = await center.runOnce();

      expect(result.executed, 0);
      expect(result.rejected, 1);
      expect(result.decisions.single.reason, ProactiveReason.hardLimitDisabled);
      expect((await repo.getCandidate(id))?.status, 'rejected');
      expect((await repo.recentActions()), isEmpty);
    });

    test('手动执行也必须服从硬限制', () async {
      await repo.saveSettings(const ProactiveSettings(enabled: false));
      final id = await insertPending();
      final decision = await center.executeManually(id);
      expect(decision.kind, ProactiveDecisionKind.reject);
      expect(decision.reason, ProactiveReason.hardLimitDisabled);
      expect((await repo.getCandidate(id))?.status, 'pending');
    });

    test('类别关闭后该类候选被拒绝', () async {
      await repo.saveSettings(const ProactiveSettings(disabledKinds: {'post'}));
      final id = await insertPending(kind: ProactiveActionKind.post);
      final result = await center.runOnce();
      expect(result.executed, 0);
      expect(
        result.decisions.single.reason,
        ProactiveReason.hardLimitKindDisabled,
      );
      expect((await repo.getCandidate(id))?.status, 'rejected');
    });
  });

  group('冷却 / 勿扰 / 上限 / 重复', () {
    test('勿扰时段顺延而不是丢弃', () async {
      now = DateTime(2026, 5, 20, 23, 30);
      final id = await insertPending();
      final result = await center.runOnce();

      expect(result.executed, 0);
      expect(result.deferred, 1);
      expect(result.decisions.single.reason, ProactiveReason.quietHours);
      final candidate = await repo.getCandidate(id);
      expect(candidate?.status, 'pending');
      expect(candidate?.cooldownUntil, ms(DateTime(2026, 5, 21, 8, 0)));
    });

    test('每日上限达到后拒绝留痕', () async {
      await repo.saveSettings(const ProactiveSettings(dailyCap: 1));
      final first = await insertPending(dedupKey: 'chat:one');
      await center.runOnce();
      expect((await repo.getCandidate(first))?.status, 'executed');

      now = now.add(const Duration(hours: 3));
      final second = await insertPending(
        draft: '第二个完全不同的话题',
        dedupKey: 'chat:two',
      );
      final result = await center.runOnce();
      expect(result.executed, 0);
      expect(result.decisions.single.reason, ProactiveReason.dailyCap);
      expect((await repo.getCandidate(second))?.status, 'rejected');
    });

    test('同 dedup_key 的候选不会重复表达', () async {
      final first = await insertPending(dedupKey: 'chat:same');
      await center.runOnce();

      now = now.add(const Duration(hours: 3));
      final second = await insertPending(
        draft: '完全不同的措辞也没用',
        dedupKey: 'chat:same',
      );
      final result = await center.runOnce();
      expect(result.executed, 0);
      expect(result.decisions.single.reason, ProactiveReason.duplicateKey);
      expect((await repo.getCandidate(second))?.status, 'rejected');
      expect((await repo.getCandidate(first))?.status, 'executed');
    });

    test('内容相似检测拦截换汤不换药的候选', () async {
      await insertPending(draft: '想问问你今天过得怎么样', dedupKey: 'chat:a');
      await center.runOnce();

      now = now.add(const Duration(hours: 3));
      final second = await insertPending(
        draft: '想问问你今天过得怎么样呀',
        dedupKey: 'chat:b',
      );
      final result = await center.runOnce();
      expect(result.executed, 0);
      expect(result.decisions.single.reason, ProactiveReason.duplicateContent);
      expect((await repo.getCandidate(second))?.status, 'rejected');
    });

    test('最短间隔未到 → 顺延并更新 cooldownUntil', () async {
      await insertPending(dedupKey: 'chat:a');
      await center.runOnce();

      now = now.add(const Duration(minutes: 20));
      final second = await insertPending(
        kind: ProactiveActionKind.post,
        draft: '今天看到一朵很像你的云',
        dedupKey: 'post:b',
      );
      final result = await center.runOnce();
      expect(result.executed, 0);
      expect(result.deferred, 1);
      expect(result.decisions.single.reason, ProactiveReason.minInterval);
      final candidate = await repo.getCandidate(second);
      expect(candidate?.status, 'pending');
      expect(candidate?.cooldownUntil, ms(DateTime(2026, 5, 20, 11, 0)));
    });
  });

  group('反馈闭环', () {
    test('“不太合适”只调整优先级与冷却，不改核心人格', () async {
      final id = await insertPending();
      await center.runOnce();
      final action = (await repo.recentActions()).single;

      final feedback = await repo.recordFeedback(
        candidateId: id,
        actionId: action.id,
        verdict: 'dislike',
        note: '这个话题太频繁了',
      );
      expect(feedback.verdict, 'dislike');

      final settings = await repo.loadSettings();
      final adjustment = settings.adjustmentFor(ProactiveActionKind.chat);
      expect(adjustment.priorityDelta, -10);
      expect(adjustment.cooldownMultiplier, 1.5);

      final updatedAction = (await repo.recentActions()).single;
      expect(updatedAction.userFeedbackId, feedback.id);
    });

    test('撤销反馈后调整回滚但记录保留', () async {
      final id = await insertPending();
      await center.runOnce();
      final action = (await repo.recentActions()).single;
      final feedback = await repo.recordFeedback(
        candidateId: id,
        actionId: action.id,
        verdict: 'dislike',
      );

      await repo.revertFeedback(feedback.id);
      final settings = await repo.loadSettings();
      expect(settings.adjustmentFor(ProactiveActionKind.chat).priorityDelta, 0);
      expect(
        settings.adjustmentFor(ProactiveActionKind.chat).cooldownMultiplier,
        1.0,
      );
      final rows = await repo.recentFeedback();
      expect(rows.single.revertedAt, isNotNull);
    });

    test('反馈累计：两次“不太合适”冷却倍率递增且封顶 3 倍', () async {
      final id = await insertPending();
      await center.runOnce();
      final action = (await repo.recentActions()).single;
      await repo.recordFeedback(
        candidateId: id,
        actionId: action.id,
        verdict: 'dislike',
      );
      await repo.recordFeedback(
        candidateId: id,
        actionId: action.id,
        verdict: 'adjust',
      );
      final settings = await repo.loadSettings();
      // 1.5 × 2.0 = 3.0（封顶）
      expect(
        settings.adjustmentFor(ProactiveActionKind.chat).cooldownMultiplier,
        3.0,
      );
    });
  });

  group('设置持久化', () {
    test('保存后重新加载保持一致，损坏配置回退默认积极档', () async {
      await repo.saveSettings(
        const ProactiveSettings(
          level: ProactivityLevel.conservative,
          quietStart: '22:00',
          quietEnd: '07:00',
          dailyCap: 2,
        ),
      );
      final restored = await repo.loadSettings();
      expect(restored.level, ProactivityLevel.conservative);
      expect(restored.quietStart, '22:00');
      expect(restored.effectiveDailyCap, 2);

      await db
          .into(db.appSettings)
          .insert(
            AppSettingsCompanion.insert(
              key: ProactiveRepository.settingsKey,
              value: const Value('{损坏的 JSON'),
              updatedAt: DateTime.now().toUtc().toIso8601String(),
            ),
            mode: InsertMode.insertOrReplace,
          );
      final fallback = await repo.loadSettings();
      expect(fallback.level, ProactivityLevel.active);
      expect(fallback.enabled, isTrue);
    });
  });
}
