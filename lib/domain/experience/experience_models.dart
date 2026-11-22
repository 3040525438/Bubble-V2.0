// 共同经历领域模型（T9.1）：历史事实不可改，视角可补，回顾记录只追加。
// 依据 DATABASE_DESIGN §2.17、REQUIREMENTS FR-EXP-01~04、UI_PAGE_SPEC §3。
import 'dart:convert';

/// 回顾记录条目（只追加，永不修改或删除）
class ExperienceReviewEntry {
  const ExperienceReviewEntry({
    required this.atMs,
    required this.content,
    required this.author,
  });

  final int atMs;
  final String content;

  /// user / bubble
  final String author;

  String get authorLabel => author == 'user' ? '你' : '泡泡';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'atMs': atMs,
    'content': content,
    'author': author,
  };

  static ExperienceReviewEntry? fromJson(Map<String, dynamic> json) {
    final content = (json['content'] as String? ?? '').trim();
    if (content.isEmpty) return null;
    return ExperienceReviewEntry(
      atMs: (json['atMs'] as num?)?.toInt() ?? 0,
      content: content,
      author: json['author'] as String? ?? 'bubble',
    );
  }
}

/// 历史事实：创建后不可被 AI 修改（用户也不能改「发生过什么」本身）
class ExperienceFacts {
  const ExperienceFacts({
    required this.name,
    required this.occurredAtMs,
    required this.eventContent,
  });

  final String name;
  final int occurredAtMs;
  final String eventContent;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'occurredAtMs': occurredAtMs,
    'eventContent': eventContent,
  };

  static ExperienceFacts? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final name = (json['name'] as String? ?? '').trim();
    final content = (json['eventContent'] as String? ?? '').trim();
    if (name.isEmpty || content.isEmpty) return null;
    return ExperienceFacts(
      name: name,
      occurredAtMs: (json['occurredAtMs'] as num?)?.toInt() ?? 0,
      eventContent: content,
    );
  }
}

/// 新建共同经历的草稿
class ExperienceDraft {
  const ExperienceDraft({
    required this.name,
    required this.occurredAtMs,
    required this.eventContent,
    this.relatedMemoryIds = const <String>[],
    this.relatedConversationIds = const <String>[],
    this.importance = 50,
    this.userPerspective,
    this.bubblePerspective,
  });

  final String name;
  final int occurredAtMs;
  final String eventContent;
  final List<String> relatedMemoryIds;
  final List<String> relatedConversationIds;
  final int importance;
  final String? userPerspective;
  final String? bubblePerspective;

  ExperienceFacts get facts => ExperienceFacts(
    name: name,
    occurredAtMs: occurredAtMs,
    eventContent: eventContent,
  );
}

/// 从记忆/思考流自动提名的一段经历（提名只是建议，必须由用户确认后创建）
class ExperienceNomination {
  const ExperienceNomination({
    required this.sourceKind,
    required this.sourceId,
    required this.suggestedName,
    required this.occurredAtMs,
    required this.eventContent,
    required this.reason,
    this.importance = 50,
    this.relatedMemoryIds = const <String>[],
  });

  /// memory / thinking
  final String sourceKind;
  final String sourceId;
  final String suggestedName;
  final int occurredAtMs;
  final String eventContent;
  final String reason;
  final int importance;
  final List<String> relatedMemoryIds;

  ExperienceDraft toDraft() => ExperienceDraft(
    name: suggestedName,
    occurredAtMs: occurredAtMs,
    eventContent: eventContent,
    importance: importance,
    relatedMemoryIds: relatedMemoryIds,
  );
}

/// 共同经历规则（纯函数，便于单测）
class ExperienceRules {
  const ExperienceRules._();

  static const factLockNote = '历史事实不可修改 · 回顾记录只追加';

  /// 校验草稿；返回 null 表示通过
  static String? validateDraft(ExperienceDraft draft) {
    if (draft.name.trim().isEmpty) return '经历名称不能为空';
    if (draft.eventContent.trim().isEmpty) return '发生的事不能为空';
    if (draft.occurredAtMs <= 0) return '发生时间无效';
    if (draft.importance < 0 || draft.importance > 100) return '重要程度需在 0~100';
    return null;
  }

  /// 回顾记录只追加：返回新列表，原列表不被修改
  static List<ExperienceReviewEntry> appendReview(
    List<ExperienceReviewEntry> existing,
    ExperienceReviewEntry entry,
  ) {
    final content = entry.content.trim();
    if (content.isEmpty) {
      throw ArgumentError('回顾内容不能为空');
    }
    if (content.length > 500) {
      throw ArgumentError('单条回顾不超过 500 字');
    }
    return <ExperienceReviewEntry>[
      ...existing,
      ExperienceReviewEntry(
        atMs: entry.atMs,
        content: content,
        author: entry.author,
      ),
    ];
  }

  static List<ExperienceReviewEntry> parseReviewLog(String? raw) {
    if (raw == null || raw.trim().isEmpty)
      return const <ExperienceReviewEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(ExperienceReviewEntry.fromJson)
            .whereType<ExperienceReviewEntry>()
            .toList();
      }
    } catch (_) {
      // 损坏的历史记录不阻断页面
    }
    return const <ExperienceReviewEntry>[];
  }

  static String encodeReviewLog(List<ExperienceReviewEntry> entries) {
    return jsonEncode(entries.map((e) => e.toJson()).toList());
  }

  /// AI 只能提出视角建议：返回新的视角文本，绝不改动历史事实
  static String proposePerspective(String? current, String proposal) {
    final trimmed = proposal.trim();
    if (trimmed.isEmpty) return current ?? '';
    return trimmed;
  }

  /// 三维事实一致性校验：用于确认某次更新没有篡改历史
  static bool factsUnchanged(ExperienceFacts before, ExperienceFacts after) {
    return before.name == after.name &&
        before.occurredAtMs == after.occurredAtMs &&
        before.eventContent == after.eventContent;
  }
}
