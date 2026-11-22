// 主动行为决策中心（T8.2/T8.3）：唯一执行入口（FR-DEC-01/03）。
// 其他模块只能写候选；本类负责统一过滤、执行、留痕与反馈读取。
import 'package:flutter/foundation.dart';

import '../../domain/proactive/proactive_models.dart';
import '../../domain/proactive/proactive_policy.dart';
import '../database/app_database.dart';
import '../repositories/proactive_repository.dart';

/// 执行投递结果（阶段 8 只落记录；内容生成在阶段 10/13 接入）
class ProactiveDelivery {
  const ProactiveDelivery({
    this.deliverableType,
    this.deliverableId,
    this.note,
  });

  final String? deliverableType;
  final String? deliverableId;
  final String? note;
}

typedef ProactiveDeliverer = Future<ProactiveDelivery?> Function(
  ProactiveCandidate candidate,
);

/// 默认投递器：记录模式（不生成内容、不发消息）
Future<ProactiveDelivery?> recordOnlyDeliverer(
  ProactiveCandidate candidate,
) async {
  return const ProactiveDelivery(note: '阶段 8 记录模式：内容生成与投递在后续阶段接入');
}

class ProactiveDecisionCenter {
  ProactiveDecisionCenter(
    AppDatabase db, {
    ProactiveRepository? repository,
    ProactivePolicy policy = const ProactivePolicy(),
    DateTime Function()? clock,
    ProactiveDeliverer? deliverer,
  }) : _repository = repository ?? ProactiveRepository(db, clock: clock),
       _policy = policy,
       _clock = clock ?? DateTime.now,
       _deliverer = deliverer ?? recordOnlyDeliverer;

  final ProactiveRepository _repository;
  final ProactivePolicy _policy;
  final DateTime Function() _clock;
  final ProactiveDeliverer _deliverer;

  ProactiveRepository get repository => _repository;

  /// 运行一轮决策：过期扫描 → 优先级排序 → 逐个过滤 → 执行/顺延/拒绝留痕。
  Future<ProactiveRunResult> runOnce({int maxCandidates = 50}) async {
    final nowMs = _clock().millisecondsSinceEpoch;
    final expiredCount = await _repository.expireDueCandidates(nowMs);
    final settings = await _repository.loadSettings();
    final pending = await _repository.pendingCandidates(limit: maxCandidates);
    if (pending.isEmpty) {
      return ProactiveRunResult.empty.copyWithExpired(expiredCount);
    }

    final views = pending.map(_toView).toList()
      ..sort((a, b) {
        final priorityCompare = _policy
            .effectivePriority(b, settings)
            .compareTo(_policy.effectivePriority(a, settings));
        if (priorityCompare != 0) return priorityCompare;
        return a.createdAtMs.compareTo(b.createdAtMs);
      });

    var executedTodayTotal = await _repository.executedTodayTotal();
    final executedTodayByKind = await _repository.executedTodayByKind();
    var lastProactiveAtMs = await _repository.lastProactiveAtMs();
    final recentOutputs = await _repository.recentOutputs();

    final decisions = <ProactiveDecision>[];
    var executed = 0;
    var deferred = 0;
    var rejected = 0;
    String? executedCandidateId;

    for (final view in views) {
      final context = ProactiveDecisionContext(
        nowMs: nowMs,
        settings: settings,
        executedTodayTotal: executedTodayTotal,
        executedTodayByKind: executedTodayByKind,
        lastProactiveAtMs: lastProactiveAtMs,
        recentOutputs: recentOutputs,
      );
      var decision = _policy.evaluate(view, context);

      // 已有顺延时间且未到：不因重新评估而提前
      final existingEligible = view.cooldownUntilMs;
      if (decision.isDefer &&
          existingEligible != null &&
          decision.nextEligibleAtMs != null &&
          existingEligible > decision.nextEligibleAtMs!) {
        decision = ProactiveDecision(
          candidateId: decision.candidateId,
          kind: decision.kind,
          reason: decision.reason,
          nextEligibleAtMs: existingEligible,
          note: decision.note,
        );
      }

      decisions.add(decision);
      if (decision.isExecute) {
        await _execute(view, decision);
        executed++;
        executedCandidateId ??= view.id;
        // 执行成功后刷新上下文，防止同轮批量超限
        executedTodayTotal++;
        executedTodayByKind[view.actionKind.wire] =
            (executedTodayByKind[view.actionKind.wire] ?? 0) + 1;
        if (view.actionKind != ProactiveActionKind.quiet) {
          lastProactiveAtMs = nowMs;
        }
        recentOutputs.insert(
          0,
          RecentProactiveOutput(
            kind: view.actionKind,
            text: view.contentDraft ?? '',
            atMs: nowMs,
            dedupKey: view.dedupKey,
          ),
        );
      } else if (decision.isDefer) {
        await _repository.deferCandidate(
          view.id,
          nextEligibleAtMs:
              decision.nextEligibleAtMs ??
              nowMs + const Duration(hours: 1).inMilliseconds,
          note: decision.note ?? decision.reason.label,
        );
        deferred++;
      } else {
        await _repository.rejectCandidate(
          view.id,
          note: decision.note ?? decision.reason.label,
        );
        rejected++;
      }
    }

    return ProactiveRunResult(
      decisions: decisions,
      executed: executed,
      deferred: deferred,
      rejected: rejected,
      expired: expiredCount,
      executedCandidateId: executedCandidateId,
    );
  }

  /// 用户手动执行某个候选：仍必须先满足用户硬限制与过期检查（FR-SET-02）
  Future<ProactiveDecision> executeManually(String candidateId) async {
    final nowMs = _clock().millisecondsSinceEpoch;
    final row = await _repository.getCandidate(candidateId);
    if (row == null) {
      return ProactiveDecision(
        candidateId: candidateId,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.expired,
        note: '候选不存在',
      );
    }
    final settings = await _repository.loadSettings();
    final view = _toView(row);
    if (!settings.enabled) {
      return ProactiveDecision(
        candidateId: candidateId,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.hardLimitDisabled,
        note: '主动行为总开关已关闭，手动也不能绕过',
      );
    }
    if (settings.disabledKinds.contains(view.actionKind.wire)) {
      return ProactiveDecision(
        candidateId: candidateId,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.hardLimitKindDisabled,
        note: '${view.actionKind.label}已被你单独关闭',
      );
    }
    if (view.expiresAtMs != null && nowMs >= view.expiresAtMs!) {
      return ProactiveDecision(
        candidateId: candidateId,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.expired,
        note: '候选已过期',
      );
    }
    if (row.status != 'pending') {
      return ProactiveDecision(
        candidateId: candidateId,
        kind: ProactiveDecisionKind.reject,
        reason: ProactiveReason.expired,
        note: '候选当前状态为 ${row.status}，不能执行',
      );
    }
    await _execute(
      view,
      ProactiveDecision(
        candidateId: candidateId,
        kind: ProactiveDecisionKind.execute,
        reason: ProactiveReason.eligible,
        note: '用户手动执行',
      ),
    );
    return ProactiveDecision(
      candidateId: candidateId,
      kind: ProactiveDecisionKind.execute,
      reason: ProactiveReason.eligible,
      note: '用户手动执行',
    );
  }

  Future<void> _execute(
    ProactiveCandidateView view,
    ProactiveDecision decision,
  ) async {
    final row = await _repository.getCandidate(view.id);
    if (row == null) return;
    ProactiveDelivery? delivery;
    try {
      delivery = await _deliverer(row);
    } catch (error) {
      // 投递失败不写执行记录，候选保持 pending 等下一轮重试
      debugPrint('主动投递失败：$error');
      return;
    }
    await _repository.recordExecution(
      candidate: row,
      decisionNote: delivery?.note ?? decision.note ?? decision.reason.label,
      deliverableType: delivery?.deliverableType,
      deliverableId: delivery?.deliverableId,
    );
  }

  ProactiveCandidateView _toView(ProactiveCandidate row) {
    return ProactiveCandidateView(
      id: row.id,
      actionKind: ProactiveActionKind.fromWire(row.actionKind),
      priority: row.priority,
      createdAtMs:
          DateTime.tryParse(row.createdAt)?.millisecondsSinceEpoch ?? 0,
      title: row.title,
      contentDraft: row.contentDraft,
      sourceKind: row.sourceKind,
      dedupKey: row.dedupKey,
      cooldownUntilMs: row.cooldownUntil,
      expiresAtMs: row.expiresAt,
    );
  }
}

extension on ProactiveRunResult {
  /// 空结果但需要带过期数量
  ProactiveRunResult copyWithExpired(int expired) => ProactiveRunResult(
    decisions: const <ProactiveDecision>[],
    executed: 0,
    deferred: 0,
    rejected: 0,
    expired: expired,
  );
}
