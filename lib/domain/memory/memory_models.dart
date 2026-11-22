// 记忆域纯模型（T5.1）：10 类记忆、6 态生命周期、候选草稿、扫描结果与比较决策。
// 依据 MEMORY_DESIGN §2 与 REQUIREMENTS FR-MEM-02~05；本文件不依赖 Flutter/Drift，可纯单测。
library;

/// 记忆分类（FR-MEM-02 的 10 类）
enum MemoryType {
  profile('profile', '用户资料'),
  preference('preference', '用户偏好'),
  experienceJoint('experience_joint', '共同经历'),
  event('event', '重要事件'),
  relationship('relationship', '关系发展'),
  agreement('agreement', '重要约定'),
  opinion('opinion', '观点变化'),
  lesson('lesson', '经验教训'),
  project('project', '项目状态'),
  importantExperience('important_experience', '重要经历');

  const MemoryType(this.wire, this.label);

  /// 落库字符串
  final String wire;

  /// 中文展示名
  final String label;

  static MemoryType? fromWire(String? value) {
    for (final type in MemoryType.values) {
      if (type.wire == value) return type;
    }
    return null;
  }

  static String labelOf(String? wire) => fromWire(wire)?.label ?? (wire ?? '未知');
}

/// 置信度（low 不参与注入）
enum MemoryConfidence {
  low('low', '低', 1),
  medium('medium', '中', 2),
  high('high', '高', 3);

  const MemoryConfidence(this.wire, this.label, this.rank);

  final String wire;
  final String label;
  final int rank;

  static MemoryConfidence fromWire(String? value) {
    for (final c in MemoryConfidence.values) {
      if (c.wire == value) return c;
    }
    return MemoryConfidence.medium;
  }

  static MemoryConfidence min(MemoryConfidence a, MemoryConfidence b) =>
      a.rank <= b.rank ? a : b;
}

/// 生命周期（FR-MEM-03）
enum MemoryStatus {
  pending('pending', '待确认'),
  active('active', '生效中'),
  stale('stale', '已过期'),
  superseded('superseded', '被替代'),
  conflict('conflict', '待裁决'),
  archived('archived', '已归档');

  const MemoryStatus(this.wire, this.label);

  final String wire;
  final String label;

  static MemoryStatus fromWire(String? value) {
    for (final s in MemoryStatus.values) {
      if (s.wire == value) return s;
    }
    return MemoryStatus.active;
  }
}

/// 候选比较结果（FR-MEM-04-04/05/06）
enum CompareKind {
  create('create', '新建'),
  update('update', '补充更新'),
  merge('merge', '合并去重'),
  conflict('conflict', '冲突待裁决');

  const CompareKind(this.wire, this.label);

  final String wire;
  final String label;

  static CompareKind fromWire(String? value) {
    for (final k in CompareKind.values) {
      if (k.wire == value) return k;
    }
    return CompareKind.create;
  }
}

/// 机密扫描命中项
class SecretFinding {
  const SecretFinding({
    required this.kind,
    required this.severity,
    required this.start,
    required this.end,
    required this.excerpt,
  });

  final String kind;

  /// high 拒绝整条 / low 脱敏后保留
  final String severity;
  final int start;
  final int end;
  final String excerpt;

  bool get isHigh => severity == 'high';
}

/// 机密扫描结果（MEMORY_DESIGN §1：11 类模式、重叠合并、≥50% 拒绝）
class SecretScanResult {
  const SecretScanResult({
    required this.findings,
    required this.maskedText,
    required this.rejected,
    required this.coverage,
  });

  final List<SecretFinding> findings;
  final String maskedText;

  /// 是否整条拒绝（high 命中或机密占比 ≥50%）
  final bool rejected;

  /// 命中字符占总字符比例
  final double coverage;

  bool get hasHigh => findings.any((f) => f.isHigh);
  bool get hasLow => findings.any((f) => !f.isHigh);

  /// 用于 UI/日志的摘要
  String get summary {
    if (findings.isEmpty) return '未发现机密';
    final kinds = findings.map((f) => f.kind).toSet().join('、');
    return rejected ? '发现机密（$kinds），已拒绝保存' : '发现敏感串（$kinds），已脱敏';
  }

  static const empty = SecretScanResult(
    findings: <SecretFinding>[],
    maskedText: '',
    rejected: false,
    coverage: 0,
  );
}

/// 敏感类别扫描结果（健康/财务/身份/关系/法律）
class SensitivityScanResult {
  const SensitivityScanResult({required this.categories});

  final List<String> categories;

  bool get flagged => categories.isNotEmpty;

  static const empty = SensitivityScanResult(categories: <String>[]);
}

/// 规则提取出的候选草稿（未落库）
class MemoryDraft {
  const MemoryDraft({
    required this.type,
    required this.title,
    required this.summary,
    required this.confidence,
    required this.importance,
    required this.evidence,
    required this.rawText,
    this.sensitiveCategories = const <String>[],
    this.opinionChange = false,
    this.sharedExperience = false,
  });

  final MemoryType type;
  final String title;
  final String summary;
  final MemoryConfidence confidence;
  final int importance;

  /// 原文定位（grounding 依据）
  final String evidence;
  final String rawText;
  final List<String> sensitiveCategories;

  /// 观点变化：同时产出 opinion_change 思考候选（阶段 7 消费）
  final bool opinionChange;

  /// 共同经历：同时提名 shared_experiences 候选（阶段 9 消费）
  final bool sharedExperience;

  bool get sensitive => sensitiveCategories.isNotEmpty;

  MemoryDraft copyWith({
    MemoryType? type,
    String? title,
    String? summary,
    MemoryConfidence? confidence,
    int? importance,
    String? evidence,
    String? rawText,
    List<String>? sensitiveCategories,
    bool? opinionChange,
    bool? sharedExperience,
  }) {
    return MemoryDraft(
      type: type ?? this.type,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      confidence: confidence ?? this.confidence,
      importance: importance ?? this.importance,
      evidence: evidence ?? this.evidence,
      rawText: rawText ?? this.rawText,
      sensitiveCategories: sensitiveCategories ?? this.sensitiveCategories,
      opinionChange: opinionChange ?? this.opinionChange,
      sharedExperience: sharedExperience ?? this.sharedExperience,
    );
  }
}

/// 参与比较的既有记忆摘要（domain 层不依赖 Drift）
class ExistingMemoryBrief {
  const ExistingMemoryBrief({
    required this.id,
    required this.type,
    required this.summary,
    required this.confidence,
    required this.status,
  });

  final String id;
  final String type;
  final String summary;
  final String confidence;
  final String status;
}

/// 比较决策
class CompareDecision {
  const CompareDecision({
    required this.kind,
    required this.overlap,
    required this.reason,
    this.targetId,
    this.targetSummary,
  });

  final CompareKind kind;
  final double overlap;
  final String reason;
  final String? targetId;
  final String? targetSummary;

  static const create = CompareDecision(
    kind: CompareKind.create,
    overlap: 0,
    reason: '没有足够相似的既有记忆',
  );
}

/// 供注入渲染使用的纯记忆条目
class MemoryRenderItem {
  const MemoryRenderItem({
    required this.id,
    required this.type,
    required this.status,
    required this.title,
    required this.summary,
    required this.confidence,
    required this.importance,
    required this.pinned,
    required this.isResident,
    required this.updatedAt,
  });

  final String id;
  final String type;
  final String status;
  final String title;
  final String summary;
  final String confidence;
  final int importance;
  final bool pinned;
  final bool isResident;

  /// UTC ISO-8601
  final String updatedAt;
}

/// 召回候选（带检索得分）
class MemoryRecallItem {
  const MemoryRecallItem({
    required this.item,
    required this.score,
    required this.matchedTokens,
  });

  final MemoryRenderItem item;
  final double score;
  final List<String> matchedTokens;
}

/// 注入块渲染结果
class MemoryBlock {
  const MemoryBlock({
    required this.text,
    required this.itemIds,
    required this.tokens,
    required this.skipped,
  });

  final String text;
  final List<String> itemIds;
  final int tokens;

  /// 因预算/质量门禁被跳过的条数
  final int skipped;

  bool get isEmpty => text.isEmpty;

  static const empty = MemoryBlock(
    text: '',
    itemIds: <String>[],
    tokens: 0,
    skipped: 0,
  );
}
