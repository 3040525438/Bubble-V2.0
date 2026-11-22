// 反馈纯模型（T14.2）：六类反馈目标 × 四种态度，支持撤销与历史。
// 依据 DATABASE_DESIGN §2.21、REQUIREMENTS FR-FBK-01/02；
// 单次反馈不直接永久修改核心人格（FR-FBK-02），只记录并可撤销。
library;

/// 反馈目标类型（六类，对应 FR-FBK-01）。
enum FeedbackTargetKind {
  expressionStyle('expression_style', '表达风格'),
  proactiveFrequency('proactive_frequency', '主动频率'),
  post('post', '说说内容'),
  memoryCorrection('memory_correction', '记忆纠错'),
  personaSuggestion('persona_suggestion', '人格建议'),
  proactiveAction('proactive_action', '主动行为');

  const FeedbackTargetKind(this.wire, this.label);

  final String wire;
  final String label;

  static FeedbackTargetKind? fromWire(String? value) {
    for (final k in FeedbackTargetKind.values) {
      if (k.wire == value) return k;
    }
    return null;
  }
}

/// 反馈态度（四态）。
enum FeedbackVerdict {
  like('like', '喜欢', '赞'),
  dislike('dislike', '不喜欢', '踩'),
  adjust('adjust', '想调整', '调整'),
  correct('correct', '需要纠正', '纠正');

  const FeedbackVerdict(this.wire, this.label, this.actionLabel);

  final String wire;
  final String label;
  final String actionLabel;

  static FeedbackVerdict? fromWire(String? value) {
    for (final v in FeedbackVerdict.values) {
      if (v.wire == value) return v;
    }
    return null;
  }
}

/// 单条反馈视图（与 feedback_records 行一一对应）。
class FeedbackEntry {
  const FeedbackEntry({
    required this.id,
    required this.targetKind,
    required this.targetId,
    required this.verdict,
    required this.createdAt,
    this.note,
    this.actionTaken,
    this.revertedAt,
  });

  final String id;
  final FeedbackTargetKind targetKind;
  final String targetId;
  final FeedbackVerdict verdict;

  /// UTC ISO-8601
  final String createdAt;
  final String? note;

  /// 实际调整动作（仅成长层记录 JSON）
  final String? actionTaken;

  /// 撤销时间；非空表示已撤销
  final String? revertedAt;

  bool get isReverted => revertedAt != null;

  DateTime? get createdAtTime => DateTime.tryParse(createdAt)?.toLocal();

  DateTime? get revertedAtTime =>
      revertedAt == null ? null : DateTime.tryParse(revertedAt!)?.toLocal();
}

/// 反馈统计（数据中心/反馈历史页摘要）。
class FeedbackSummary {
  const FeedbackSummary({
    required this.total,
    required this.active,
    required this.reverted,
    required this.byKind,
  });

  final int total;
  final int active;
  final int reverted;
  final Map<FeedbackTargetKind, int> byKind;

  static FeedbackSummary empty() =>
      const FeedbackSummary(total: 0, active: 0, reverted: 0, byKind: {});
}

/// 校验反馈输入（UI 与仓储共用同一规则）。
String? validateFeedback({
  required FeedbackTargetKind kind,
  required String targetId,
  required FeedbackVerdict verdict,
  String? note,
}) {
  if (targetId.trim().isEmpty) return '反馈对象不能为空';
  final trimmedNote = note?.trim() ?? '';
  if (trimmedNote.length > 500) return '反馈备注不超过 500 字';
  if (verdict == FeedbackVerdict.correct && trimmedNote.isEmpty) {
    return '请填写需要纠正的内容';
  }
  return null;
}
