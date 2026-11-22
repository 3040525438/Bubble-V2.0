// 思考状态机（T7.1）：八步流转白名单 + 中断恢复目标判定。
// 依据 AUTONOMOUS_SYSTEM §1.1 与 DATABASE_DESIGN §2.12 的 state 约束。
import 'thinking_models.dart';

class ThinkingStateMachine {
  const ThinkingStateMachine._();

  /// 正常流转（含失败与中断兜底）
  static const Map<ThinkingState, Set<ThinkingState>> transitions = {
    ThinkingState.created: {ThinkingState.loading, ThinkingState.interrupted},
    ThinkingState.loading: {
      ThinkingState.reviewing,
      ThinkingState.failed,
      ThinkingState.interrupted,
    },
    ThinkingState.reviewing: {
      ThinkingState.analyzing,
      ThinkingState.failed,
      ThinkingState.interrupted,
    },
    ThinkingState.analyzing: {
      ThinkingState.saving,
      ThinkingState.failed,
      ThinkingState.interrupted,
    },
    ThinkingState.saving: {
      ThinkingState.deciding,
      ThinkingState.failed,
      ThinkingState.interrupted,
    },
    ThinkingState.deciding: {
      ThinkingState.done,
      ThinkingState.failed,
      ThinkingState.interrupted,
    },
    ThinkingState.done: <ThinkingState>{},
    ThinkingState.failed: {ThinkingState.loading},
    ThinkingState.interrupted: {
      ThinkingState.loading,
      ThinkingState.reviewing,
      ThinkingState.analyzing,
      ThinkingState.saving,
      ThinkingState.deciding,
      ThinkingState.failed,
    },
  };

  static bool canTransition(ThinkingState from, ThinkingState to) =>
      transitions[from]?.contains(to) ?? false;

  /// 中断恢复的续跑入口：按检查点落到对应步骤。
  static ThinkingState resumeTarget(ThinkingCheckpoint checkpoint) {
    switch (checkpoint.step) {
      case 'loading':
        return ThinkingState.loading;
      case 'reviewing':
        return ThinkingState.reviewing;
      case 'analyzing':
        return ThinkingState.analyzing;
      case 'saving':
        return ThinkingState.saving;
      case 'deciding':
        return ThinkingState.deciding;
      default:
        return ThinkingState.loading;
    }
  }

  /// 需要恢复扫描的非终态集合（FR-IOS-07）
  static const Set<String> resumableStates = {
    'created',
    'loading',
    'reviewing',
    'analyzing',
    'saving',
    'deciding',
    'interrupted',
  };
}
