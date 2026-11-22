// 记忆引擎（T5.1）：纯函数决策层，不写库（ADR-1）。
// 职责：规则式信号提取（中文正则加权）、噪声过滤、机密扫描与脱敏、
// 敏感类别识别与降级、grounding 校验、候选比较（新建/补充/合并/冲突）。
// 依据 MEMORY_DESIGN §1~§2 与 REQUIREMENTS FR-MEM-04/05/07。
import '../search/tokenizer.dart';
import 'memory_models.dart';

/// 单条信号规则
class _SignalRule {
  const _SignalRule(
    this.pattern,
    this.type,
    this.weight, {
    this.opinionChange = false,
    this.sharedExperience = false,
  });

  final RegExp pattern;
  final MemoryType type;
  final int weight;
  final bool opinionChange;
  final bool sharedExperience;
}

/// 单条机密模式
class _SecretPattern {
  const _SecretPattern(this.kind, this.pattern, this.severity);

  final String kind;
  final RegExp pattern;
  final String severity;
}

class MemoryEngine {
  const MemoryEngine();

  /// 合并阈值：重叠系数 ≥0.82 视为同一条（TEST_PLAN §2 边界 0.81/0.82/0.83）
  static const double mergeThreshold = 0.82;

  /// 补充阈值：≥0.55 视为同主题补充
  static const double updateThreshold = 0.55;

  /// 自动保存门禁：仅 high 置信度、create/update、无敏感标记
  static bool canAutoActivate(
    MemoryDraft draft,
    CompareDecision decision,
  ) {
    return draft.confidence == MemoryConfidence.high &&
        !draft.sensitive &&
        (decision.kind == CompareKind.create ||
            decision.kind == CompareKind.update);
  }

  // ------------------------------------------------------------ 提取

  /// 从用户原话提取记忆草稿；无信号/噪声返回 null。
  /// 助手回复只做 grounding 参考，不单独产生关于用户的记忆。
  MemoryDraft? extract(String userText, {String assistantText = ''}) {
    final text = userText.trim();
    if (text.isEmpty || isNoise(text)) return null;

    _SignalRule? best;
    RegExpMatch? match;
    for (final rule in _signalRules) {
      final m = rule.pattern.firstMatch(text);
      if (m == null) continue;
      if (best == null || rule.weight > best.weight) {
        best = rule;
        match = m;
      }
    }
    if (best == null || match == null) return null;

    final evidence = _sentenceAt(text, match.start);
    final title = _buildTitle(evidence, best.type);
    final summary = _buildSummary(text);
    var confidence = _confidenceOf(best.weight);
    final sensitive = scanSensitivity(text);

    var draft = MemoryDraft(
      type: best.type,
      title: title,
      summary: summary,
      confidence: confidence,
      importance: best.weight.clamp(0, 95),
      evidence: evidence,
      rawText: text,
      sensitiveCategories: sensitive.categories,
      opinionChange: best.opinionChange ||
          RegExp(r'(以前|之前).{0,12}(现在|如今).{0,12}(觉得|认为|发现)')
              .hasMatch(text),
      sharedExperience: best.sharedExperience,
    );

    // grounding：原文定位不到 → 降 low；仅助手回复佐证 → 最多 medium
    confidence = MemoryConfidence.min(
      confidence,
      groundConfidence(draft, assistantText: assistantText),
    );
    // 敏感信息默认不自动保存：置信度压到 medium 及以下（只能进待确认）
    if (sensitive.flagged && confidence.rank > MemoryConfidence.medium.rank) {
      confidence = MemoryConfidence.medium;
    }
    draft = draft.copyWith(confidence: confidence);
    return draft;
  }

  /// 噪声过滤：寒暄、纯表情、单字回应等不成为记忆。
  bool isNoise(String text) {
    final core = _coreText(text);
    if (core.length < 2) return true;
    const greetings = <String>[
      '嗯', '嗯嗯', '哦', '哦哦', '啊', '哈', '哈哈', '哈哈哈', '呵', '呵呵',
      '好的', '好', '行', '可以', '继续', '在吗', '在', '早', '早上好',
      '晚安', '谢谢', '谢啦', '拜拜', '再见', 'ok', 'okay', '收到', '知道了',
    ];
    return greetings.contains(core);
  }

  /// grounding 校验：草稿主张必须能在用户原话中找到定位。
  MemoryConfidence groundConfidence(
    MemoryDraft draft, {
    String assistantText = '',
  }) {
    final userTokens = similarityTokens(draft.rawText);
    final summaryTokens = similarityTokens('${draft.title} ${draft.summary}');
    if (summaryTokens.isEmpty) return MemoryConfidence.low;
    final hit = summaryTokens.where(userTokens.contains).length;
    if (hit >= 2) return draft.confidence;
    if (hit == 1) {
      return MemoryConfidence.min(draft.confidence, MemoryConfidence.medium);
    }
    // 原文完全定位不到：只有助手回复里有迹可循时最多 medium，否则 low
    final assistantTokens = similarityTokens(assistantText);
    if (assistantTokens.isNotEmpty &&
        summaryTokens.where(assistantTokens.contains).isNotEmpty) {
      return MemoryConfidence.medium;
    }
    return MemoryConfidence.low;
  }

  // ------------------------------------------------------------ 机密与敏感扫描

  /// 机密扫描：11 类模式、重叠 span 合并、high 拒绝整条、low 脱敏、≥50% 拒绝。
  SecretScanResult scanSecrets(String text) {
    if (text.isEmpty) return SecretScanResult.empty;
    final raw = <SecretFinding>[];
    for (final pattern in _secretPatterns) {
      for (final match in pattern.pattern.allMatches(text)) {
        if (match.end <= match.start) continue;
        final excerpt = match.group(0) ?? '';
        raw.add(SecretFinding(
          kind: pattern.kind,
          severity: pattern.severity,
          start: match.start,
          end: match.end,
          excerpt: excerpt,
        ));
      }
    }
    if (raw.isEmpty) {
      return SecretScanResult(
        findings: const <SecretFinding>[],
        maskedText: text,
        rejected: false,
        coverage: 0,
      );
    }

    raw.sort((a, b) => a.start.compareTo(b.start));
    final merged = <SecretFinding>[];
    for (final finding in raw) {
      if (merged.isEmpty) {
        merged.add(finding);
        continue;
      }
      final last = merged.last;
      if (finding.start <= last.end) {
        final end = finding.end > last.end ? finding.end : last.end;
        final severity =
            (last.isHigh || finding.isHigh) ? 'high' : 'low';
        merged[merged.length - 1] = SecretFinding(
          kind: last.kind == finding.kind ? last.kind : '${last.kind}/${finding.kind}',
          severity: severity,
          start: last.start,
          end: end,
          excerpt: text.substring(last.start, end),
        );
      } else {
        merged.add(finding);
      }
    }

    var covered = 0;
    final buffer = StringBuffer();
    var cursor = 0;
    for (final finding in merged) {
      if (finding.start > cursor) {
        buffer.write(text.substring(cursor, finding.start));
      }
      buffer.write('〔已脱敏〕');
      covered += finding.end - finding.start;
      cursor = finding.end;
    }
    if (cursor < text.length) buffer.write(text.substring(cursor));

    final coverage = text.length == 0 ? 0.0 : covered / text.length;
    final hasHigh = merged.any((f) => f.isHigh);
    return SecretScanResult(
      findings: merged,
      maskedText: buffer.toString(),
      rejected: hasHigh || coverage >= 0.5,
      coverage: coverage,
    );
  }

  /// 敏感类别扫描：命中即只能进待确认（FR-MEM-05）。
  SensitivityScanResult scanSensitivity(String text) {
    if (text.isEmpty) return SensitivityScanResult.empty;
    final categories = <String>[];
    for (final entry in _sensitivePatterns.entries) {
      if (entry.value.hasMatch(text)) categories.add(entry.key);
    }
    return SensitivityScanResult(categories: categories);
  }

  // ------------------------------------------------------------ 候选比较

  /// 与既有记忆比较，决定新建/补充/合并/冲突。
  CompareDecision compare(
    MemoryDraft draft,
    List<ExistingMemoryBrief> existing,
  ) {
    final draftTokens = similarityTokens('${draft.title} ${draft.summary}');
    ExistingMemoryBrief? best;
    var bestOverlap = 0.0;
    for (final item in existing) {
      if (item.type != draft.type.wire) continue;
      if (item.status != 'active' && item.status != 'conflict') continue;
      final overlap = overlapCoefficient(
        draftTokens,
        similarityTokens(item.summary),
      );
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        best = item;
      }
    }
    if (best == null || bestOverlap < updateThreshold) {
      return CompareDecision(
        kind: CompareKind.create,
        overlap: bestOverlap,
        reason: '没有足够相似的既有记忆',
      );
    }
    if (bestOverlap >= mergeThreshold) {
      if (_contradicts(draft.summary, best.summary)) {
        return CompareDecision(
          kind: CompareKind.conflict,
          overlap: bestOverlap,
          targetId: best.id,
          targetSummary: best.summary,
          reason: '与既有记忆语义矛盾，保留双方证据待裁决',
        );
      }
      return CompareDecision(
        kind: CompareKind.merge,
        overlap: bestOverlap,
        targetId: best.id,
        targetSummary: best.summary,
        reason: '重叠系数 ${bestOverlap.toStringAsFixed(2)} ≥ 0.82，合并去重',
      );
    }
    return CompareDecision(
      kind: CompareKind.update,
      overlap: bestOverlap,
      targetId: best.id,
      targetSummary: best.summary,
      reason: '同主题补充信息，更新既有记忆',
    );
  }

  /// 语义矛盾判定：数值不同 / 否定极性相反 / 反义对 / 明确替代说法。
  bool _contradicts(String a, String b) {
    final numbersA = _numbers(a);
    final numbersB = _numbers(b);
    if (numbersA.isNotEmpty &&
        numbersB.isNotEmpty &&
        !_sameNumbers(numbersA, numbersB)) {
      return true;
    }
    if (_hasNegation(a) != _hasNegation(b)) return true;
    for (final pair in _antonymPairs) {
      final aHead = pair[0];
      final bHead = pair[1];
      if ((a.contains(aHead) && b.contains(bHead)) ||
          (a.contains(bHead) && b.contains(aHead))) {
        return true;
      }
    }
    return RegExp(r'(不再是|改成|变成了|现在不|已经分手|已经离职|换了工作)')
        .hasMatch(a);
  }

  Set<String> _numbers(String text) =>
      RegExp(r'\b\d+\b|[零一二三四五六七八九十百千万亿两]+')
          .allMatches(text)
          .map((m) => m.group(0)!)
          .toSet();

  bool _sameNumbers(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  bool _hasNegation(String text) =>
      RegExp(r'(不喜欢|不想要|不再|没有|没在|不想|别|从不|从不|讨厌)').hasMatch(text);

  // ------------------------------------------------------------ 内部规则

  static final List<_SignalRule> _signalRules = <_SignalRule>[
    // 显式记忆指令（最高优先级）
    _SignalRule(RegExp(r'(记住|请记住|帮我记住|你要记得|记一下)'), MemoryType.preference, 100),
    // 偏好
    _SignalRule(RegExp(r'(我喜欢|我爱吃|我最爱|我讨厌|我不喜欢|我受不了|我习惯|以后都|不要再)'),
        MemoryType.preference, 95),
    // 约定
    _SignalRule(RegExp(r'(说好了|约好|答应你|下次一起|一言为定|周末一起|生日那天|我们约定)'),
        MemoryType.agreement, 92),
    // 用户资料
    _SignalRule(RegExp(r'(我是|我叫|我的名字|我在做|我的职业|我今年|我在.*工作)'),
        MemoryType.profile, 90),
    _SignalRule(RegExp(r'(我住在|我来自|我家在|我老家)'), MemoryType.profile, 88),
    // 关系发展
    _SignalRule(RegExp(r'(我们的关系|你在我心里|越来越|第一次遇见|后来我们)'),
        MemoryType.relationship, 85),
    // 重要经历
    _SignalRule(RegExp(r'(对我很重要|一辈子忘不了|人生中第一次|最重要的一天)'),
        MemoryType.importantExperience, 85),
    // 共同经历
    _SignalRule(RegExp(r'(我们一起|一起去过|一起做|那天我们|上次我们)'),
        MemoryType.experienceJoint, 80, sharedExperience: true),
    // 观点
    _SignalRule(RegExp(r'(我觉得|我认为|我的看法|我感觉)'), MemoryType.opinion, 80),
    _SignalRule(
      RegExp(r'(以前|之前).{0,12}(现在|如今).{0,12}(觉得|认为|发现)'),
      MemoryType.opinion,
      88,
      opinionChange: true,
    ),
    // 事件
    _SignalRule(RegExp(r'(今天发生|刚刚|刚考完|搬家了|毕业了|升职|换工作|分手了|生病了|住院了)'),
        MemoryType.event, 75),
    // 教训
    _SignalRule(RegExp(r'(教训|踩坑|学到了|下次不要|长记性)'), MemoryType.lesson, 78),
    // 项目状态
    _SignalRule(RegExp(r'(项目|在做的|卡在|进度|上线|开发中)'), MemoryType.project, 65),
  ];

  static final List<_SecretPattern> _secretPatterns = <_SecretPattern>[
    _SecretPattern(
      '私钥',
      RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----'),
      'high',
    ),
    _SecretPattern(
      '密码',
      RegExp(r'(?:密码|口令|passwd|password|pwd)\s*(?:是|为|：|:|＝|=)\s*\S{3,}',
          caseSensitive: false),
      'high',
    ),
    _SecretPattern(
      'API Key',
      RegExp(
          r'(?:api[_-]?key|apikey|secret[_-]?key|access[_-]?key)\s*(?:是|为|：|:|＝|=)\s*[A-Za-z0-9_\-]{8,}',
          caseSensitive: false),
      'high',
    ),
    _SecretPattern(
      '访问令牌',
      RegExp(
          r'(?:access[_-]?token|refresh[_-]?token|bearer\s+|token|令牌)\s*(?:是|为|：|:|＝|=)?\s*[A-Za-z0-9_\-.]{8,}',
          caseSensitive: false),
      'high',
    ),
    _SecretPattern(
      '密钥',
      RegExp(r'(?:密钥|秘钥|secret)\s*(?:是|为|：|:|＝|=)\s*\S{3,}',
          caseSensitive: false),
      'high',
    ),
    _SecretPattern(
      'API Key 前缀',
      RegExp(r'sk-[A-Za-z0-9]{12,}'),
      'high',
    ),
    _SecretPattern(
      '带凭据链接',
      RegExp(r'https?://[^\s:@/]+:[^\s@/]+@'),
      'high',
    ),
    _SecretPattern('银行卡号', RegExp(r'\b\d{16,19}\b'), 'high'),
    _SecretPattern('身份证号', RegExp(r'\b\d{17}[\dXx]\b'), 'high'),
    _SecretPattern('手机号', RegExp(r'\b1[3-9]\d{9}\b'), 'low'),
    _SecretPattern(
      '邮箱',
      RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'),
      'low',
    ),
  ];

  static final Map<String, RegExp> _sensitivePatterns = <String, RegExp>{
    '健康': RegExp(r'(健康|生病|住院|手术|抑郁|焦虑症|体检|吃药|医院|癌症|发烧|失眠)'),
    '财务': RegExp(r'(工资|收入|存款|负债|欠债|房贷|车贷|信用卡|花呗|借呗|投资|股票|亏了|赚了)'),
    '身份': RegExp(r'(身份证|护照|住址|家庭住址|真名|户籍|社保号|银行卡号)'),
    '关系': RegExp(r'(前任|男朋友|女朋友|结婚|离婚|分手|暗恋|相亲|恋爱|恋人)'),
    '法律': RegExp(r'(官司|起诉|律师|违法|犯罪|合同纠纷|仲裁|判决)'),
  };

  static final List<List<String>> _antonymPairs = <List<String>>[
    ['喜欢', '讨厌'],
    ['喜欢吃', '不喜欢吃'],
    ['素食', '吃肉'],
    ['早起', '熬夜'],
    ['单身', '恋爱'],
    ['在一起', '分开'],
    ['吃素', '吃肉'],
  ];

  MemoryConfidence _confidenceOf(int weight) {
    if (weight >= 90) return MemoryConfidence.high;
    if (weight >= 75) return MemoryConfidence.medium;
    return MemoryConfidence.low;
  }

  /// 仅保留中文、拉丁字母、数字，用于噪声判定
  String _coreText(String text) {
    final buffer = StringBuffer();
    for (final rune in text.runes) {
      final isCjk = (rune >= 0x4E00 && rune <= 0x9FFF) ||
          (rune >= 0x3400 && rune <= 0x4DBF);
      final isLatin = (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A);
      final isDigit = rune >= 0x30 && rune <= 0x39;
      if (isCjk || isLatin || isDigit) buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  String _sentenceAt(String text, int index) {
    const delimiters = {'。', '！', '？', '!', '?', '；', ';', '\n'};
    var start = index;
    while (start > 0 && !delimiters.contains(text[start - 1])) {
      start--;
    }
    var end = index;
    while (end < text.length && !delimiters.contains(text[end])) {
      end++;
    }
    final sentence = text.substring(start, end).trim();
    return sentence.isEmpty ? text.trim() : sentence;
  }

  String _buildTitle(String evidence, MemoryType type) {
    var title = evidence.trim();
    title = title.replaceFirst(
      RegExp(r'^(记住|请记住|帮我记住|你要记得|记一下)\s*[:：,，]?\s*'),
      '',
    );
    title = title.replaceAll(RegExp(r'[。！？!?；;]+$'), '');
    if (title.length > 40) title = title.substring(0, 40);
    return title.isEmpty ? type.label : title;
  }

  String _buildSummary(String text) {
    var summary = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    summary = summary.replaceFirst(
      RegExp(r'^(记住|请记住|帮我记住|你要记得|记一下)\s*[:：,，]?\s*'),
      '',
    );
    if (summary.length > 200) summary = summary.substring(0, 200);
    return summary;
  }
}
