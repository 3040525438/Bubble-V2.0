// 主动决策策略单测（T8.2）：硬限制 > 过期 > 重复 > 冷却 > 勿扰 > 每日上限 > 最短间隔。
// 全部使用注入的固定时刻，不依赖系统时间（等价 fakeAsync 时钟）。
import 'package:bubble/domain/proactive/proactive_models.dart';
import 'package:bubble/domain/proactive/proactive_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = ProactivePolicy();

  int ms(DateTime time) => time.millisecondsSinceEpoch;

  ProactiveCandidateView candidate({
    String id = 'c1',
    ProactiveActionKind kind = ProactiveActionKind.chat,
    int priority = 60,
    String? draft = '想问问你今天过得怎么样',
    String? dedupKey = 'chat:hello',
    int? expiresAtMs,
    int? cooldownUntilMs,
  }) {
    return ProactiveCandidateView(
      id: id,
      actionKind: kind,
      priority: priority,
      createdAtMs: ms(DateTime(2026, 5, 20, 9, 0)),
      title: '主动问候',
      contentDraft: draft,
      sourceKind: 'history_chat',
      dedupKey: dedupKey,
      expiresAtMs: expiresAtMs,
      cooldownUntilMs: cooldownUntilMs,
    );
  }

  ProactiveDecisionContext context({
    required DateTime now,
    ProactiveSettings settings = const ProactiveSettings(),
    int executedTodayTotal = 0,
    DateTime? lastProactiveAt,
    List<RecentProactiveOutput> outputs = const <RecentProactiveOutput>[],
  }) {
    return ProactiveDecisionContext(
      nowMs: ms(now),
      settings: settings,
      executedTodayTotal: executedTodayTotal,
      lastProactiveAtMs: lastProactiveAt == null ? null : ms(lastProactiveAt),
      recentOutputs: outputs,
    );
  }

  group('用户硬限制（FR-SET-02 优先级最高）', () {
    test('总开关关闭时任何候选都被拒绝', () {
      final decision = policy.evaluate(
        candidate(),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          settings: const ProactiveSettings(enabled: false),
        ),
      );
      expect(decision.kind, ProactiveDecisionKind.reject);
      expect(decision.reason, ProactiveReason.hardLimitDisabled);
      expect(decision.reason.isHardLimit, isTrue);
    });

    test('关闭某一类行为后该类候选被拒绝', () {
      final decision = policy.evaluate(
        candidate(kind: ProactiveActionKind.post),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          settings: const ProactiveSettings(disabledKinds: {'post'}),
        ),
      );
      expect(decision.kind, ProactiveDecisionKind.reject);
      expect(decision.reason, ProactiveReason.hardLimitKindDisabled);
    });

    test('硬限制优先于过期与冷却', () {
      final decision = policy.evaluate(
        candidate(expiresAtMs: ms(DateTime(2026, 5, 20, 9, 30))),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          settings: const ProactiveSettings(enabled: false),
        ),
      );
      expect(decision.reason, ProactiveReason.hardLimitDisabled);
    });
  });

  group('过期与重复', () {
    test('过期候选被拒绝', () {
      final decision = policy.evaluate(
        candidate(expiresAtMs: ms(DateTime(2026, 5, 20, 9, 59))),
        context(now: DateTime(2026, 5, 20, 10, 0)),
      );
      expect(decision.kind, ProactiveDecisionKind.reject);
      expect(decision.reason, ProactiveReason.expired);
    });

    test('dedup_key 命中近期输出 → 拒绝避免重复', () {
      final decision = policy.evaluate(
        candidate(dedupKey: 'chat:hello'),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          outputs: [
            RecentProactiveOutput(
              kind: ProactiveActionKind.chat,
              text: '今天有什么新鲜事吗',
              atMs: ms(DateTime(2026, 5, 19, 12, 0)),
              dedupKey: 'chat:hello',
            ),
          ],
        ),
      );
      expect(decision.reason, ProactiveReason.duplicateKey);
    });

    test('内容过于相似 → 拒绝', () {
      final decision = policy.evaluate(
        candidate(draft: '想问问你今天过得怎么样呀'),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          outputs: [
            RecentProactiveOutput(
              kind: ProactiveActionKind.chat,
              text: '想问问你今天过得怎么样',
              atMs: ms(DateTime(2026, 5, 19, 12, 0)),
            ),
          ],
        ),
      );
      expect(decision.reason, ProactiveReason.duplicateContent);
    });

    test('超出去重窗口的历史输出不再拦截', () {
      final decision = policy.evaluate(
        candidate(),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          settings: const ProactiveSettings(dedupWindowDays: 14),
          outputs: [
            RecentProactiveOutput(
              kind: ProactiveActionKind.chat,
              text: '想问问你今天过得怎么样',
              atMs: ms(DateTime(2026, 4, 1, 12, 0)),
              dedupKey: 'chat:hello',
            ),
          ],
        ),
      );
      expect(decision.kind, ProactiveDecisionKind.execute);
    });
  });

  group('冷却 / 勿扰 / 上限 / 间隔', () {
    test('同类冷却未到 → 顺延到冷却结束', () {
      final lastAt = DateTime(2026, 5, 20, 9, 30);
      final decision = policy.evaluate(
        candidate(),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          outputs: [
            RecentProactiveOutput(
              kind: ProactiveActionKind.chat,
              text: '另一个完全不同的话题内容',
              atMs: ms(lastAt),
            ),
          ],
        ),
      );
      expect(decision.kind, ProactiveDecisionKind.defer);
      expect(decision.reason, ProactiveReason.cooldown);
      // 默认 chat 冷却 90 分钟 → 11:00
      expect(
        decision.nextEligibleAtMs,
        ms(lastAt.add(const Duration(minutes: 90))),
      );
    });

    test('勿扰时段（跨午夜）→ 顺延到次日勿扰结束', () {
      final decision = policy.evaluate(
        candidate(),
        context(now: DateTime(2026, 5, 20, 23, 30)),
      );
      expect(decision.kind, ProactiveDecisionKind.defer);
      expect(decision.reason, ProactiveReason.quietHours);
      expect(decision.nextEligibleAtMs, ms(DateTime(2026, 5, 21, 8, 0)));
    });

    test('勿扰结束前候选就会过期 → 拒绝', () {
      final decision = policy.evaluate(
        candidate(expiresAtMs: ms(DateTime(2026, 5, 21, 7, 0))),
        context(now: DateTime(2026, 5, 20, 23, 30)),
      );
      expect(decision.kind, ProactiveDecisionKind.reject);
      expect(decision.reason, ProactiveReason.expired);
    });

    test('当日主动次数达上限 → 拒绝留痕', () {
      final decision = policy.evaluate(
        candidate(),
        context(now: DateTime(2026, 5, 20, 10, 0), executedTodayTotal: 6),
      );
      expect(decision.kind, ProactiveDecisionKind.reject);
      expect(decision.reason, ProactiveReason.dailyCap);
    });

    test('距上次主动时间不足最短间隔 → 顺延', () {
      final lastAt = DateTime(2026, 5, 20, 9, 30);
      final decision = policy.evaluate(
        candidate(kind: ProactiveActionKind.post, dedupKey: 'post:x'),
        context(now: DateTime(2026, 5, 20, 10, 0), lastProactiveAt: lastAt),
      );
      expect(decision.kind, ProactiveDecisionKind.defer);
      expect(decision.reason, ProactiveReason.minInterval);
      expect(
        decision.nextEligibleAtMs,
        ms(lastAt.add(const Duration(minutes: 60))),
      );
    });

    test('全部条件满足 → 执行', () {
      final decision = policy.evaluate(
        candidate(),
        context(now: DateTime(2026, 5, 20, 10, 0)),
      );
      expect(decision.kind, ProactiveDecisionKind.execute);
      expect(decision.reason, ProactiveReason.eligible);
    });

    test('安静决策不占每日上限与最短间隔，作为正式决策记录', () {
      final decision = policy.evaluate(
        candidate(
          kind: ProactiveActionKind.quiet,
          draft: '今晚先不打扰',
          dedupKey: 'quiet:2026-05-20',
        ),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          executedTodayTotal: 6,
          lastProactiveAt: DateTime(2026, 5, 20, 9, 55),
        ),
      );
      expect(decision.kind, ProactiveDecisionKind.execute);
    });
  });

  group('三档参数与反馈调整', () {
    test('三档默认每日上限与最短间隔符合产品设定', () {
      expect(ProactivityLevel.conservative.defaultDailyCap, 2);
      expect(ProactivityLevel.conservative.defaultMinIntervalMinutes, 120);
      expect(ProactivityLevel.balanced.defaultDailyCap, 4);
      expect(ProactivityLevel.balanced.defaultMinIntervalMinutes, 90);
      expect(ProactivityLevel.active.defaultDailyCap, 6);
      expect(ProactivityLevel.active.defaultMinIntervalMinutes, 60);
      expect(const ProactiveSettings().level, ProactivityLevel.active);
    });

    test('反馈调高/调低优先级用于排序', () {
      final settings = const ProactiveSettings(
        adjustments: {'chat': ProactiveAdjustment(priorityDelta: 15)},
      );
      expect(policy.effectivePriority(candidate(priority: 60), settings), 75);
      final lowered = const ProactiveSettings(
        adjustments: {'chat': ProactiveAdjustment(priorityDelta: -20)},
      );
      expect(policy.effectivePriority(candidate(priority: 60), lowered), 40);
    });

    test('反馈放大冷却倍率后顺延时间变长', () {
      final lastAt = DateTime(2026, 5, 20, 9, 30);
      final decision = policy.evaluate(
        candidate(),
        context(
          now: DateTime(2026, 5, 20, 10, 0),
          settings: const ProactiveSettings(
            adjustments: {'chat': ProactiveAdjustment(cooldownMultiplier: 2.0)},
          ),
          outputs: [
            RecentProactiveOutput(
              kind: ProactiveActionKind.chat,
              text: '完全不同的话题',
              atMs: ms(lastAt),
            ),
          ],
        ),
      );
      expect(decision.kind, ProactiveDecisionKind.defer);
      // 90 分钟 × 2 = 180 分钟
      expect(
        decision.nextEligibleAtMs,
        ms(lastAt.add(const Duration(minutes: 180))),
      );
    });

    test('设置 JSON 往返无损', () {
      final settings = ProactiveSettings(
        level: ProactivityLevel.balanced,
        enabled: false,
        quietStart: '22:30',
        quietEnd: '07:30',
        dailyCap: 3,
        minIntervalMinutes: 45,
        disabledKinds: const {'post'},
        adjustments: const {
          'chat': ProactiveAdjustment(
            priorityDelta: 5,
            cooldownMultiplier: 1.5,
          ),
        },
      );
      final restored = ProactiveSettings.fromJson(settings.toJson());
      expect(restored.level, ProactivityLevel.balanced);
      expect(restored.enabled, isFalse);
      expect(restored.quietStart, '22:30');
      expect(restored.quietEnd, '07:30');
      expect(restored.effectiveDailyCap, 3);
      expect(restored.effectiveMinIntervalMinutes, 45);
      expect(restored.disabledKinds, contains('post'));
      expect(restored.adjustmentFor(ProactiveActionKind.chat).priorityDelta, 5);
      expect(
        restored.adjustmentFor(ProactiveActionKind.chat).cooldownMultiplier,
        1.5,
      );
    });
  });

  group('时间与相似度工具', () {
    test('勿扰判定支持同日与跨午夜', () {
      expect(
        isInQuietHours(ms(DateTime(2026, 5, 20, 12, 0)), '13:00', '14:00'),
        isFalse,
      );
      expect(
        isInQuietHours(ms(DateTime(2026, 5, 20, 13, 30)), '13:00', '14:00'),
        isTrue,
      );
      expect(
        isInQuietHours(ms(DateTime(2026, 5, 20, 23, 30)), '23:00', '08:00'),
        isTrue,
      );
      expect(
        isInQuietHours(ms(DateTime(2026, 5, 20, 7, 30)), '23:00', '08:00'),
        isTrue,
      );
      expect(
        isInQuietHours(ms(DateTime(2026, 5, 20, 12, 0)), '23:00', '08:00'),
        isFalse,
      );
      expect(
        isInQuietHours(ms(DateTime(2026, 5, 20, 12, 0)), '12:00', '12:00'),
        isFalse,
      );
    });

    test('HH:mm 解析非法输入返回 null', () {
      expect(parseHhmm('23:00'), 23 * 60);
      expect(parseHhmm('7:05'), 7 * 60 + 5);
      expect(parseHhmm('24:00'), isNull);
      expect(parseHhmm('abc'), isNull);
    });

    test('相似度：相同为 1，完全不同接近 0', () {
      expect(contentSimilarity('今天想你了', '今天想你了'), 1.0);
      expect(contentSimilarity('今天想你了', '明天要下雨'), lessThan(0.2));
      expect(contentSimilarity('', '任何内容'), 0);
    });
  });
}
