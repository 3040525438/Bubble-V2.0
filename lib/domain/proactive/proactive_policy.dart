// 主动行为过滤策略（T8.2）：纯函数 + 时钟注入，按 AUTONOMOUS_SYSTEM §2.2 全项顺序判定。
// 硬限制（用户总开关 / 类别开关）优先级最高（FR-SET-02），任何候选都无法绕过。
import '../text/text_similarity.dart';
import 'proactive_models.dart';

export '../text/text_similarity.dart' show contentSimilarity, textBigrams;

class ProactivePolicy {
  const ProactivePolicy();

  /// 评估单个候选。返回 execute / defer / reject 与可解释原因。
  ProactiveDecision evaluate(
    ProactiveCandidateView candidate,
    ProactiveDecisionContext context,
  ) {
    final settings = context.settings;
    final nowMs = context.nowMs;

    // ① 用户硬限制（FR-SET-02 优先级最高）
    if (!settings.enabled) {
      return ProactiveDecision(
        candidateId: candidate.id,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.hardLimitDisabled,
        note: '主动行为总开关已关闭，任何候选都不得执行',
      );
    }
    if (settings.disabledKinds.contains(candidate.actionKind.wire)) {
      return ProactiveDecision(
        candidateId: candidate.id,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.hardLimitKindDisabled,
        note: '${candidate.actionKind.label}已被你单独关闭',
      );
    }

    // ② 过期检查
    final expiresAt = candidate.expiresAtMs;
    if (expiresAt != null && nowMs >= expiresAt) {
      return ProactiveDecision(
        candidateId: candidate.id,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.expired,
        note: '候选已过期，不再执行',
      );
    }

    // 安静决策是正式决策记录，不受打扰类限制（冷却/上限/间隔）
    if (candidate.actionKind == ProactiveActionKind.quiet) {
      return ProactiveDecision(
        candidateId: candidate.id,
        kind: ProactiveDecisionKind.execute,
        reason: ProactiveReason.eligible,
        note: '安静也是正式决策：记录此刻选择不打扰',
      );
    }

    // ③ 重复检测：dedup_key + 近期内容相似度
    final windowStartMs =
        nowMs - Duration(days: settings.dedupWindowDays).inMilliseconds;
    final inWindow = context.recentOutputs
        .where((output) => output.atMs >= windowStartMs)
        .toList();

    final dedupKey = candidate.dedupKey;
    if (dedupKey != null && dedupKey.isNotEmpty) {
      final hit = inWindow.any((output) => output.dedupKey == dedupKey);
      if (hit) {
        return ProactiveDecision(
          candidateId: candidate.id,
          kind: ProactiveDecisionKind.reject,
          reason: ProactiveReason.duplicateKey,
          note: '同主题近期已经表达过，避免重复',
        );
      }
    }

    final draft = (candidate.contentDraft ?? '').trim();
    if (draft.isNotEmpty) {
      for (final output in inWindow) {
        if (output.kind != candidate.actionKind) continue;
        if (output.text.trim().isEmpty) continue;
        if (contentSimilarity(draft, output.text) >=
            settings.contentSimilarityThreshold) {
          return ProactiveDecision(
            candidateId: candidate.id,
            kind: ProactiveDecisionKind.reject,
            reason: ProactiveReason.duplicateContent,
            note: '内容与近期表达过于相似，避免重复表达',
          );
        }
      }
    }

    // ④ 同类冷却（反馈会放大冷却倍率）
    final adjustment = settings.adjustmentFor(candidate.actionKind);
    final cooldownMs =
        (settings.cooldownMinutesFor(candidate.actionKind) *
                60 *
                1000 *
                adjustment.cooldownMultiplier)
            .round();
    if (cooldownMs > 0) {
      final lastSameKindMs = _lastExecutedAtFor(candidate.actionKind, inWindow);
      if (lastSameKindMs != null && nowMs < lastSameKindMs + cooldownMs) {
        return ProactiveDecision(
          candidateId: candidate.id,
          kind: ProactiveDecisionKind.defer,
          reason: ProactiveReason.cooldown,
          nextEligibleAtMs: lastSameKindMs + cooldownMs,
          note: '同类行为冷却中，顺延而非丢弃',
        );
      }
    }

    // ⑤ 勿扰时段：顺延到勿扰结束（不丢弃）
    final quietEndMs = nextQuietEndMs(
      nowMs,
      settings.quietStart,
      settings.quietEnd,
    );
    if (quietEndMs != null) {
      if (expiresAt != null && quietEndMs >= expiresAt) {
        return ProactiveDecision(
          candidateId: candidate.id,
          kind: ProactiveDecisionKind.reject,
          reason: ProactiveReason.expired,
          note: '勿扰结束前候选就会过期',
        );
      }
      return ProactiveDecision(
        candidateId: candidate.id,
        kind: ProactiveDecisionKind.defer,
        reason: ProactiveReason.quietHours,
        nextEligibleAtMs: quietEndMs,
        note: '当前是勿扰时段，顺延到 ${settings.quietEnd}',
      );
    }

    // ⑥ 每日上限：当日主动次数达上限 → 拒绝留痕
    if (context.executedTodayTotal >= settings.effectiveDailyCap) {
      return ProactiveDecision(
        candidateId: candidate.id,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.dailyCap,
        note: '今日主动次数已达上限 ${settings.effectiveDailyCap} 次',
      );
    }

    // ⑦ 全局最短间隔
    final lastProactiveAtMs = context.lastProactiveAtMs;
    if (lastProactiveAtMs != null) {
      final intervalMs = Duration(minutes: settings.effectiveMinIntervalMinutes)
          .inMilliseconds;
      if (nowMs < lastProactiveAtMs + intervalMs) {
        return ProactiveDecision(
          candidateId: candidate.id,
          kind: ProactiveDecisionKind.defer,
          reason: ProactiveReason.minInterval,
          nextEligibleAtMs: lastProactiveAtMs + intervalMs,
          note: '距上次主动时间太近，顺延到最短间隔之后',
        );
      }
    }

    return ProactiveDecision(
      candidateId: candidate.id,
      kind: ProactiveDecisionKind.execute,
      reason: ProactiveReason.eligible,
      note: '通过全部过滤，执行并留下记录',
    );
  }

  /// 反馈调整后的有效优先级（0-100）
  int effectivePriority(
    ProactiveCandidateView candidate,
    ProactiveSettings settings,
  ) {
    final delta = settings.adjustmentFor(candidate.actionKind).priorityDelta;
    return (candidate.priority + delta).clamp(0, 100);
  }

  int? _lastExecutedAtFor(
    ProactiveActionKind kind,
    List<RecentProactiveOutput> outputs,
  ) {
    int? latest;
    for (final output in outputs) {
      if (output.kind != kind) continue;
      if (latest == null || output.atMs > latest) latest = output.atMs;
    }
    return latest;
  }
}

/// 当前是否处于勿扰时段（支持跨午夜；起止相同视为无勿扰）
bool isInQuietHours(int nowMs, String start, String end) {
  final startMinutes = parseHhmm(start);
  final endMinutes = parseHhmm(end);
  if (startMinutes == null || endMinutes == null) return false;
  if (startMinutes == endMinutes) return false;
  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final minutes = now.hour * 60 + now.minute;
  if (startMinutes < endMinutes) {
    return minutes >= startMinutes && minutes < endMinutes;
  }
  return minutes >= startMinutes || minutes < endMinutes;
}

/// 若当前处于勿扰时段，返回勿扰结束时刻（毫秒）；否则返回 null
int? nextQuietEndMs(int nowMs, String start, String end) {
  if (!isInQuietHours(nowMs, start, end)) return null;
  final endMinutes = parseHhmm(end);
  if (endMinutes == null) return null;
  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final today = DateTime(now.year, now.month, now.day);
  final endToday = today.add(Duration(minutes: endMinutes));
  final startMinutes = parseHhmm(start) ?? 0;
  if (startMinutes > endMinutes) {
    // 跨午夜：结束可能在今天凌晨或明天凌晨
    if (now.isBefore(endToday)) return endToday.millisecondsSinceEpoch;
    return today
        .add(Duration(days: 1, minutes: endMinutes))
        .millisecondsSinceEpoch;
  }
  return endToday.millisecondsSinceEpoch;
}

/// "HH:mm" → 当天分钟数；非法返回 null
int? parseHhmm(String value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
  if (match == null) return null;
  final hour = int.tryParse(match.group(1) ?? '');
  final minute = int.tryParse(match.group(2) ?? '');
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return hour * 60 + minute;
}
