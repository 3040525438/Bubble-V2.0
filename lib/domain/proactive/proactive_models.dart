// 主动行为决策领域模型（T8.1/T8.2）。
// 依据 AUTONOMOUS_SYSTEM §2、REQUIREMENTS FR-DEC-01~03 / FR-PRO / FR-SET / FR-FBK。
// 决策中心是唯一执行入口：其他模块只能写入 proactive_candidates，不能自行调度。
import '../thinking/thinking_models.dart';

export '../thinking/thinking_models.dart' show ProactiveActionKind;

/// 主动程度三档（UI_PAGE_SPEC §22：保守 / 均衡 / 积极，默认积极 = D-4）
enum ProactivityLevel {
  conservative('conservative', '保守', 120, 2, '每天最多打扰 2 次，间隔至少 2 小时'),
  balanced('balanced', '均衡', 90, 4, '每天最多 4 次，间隔至少 90 分钟'),
  active('active', '积极', 60, 6, '每天最多 6 次，间隔至少 60 分钟');

  const ProactivityLevel(
    this.wire,
    this.label,
    this.defaultMinIntervalMinutes,
    this.defaultDailyCap,
    this.description,
  );

  final String wire;
  final String label;
  final int defaultMinIntervalMinutes;
  final int defaultDailyCap;
  final String description;

  static ProactivityLevel fromWire(String? value) {
    for (final level in ProactivityLevel.values) {
      if (level.wire == value) return level;
    }
    return ProactivityLevel.active;
  }
}

/// 候选快照（决策层不依赖数据库行，便于纯函数测试）
class ProactiveCandidateView {
  const ProactiveCandidateView({
    required this.id,
    required this.actionKind,
    required this.priority,
    required this.createdAtMs,
    this.title,
    this.contentDraft,
    this.sourceKind,
    this.dedupKey,
    this.cooldownUntilMs,
    this.expiresAtMs,
  });

  final String id;
  final ProactiveActionKind actionKind;
  final int priority; // 0-100，越大越先
  final int createdAtMs;
  final String? title;
  final String? contentDraft;
  final String? sourceKind;
  final String? dedupKey;
  final int? cooldownUntilMs; // 顺延到的可执行时间
  final int? expiresAtMs;

  String get displayTitle {
    final value = (title ?? '').trim();
    if (value.isNotEmpty) return value;
    final draft = (contentDraft ?? '').trim();
    if (draft.isEmpty) return actionKind.label;
    return draft.length <= 18 ? draft : '${draft.substring(0, 18)}…';
  }
}

/// 近期已输出/已执行的记录，用于重复检测（FR-DEC-02）
class RecentProactiveOutput {
  const RecentProactiveOutput({
    required this.kind,
    required this.text,
    required this.atMs,
    this.dedupKey,
  });

  final ProactiveActionKind kind;
  final String text;
  final int atMs;
  final String? dedupKey;
}

/// 反馈累计调整（FR-FBK-01：只调整优先级与冷却，不改核心人格）
class ProactiveAdjustment {
  const ProactiveAdjustment({
    this.priorityDelta = 0,
    this.cooldownMultiplier = 1.0,
  });

  final int priorityDelta;
  final double cooldownMultiplier;

  ProactiveAdjustment merge({
    int priorityDelta = 0,
    double cooldownMultiplier = 1.0,
  }) {
    return ProactiveAdjustment(
      priorityDelta: (this.priorityDelta + priorityDelta).clamp(-50, 50),
      cooldownMultiplier: (this.cooldownMultiplier * cooldownMultiplier).clamp(
        1.0,
        3.0,
      ),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'priorityDelta': priorityDelta,
    'cooldownMultiplier': cooldownMultiplier,
  };

  static ProactiveAdjustment fromJson(Map<String, dynamic> json) {
    return ProactiveAdjustment(
      priorityDelta: (json['priorityDelta'] as num?)?.toInt() ?? 0,
      cooldownMultiplier:
          (json['cooldownMultiplier'] as num?)?.toDouble() ?? 1.0,
    );
  }
}

/// 主动行为设置（app_settings 持久化；全部参数集中在此，硬限制不可被候选绕过）
class ProactiveSettings {
  const ProactiveSettings({
    this.level = ProactivityLevel.active,
    this.enabled = true,
    this.quietStart = '23:00',
    this.quietEnd = '08:00',
    this.dailyCap,
    this.minIntervalMinutes,
    this.cooldowns = const <String, int>{},
    this.disabledKinds = const <String>{},
    this.dedupWindowDays = 14,
    this.contentSimilarityThreshold = 0.62,
    this.adjustments = const <String, ProactiveAdjustment>{},
  });

  final ProactivityLevel level;

  /// 硬限制：总开关关闭后任何候选都不得执行（FR-SET-02）
  final bool enabled;
  final String quietStart; // HH:mm，跨午夜允许
  final String quietEnd;
  final int? dailyCap; // 空 → 取档位默认
  final int? minIntervalMinutes; // 空 → 取档位默认
  final Map<String, int> cooldowns; // kind.wire → 分钟，空 → 默认值
  final Set<String> disabledKinds; // 用户单独关闭的类别（硬限制）
  final int dedupWindowDays;
  final double contentSimilarityThreshold;
  final Map<String, ProactiveAdjustment> adjustments; // 反馈累计

  int get effectiveDailyCap => dailyCap ?? level.defaultDailyCap;

  int get effectiveMinIntervalMinutes =>
      minIntervalMinutes ?? level.defaultMinIntervalMinutes;

  /// 默认同类冷却（分钟）：信件最长，符合 AUTONOMOUS_SYSTEM §4
  static const defaultCooldowns = <String, int>{
    'chat': 90,
    'post': 240,
    'diary': 1440,
    'letter': 10080,
    'review_experience': 1440,
    'memory_housekeeping': 1440,
    'quiet': 0,
  };

  int cooldownMinutesFor(ProactiveActionKind kind) =>
      cooldowns[kind.wire] ?? defaultCooldowns[kind.wire] ?? 120;

  ProactiveAdjustment adjustmentFor(ProactiveActionKind kind) =>
      adjustments[kind.wire] ?? const ProactiveAdjustment();

  ProactiveSettings copyWith({
    ProactivityLevel? level,
    bool? enabled,
    String? quietStart,
    String? quietEnd,
    int? dailyCap,
    int? minIntervalMinutes,
    Map<String, int>? cooldowns,
    Set<String>? disabledKinds,
    int? dedupWindowDays,
    double? contentSimilarityThreshold,
    Map<String, ProactiveAdjustment>? adjustments,
  }) {
    return ProactiveSettings(
      level: level ?? this.level,
      enabled: enabled ?? this.enabled,
      quietStart: quietStart ?? this.quietStart,
      quietEnd: quietEnd ?? this.quietEnd,
      dailyCap: dailyCap ?? this.dailyCap,
      minIntervalMinutes: minIntervalMinutes ?? this.minIntervalMinutes,
      cooldowns: cooldowns ?? this.cooldowns,
      disabledKinds: disabledKinds ?? this.disabledKinds,
      dedupWindowDays: dedupWindowDays ?? this.dedupWindowDays,
      contentSimilarityThreshold:
          contentSimilarityThreshold ?? this.contentSimilarityThreshold,
      adjustments: adjustments ?? this.adjustments,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'level': level.wire,
    'enabled': enabled,
    'quietStart': quietStart,
    'quietEnd': quietEnd,
    'dailyCap': dailyCap,
    'minIntervalMinutes': minIntervalMinutes,
    'cooldowns': cooldowns,
    'disabledKinds': disabledKinds.toList(),
    'dedupWindowDays': dedupWindowDays,
    'contentSimilarityThreshold': contentSimilarityThreshold,
    'adjustments': adjustments.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
  };

  static ProactiveSettings fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return const ProactiveSettings();
    final cooldownsRaw = json['cooldowns'];
    final adjustmentsRaw = json['adjustments'];
    return ProactiveSettings(
      level: ProactivityLevel.fromWire(json['level'] as String?),
      enabled: json['enabled'] as bool? ?? true,
      quietStart: json['quietStart'] as String? ?? '23:00',
      quietEnd: json['quietEnd'] as String? ?? '08:00',
      dailyCap: (json['dailyCap'] as num?)?.toInt(),
      minIntervalMinutes: (json['minIntervalMinutes'] as num?)?.toInt(),
      cooldowns: cooldownsRaw is Map
          ? cooldownsRaw.map(
              (key, value) => MapEntry(key.toString(), (value as num).toInt()),
            )
          : const <String, int>{},
      disabledKinds:
          (json['disabledKinds'] as List?)?.map((e) => e.toString()).toSet() ??
          const <String>{},
      dedupWindowDays: (json['dedupWindowDays'] as num?)?.toInt() ?? 14,
      contentSimilarityThreshold:
          (json['contentSimilarityThreshold'] as num?)?.toDouble() ?? 0.62,
      adjustments: adjustmentsRaw is Map
          ? adjustmentsRaw.map(
              (key, value) => MapEntry(
                key.toString(),
                ProactiveAdjustment.fromJson(
                  Map<String, dynamic>.from(value as Map),
                ),
              ),
            )
          : const <String, ProactiveAdjustment>{},
    );
  }
}

/// 决策结论类型
enum ProactiveDecisionKind {
  execute('execute', '执行'),
  defer('defer', '顺延'),
  reject('reject', '拒绝');

  const ProactiveDecisionKind(this.wire, this.label);

  final String wire;
  final String label;
}

/// 决策原因（UI/报告可解释性）
enum ProactiveReason {
  eligible('eligible', '可以执行'),
  hardLimitDisabled('hard_limit_disabled', '主动行为已被你关闭'),
  hardLimitKindDisabled('hard_limit_kind_disabled', '这一类主动行为已被你关闭'),
  expired('expired', '候选已过期'),
  duplicateKey('duplicate_key', '同主题近期已表达'),
  duplicateContent('duplicate_content', '内容与近期表达过于相似'),
  cooldown('cooldown', '同类行为冷却中'),
  quietHours('quiet_hours', '勿扰时段'),
  dailyCap('daily_cap', '今日主动次数已达上限'),
  minInterval('min_interval', '距上次主动时间太近');

  const ProactiveReason(this.wire, this.label);

  final String wire;
  final String label;

  bool get isHardLimit =>
      this == hardLimitDisabled || this == hardLimitKindDisabled;
}

/// 单个候选的决策
class ProactiveDecision {
  const ProactiveDecision({
    required this.candidateId,
    required this.kind,
    required this.reason,
    this.nextEligibleAtMs,
    this.note,
  });

  final String candidateId;
  final ProactiveDecisionKind kind;
  final ProactiveReason reason;
  final int? nextEligibleAtMs; // 顺延目标时间
  final String? note;

  bool get isExecute => kind == ProactiveDecisionKind.execute;
  bool get isDefer => kind == ProactiveDecisionKind.defer;
  bool get isReject => kind == ProactiveDecisionKind.reject;
}

/// 决策上下文（全部由数据层预先聚合，策略层保持纯函数）
class ProactiveDecisionContext {
  const ProactiveDecisionContext({
    required this.nowMs,
    required this.settings,
    this.executedTodayTotal = 0,
    this.executedTodayByKind = const <String, int>{},
    this.lastProactiveAtMs,
    this.recentOutputs = const <RecentProactiveOutput>[],
  });

  final int nowMs;
  final ProactiveSettings settings;
  final int executedTodayTotal;
  final Map<String, int> executedTodayByKind;
  final int? lastProactiveAtMs;
  final List<RecentProactiveOutput> recentOutputs;
}

/// 单次决策运行结果
class ProactiveRunResult {
  const ProactiveRunResult({
    required this.decisions,
    required this.executed,
    required this.deferred,
    required this.rejected,
    required this.expired,
    this.executedCandidateId,
  });

  final List<ProactiveDecision> decisions;
  final int executed;
  final int deferred;
  final int rejected;
  final int expired;
  final String? executedCandidateId;

  static const empty = ProactiveRunResult(
    decisions: <ProactiveDecision>[],
    executed: 0,
    deferred: 0,
    rejected: 0,
    expired: 0,
  );

  bool get isEmpty => decisions.isEmpty && expired == 0;
}
