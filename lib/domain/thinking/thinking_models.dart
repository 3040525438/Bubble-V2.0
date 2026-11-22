// 思考域纯模型（T7.1）：任务八步状态、回顾输入、洞察与检查点。
// 依据 AUTONOMOUS_SYSTEM §1、DATABASE_DESIGN §2.12~§2.13、TEST_PLAN §4。
library;

/// 思考任务状态（与 thinking_tasks.state 约束一致）
enum ThinkingState {
  created('created', '已创建'),
  loading('loading', '加载进度'),
  reviewing('reviewing', '回顾历史'),
  analyzing('analyzing', '分析关联'),
  saving('saving', '保存发现'),
  deciding('deciding', '形成候选'),
  done('done', '已完成'),
  failed('failed', '失败'),
  interrupted('interrupted', '已中断');

  const ThinkingState(this.wire, this.label);

  final String wire;
  final String label;

  static ThinkingState fromWire(String? value) {
    for (final state in ThinkingState.values) {
      if (state.wire == value) return state;
    }
    return ThinkingState.created;
  }

  bool get isTerminal => this == done || this == failed;
}

/// 触发源
enum ThinkingTrigger {
  foregroundTimer('foreground_timer', '前台定时'),
  backgroundBgTask('background_bgtask', '后台任务'),
  appResume('app_resume', '回到前台'),
  manual('manual', '手动触发');

  const ThinkingTrigger(this.wire, this.label);

  final String wire;
  final String label;
}

/// 想法类型（FR-ATH-02 十项能力的六种落点）
enum ThinkingResultKind {
  newConnection('new_connection', '新联系'),
  reunderstanding('reunderstanding', '重新理解'),
  topicWorthContinuing('topic_worth_continuing', '值得继续的话题'),
  shareWorthy('share_worthy', '值得分享'),
  diaryMaterial('diary_material', '日记素材'),
  quiet('quiet', '保持安静');

  const ThinkingResultKind(this.wire, this.label);

  final String wire;
  final String label;

  static ThinkingResultKind fromWire(String? value) {
    for (final kind in ThinkingResultKind.values) {
      if (kind.wire == value) return kind;
    }
    return ThinkingResultKind.newConnection;
  }

  bool get isQuiet => this == quiet;
}

/// 主动候选的行为类型（阶段 8 决策中心统一消费，与 proactive_candidates.action_kind 一致）
enum ProactiveActionKind {
  chat('chat', '聊天'),
  post('post', '说说'),
  diary('diary', '日记'),
  letter('letter', '信件'),
  reviewExperience('review_experience', '回顾经历'),
  memoryHousekeeping('memory_housekeeping', '整理记忆'),
  quiet('quiet', '安静');

  const ProactiveActionKind(this.wire, this.label);

  final String wire;
  final String label;

  static ProactiveActionKind fromWire(String? value) {
    for (final kind in ProactiveActionKind.values) {
      if (kind.wire == value) return kind;
    }
    return ProactiveActionKind.chat;
  }
}

/// 回顾用消息摘要
class ReviewMessage {
  const ReviewMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAtMs,
  });

  final String id;
  final String conversationId;
  final String role;
  final String content;
  final int createdAtMs;
}

/// 回顾用记忆摘要
class MemoryBrief {
  const MemoryBrief({
    required this.id,
    required this.type,
    required this.title,
    required this.summary,
    required this.updatedAtMs,
  });

  final String id;
  final String type;
  final String title;
  final String summary;
  final int updatedAtMs;

  String get display => title.trim().isEmpty ? summary : title;
}

/// 八步流程的回顾输入（② 回顾数据）
class ThinkingReviewInput {
  const ThinkingReviewInput({
    required this.newMessages,
    required this.sampledMessages,
    required this.memories,
    required this.agreements,
    required this.pastThoughts,
    required this.personaPrompt,
    required this.reviewedUntilMs,
    this.scopeNote = '',
  });

  final List<ReviewMessage> newMessages;
  final List<ReviewMessage> sampledMessages;
  final List<MemoryBrief> memories;
  final List<MemoryBrief> agreements;
  final List<String> pastThoughts;
  final String personaPrompt;
  final int reviewedUntilMs;
  final String scopeNote;

  List<ReviewMessage> get allMessages => [...newMessages, ...sampledMessages];
}

/// 分析洞察（③④ 的产出，⑤⑥ 的输入）
class ThinkingInsight {
  const ThinkingInsight({
    required this.kind,
    required this.content,
    this.confidence = 'medium',
    this.relatedMemoryIds = const <String>[],
    this.relatedMessageIds = const <String>[],
    this.actionKind = ProactiveActionKind.chat,
    this.priority = 50,
    this.sourceKind = 'thinking',
    this.title,
    this.dedupKey,
  });

  final ThinkingResultKind kind;
  final String content;
  final String confidence;
  final List<String> relatedMemoryIds;
  final List<String> relatedMessageIds;
  final ProactiveActionKind actionKind;
  final int priority;
  final String sourceKind;
  final String? title;
  final String? dedupKey;

  /// 去重键：类型 + 内容稳定哈希
  String get effectiveDedupKey =>
      dedupKey ?? '${kind.wire}:${stableHash(content)}';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.wire,
        'content': content,
        'confidence': confidence,
        'memoryIds': relatedMemoryIds,
        'messageIds': relatedMessageIds,
        'action': actionKind.wire,
        'priority': priority,
        'source': sourceKind,
        'title': title,
        'dedupKey': dedupKey,
      };

  static ThinkingInsight? fromJson(Map<String, dynamic> json) {
    final content = (json['content'] as String? ?? '').trim();
    if (content.isEmpty) return null;
    return ThinkingInsight(
      kind: ThinkingResultKind.fromWire(json['kind'] as String?),
      content: content,
      confidence: json['confidence'] as String? ?? 'medium',
      relatedMemoryIds:
          (json['memoryIds'] as List?)?.cast<String>() ?? const <String>[],
      relatedMessageIds:
          (json['messageIds'] as List?)?.cast<String>() ?? const <String>[],
      actionKind: ProactiveActionKind.fromWire(json['action'] as String?),
      priority: json['priority'] as int? ?? 50,
      sourceKind: json['source'] as String? ?? 'thinking',
      title: json['title'] as String?,
      dedupKey: json['dedupKey'] as String?,
    );
  }
}

/// 检查点（每步落库，中断恢复的原子单位）
class ThinkingCheckpoint {
  const ThinkingCheckpoint({
    required this.step,
    this.reviewedUntilMs,
    this.sampleCursor = 0,
    this.insights = const <ThinkingInsight>[],
    this.savedIndexes = const <int>[],
    this.candidateCount = 0,
    this.error,
  });

  final String step;
  final int? reviewedUntilMs;
  final int sampleCursor;
  final List<ThinkingInsight> insights;
  final List<int> savedIndexes;
  final int candidateCount;
  final String? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'step': step,
        'reviewedUntilMs': reviewedUntilMs,
        'sampleCursor': sampleCursor,
        'insights': insights.map((i) => i.toJson()).toList(),
        'savedIndexes': savedIndexes,
        'candidateCount': candidateCount,
        'error': error,
      };

  static ThinkingCheckpoint fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) {
      return const ThinkingCheckpoint(step: 'created');
    }
    return ThinkingCheckpoint(
      step: json['step'] as String? ?? 'created',
      reviewedUntilMs: json['reviewedUntilMs'] as int?,
      sampleCursor: json['sampleCursor'] as int? ?? 0,
      insights: (json['insights'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(ThinkingInsight.fromJson)
              .whereType<ThinkingInsight>()
              .toList() ??
          const <ThinkingInsight>[],
      savedIndexes:
          (json['savedIndexes'] as List?)?.cast<int>() ?? const <int>[],
      candidateCount: json['candidateCount'] as int? ?? 0,
      error: json['error'] as String?,
    );
  }
}

/// 单次运行结果
class ThinkingRunResult {
  const ThinkingRunResult({
    required this.taskId,
    required this.state,
    required this.insightCount,
    required this.candidateCount,
    this.error,
  });

  final String taskId;
  final ThinkingState state;
  final int insightCount;
  final int candidateCount;
  final String? error;
}

/// 稳定哈希（FNV-1a 32 位），用于去重键，跨运行稳定。
String stableHash(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
