// 思考状态机与检查点单测（T7.1）：流转白名单、恢复目标与终态。
import 'package:bubble/domain/thinking/thinking_models.dart';
import 'package:bubble/domain/thinking/thinking_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('八步正常流转全部合法', () {
    const path = [
      ThinkingState.created,
      ThinkingState.loading,
      ThinkingState.reviewing,
      ThinkingState.analyzing,
      ThinkingState.saving,
      ThinkingState.deciding,
      ThinkingState.done,
    ];
    for (var i = 0; i < path.length - 1; i++) {
      expect(ThinkingStateMachine.canTransition(path[i], path[i + 1]), isTrue,
          reason: '${path[i]} → ${path[i + 1]}');
    }
  });

  test('非法跨步流转被拒绝', () {
    expect(
        ThinkingStateMachine.canTransition(
            ThinkingState.loading, ThinkingState.saving),
        isFalse);
    expect(
        ThinkingStateMachine.canTransition(
            ThinkingState.done, ThinkingState.loading),
        isFalse);
    expect(
        ThinkingStateMachine.canTransition(
            ThinkingState.reviewing, ThinkingState.done),
        isFalse);
  });

  test('任一步可失败或中断；失败可重试，中断可续跑', () {
    for (final state in [
      ThinkingState.loading,
      ThinkingState.reviewing,
      ThinkingState.analyzing,
      ThinkingState.saving,
      ThinkingState.deciding,
    ]) {
      expect(ThinkingStateMachine.canTransition(state, ThinkingState.failed),
          isTrue);
      expect(
          ThinkingStateMachine.canTransition(state, ThinkingState.interrupted),
          isTrue);
    }
    expect(
        ThinkingStateMachine.canTransition(
            ThinkingState.failed, ThinkingState.loading),
        isTrue);
    expect(
        ThinkingStateMachine.canTransition(
            ThinkingState.interrupted, ThinkingState.saving),
        isTrue);
  });

  test('检查点决定恢复入口', () {
    ThinkingCheckpoint cp(String step) => ThinkingCheckpoint(step: step);
    expect(ThinkingStateMachine.resumeTarget(cp('loading')),
        ThinkingState.loading);
    expect(ThinkingStateMachine.resumeTarget(cp('reviewing')),
        ThinkingState.reviewing);
    expect(ThinkingStateMachine.resumeTarget(cp('analyzing')),
        ThinkingState.analyzing);
    expect(ThinkingStateMachine.resumeTarget(cp('saving')),
        ThinkingState.saving);
    expect(ThinkingStateMachine.resumeTarget(cp('deciding')),
        ThinkingState.deciding);
    expect(ThinkingStateMachine.resumeTarget(cp('unknown')),
        ThinkingState.loading);
  });

  test('恢复扫描覆盖非终态', () {
    expect(ThinkingStateMachine.resumableStates, contains('interrupted'));
    expect(ThinkingStateMachine.resumableStates, isNot(contains('done')));
    expect(ThinkingStateMachine.resumableStates, isNot(contains('failed')));
  });

  test('检查点 JSON 往返保留洞察与已保存序号', () {
    const insight = ThinkingInsight(
      kind: ThinkingResultKind.newConnection,
      content: '两段记忆有联系',
      relatedMemoryIds: ['m1', 'm2'],
      relatedMessageIds: ['msg1'],
      priority: 60,
      sourceKind: 'memory_relation',
    );
    final checkpoint = ThinkingCheckpoint(
      step: 'saving',
      reviewedUntilMs: 123,
      insights: const [insight],
      savedIndexes: const [0, 2],
      candidateCount: 1,
    );
    final restored = ThinkingCheckpoint.fromJson(checkpoint.toJson());
    expect(restored.step, 'saving');
    expect(restored.reviewedUntilMs, 123);
    expect(restored.insights.length, 1);
    expect(restored.insights.first.kind, ThinkingResultKind.newConnection);
    expect(restored.insights.first.relatedMemoryIds, ['m1', 'm2']);
    expect(restored.savedIndexes, [0, 2]);
    expect(restored.candidateCount, 1);
  });

  test('稳定哈希可复现且不同内容不同', () {
    expect(stableHash('我喜欢西湖'), stableHash('我喜欢西湖'));
    expect(stableHash('我喜欢西湖'), isNot(stableHash('我喜欢跑步')));
  });
}
