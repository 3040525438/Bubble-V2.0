// 说说领域模型（T10.1/T10.2）：心情/来源、草稿校验、去重与生成提示词。
// 依据 DATABASE_DESIGN §2.18、REQUIREMENTS FR-POST、UI_PAGE_SPEC §2/§28/§29。
import 'dart:convert';

import '../text/text_similarity.dart';

/// 说说心情（与筛选 chips 一致）
enum PostMood {
  mood('mood', '心情'),
  daily('daily', '日常'),
  thought('thought', '感悟'),
  interest('interest', '兴趣');

  const PostMood(this.wire, this.label);

  final String wire;
  final String label;

  static PostMood? fromWire(String? value) {
    for (final mood in PostMood.values) {
      if (mood.wire == value) return mood;
    }
    return null;
  }
}

/// 生成方式（与 posts.origin 约束一致）
enum PostOrigin {
  autonomous('autonomous', '泡泡自主生成'),
  userTopic('user_topic', '按你指定的主题生成');

  const PostOrigin(this.wire, this.label);

  final String wire;
  final String label;

  static PostOrigin fromWire(String? value) {
    for (final origin in PostOrigin.values) {
      if (origin.wire == value) return origin;
    }
    return PostOrigin.autonomous;
  }
}

/// 生成请求模式
enum PostGenerationMode { autonomous, userTopic }

/// 生成素材（记忆/经历的轻量快照，供提示词与本地降级使用）
class PostMaterial {
  const PostMaterial({
    required this.id,
    required this.title,
    required this.summary,
    this.kind = 'memory',
  });

  final String id;
  final String title;
  final String summary;
  final String kind;

  String get display => title.trim().isEmpty ? summary : title;
}

/// 说说草稿
class PostDraft {
  const PostDraft({
    required this.content,
    this.mood,
    this.topic,
    this.imageIds = const <String>[],
    this.origin = PostOrigin.autonomous,
    this.relatedMemoryIds = const <String>[],
    this.relatedConversationId,
  });

  final String content;
  final PostMood? mood;
  final String? topic;
  final List<String> imageIds;
  final PostOrigin origin;
  final List<String> relatedMemoryIds;
  final String? relatedConversationId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'content': content,
    'mood': mood?.wire,
    'topic': topic,
    'imageIds': imageIds,
    'origin': origin.wire,
    'relatedMemoryIds': relatedMemoryIds,
    'relatedConversationId': relatedConversationId,
  };

  static PostDraft? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final content = (json['content'] as String? ?? '').trim();
    if (content.isEmpty) return null;
    return PostDraft(
      content: content,
      mood: PostMood.fromWire(json['mood'] as String?),
      topic: json['topic'] as String?,
      imageIds:
          (json['imageIds'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      origin: PostOrigin.fromWire(json['origin'] as String?),
      relatedMemoryIds:
          (json['relatedMemoryIds'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      relatedConversationId: json['relatedConversationId'] as String?,
    );
  }
}

/// 生成请求
class PostGenerationRequest {
  const PostGenerationRequest({
    required this.mode,
    this.topic,
    this.mood,
    this.personaPrompt = '',
    this.materials = const <PostMaterial>[],
    this.recentContents = const <String>[],
  });

  final PostGenerationMode mode;
  final String? topic;
  final PostMood? mood;
  final String personaPrompt;
  final List<PostMaterial> materials;
  final List<String> recentContents;
}

/// 生成结果（发布前预览，可编辑）
class PostGeneratedDraft {
  const PostGeneratedDraft({
    required this.content,
    required this.origin,
    this.mood,
    this.topic,
    this.relatedMemoryIds = const <String>[],
    this.fromModel = false,
    this.duplicateRisk = false,
  });

  final String content;
  final PostOrigin origin;
  final PostMood? mood;
  final String? topic;
  final List<String> relatedMemoryIds;

  /// true = 真实模型生成；false = 本地降级草稿（UI 需明确标注）
  final bool fromModel;
  final bool duplicateRisk;

  PostGeneratedDraft copyWith({String? content, PostMood? mood}) {
    return PostGeneratedDraft(
      content: content ?? this.content,
      origin: origin,
      mood: mood ?? this.mood,
      topic: topic,
      relatedMemoryIds: relatedMemoryIds,
      fromModel: fromModel,
      duplicateRisk: duplicateRisk,
    );
  }
}

/// 去重结果
class PostDedupResult {
  const PostDedupResult({
    required this.duplicate,
    required this.maxSimilarity,
    this.matchedContent,
  });

  final bool duplicate;
  final double maxSimilarity;
  final String? matchedContent;

  static const none = PostDedupResult(duplicate: false, maxSimilarity: 0);
}

/// 说说规则（纯函数）
class PostRules {
  const PostRules._();

  static const maxLength = 500;
  static const defaultDedupThreshold = 0.55;

  /// 校验草稿；返回 null 表示通过
  static String? validateDraft(PostDraft draft) {
    final content = draft.content.trim();
    if (content.isEmpty) return '说说内容不能为空';
    if (content.length > maxLength) return '说说不超过 $maxLength 字';
    if (draft.origin == PostOrigin.userTopic &&
        (draft.topic ?? '').trim().isEmpty) {
      return '指定主题生成需要填写主题';
    }
    return null;
  }

  /// 与最近说说比对，判断是否重复（验收：重复检测生效）
  static PostDedupResult dedup(
    String content,
    List<String> recentContents, {
    double threshold = defaultDedupThreshold,
  }) {
    var maxSimilarity = 0.0;
    String? matched;
    for (final recent in recentContents) {
      if (recent.trim().isEmpty) continue;
      final similarity = contentSimilarity(content, recent);
      if (similarity > maxSimilarity) {
        maxSimilarity = similarity;
        matched = recent;
      }
    }
    return PostDedupResult(
      duplicate: maxSimilarity >= threshold,
      maxSimilarity: maxSimilarity,
      matchedContent: matched,
    );
  }

  /// 构造真实模型提示词（人格 + 素材 + 不重复约束）
  static String buildPrompt(PostGenerationRequest request) {
    final persona = request.personaPrompt.trim();
    final buffer = StringBuffer()
      ..writeln('你是「泡泡」，以下是你的核心人格与说话方式：')
      ..writeln(persona.isEmpty ? '（人格描述暂缺，保持温柔、真诚、不过度热情）' : persona)
      ..writeln();
    if (request.materials.isNotEmpty) {
      buffer.writeln('你可以参考的近期记忆（只能引用真实存在的，不要编造）：');
      for (final material in request.materials.take(6)) {
        buffer.writeln('- ${material.display}：${material.summary}');
      }
      buffer.writeln();
    }
    if (request.recentContents.isNotEmpty) {
      buffer.writeln('最近已经发过的说说（不要重复这些主题与表达）：');
      for (final recent in request.recentContents.take(6)) {
        buffer.writeln('- $recent');
      }
      buffer.writeln();
    }
    final topic = (request.topic ?? '').trim();
    buffer
      ..writeln('请写一条 40~120 字的说说。')
      ..writeln('心情：${(request.mood ?? PostMood.daily).label}')
      ..writeln(topic.isEmpty ? '主题：从上面的记忆里自然想起一件小事。' : '主题：$topic')
      ..writeln(
        '要求：第一人称、口语化、不要模板腔、不要堆砌 emoji、'
        '不要编造双方没有发生过的经历。只输出说说正文。',
      );
    return buffer.toString();
  }

  /// 本地降级生成（未配置模型时使用；UI 会明确标注「本地草稿」）
  static PostGeneratedDraft localGenerate(PostGenerationRequest request) {
    final topic = (request.topic ?? '').trim();
    final material = request.materials.isEmpty ? null : request.materials.first;
    final persona = request.personaPrompt;
    final gentle = persona.contains('温柔') || persona.contains('安静');
    final playful = persona.contains('调皮') || persona.contains('活泼');

    String content;
    if (topic.isNotEmpty) {
      final head = material == null
          ? '今天忽然想聊聊「$topic」。'
          : '由「${material.display}」想到「$topic」。';
      final body = material == null
          ? '不是什么大事，只是觉得你会想听。'
          : '你说过的那些细节，我都还记着：${_trim(material.summary, 40)}';
      content = '$head$body${_ending(gentle, playful)}';
    } else if (material != null) {
      content =
          '由「${material.display}」想起。'
          '${_trim(material.summary, 50)}'
          '这些小事我都记得，偶尔会翻出来看看。${_ending(gentle, playful)}';
    } else {
      content =
          '今天没有发生什么大事，只是忽然想和你说说话。'
          '${_ending(gentle, playful)}';
    }

    return PostGeneratedDraft(
      content: content,
      origin: request.mode == PostGenerationMode.userTopic
          ? PostOrigin.userTopic
          : PostOrigin.autonomous,
      mood: request.mood ?? PostMood.daily,
      topic: topic.isEmpty ? null : topic,
      relatedMemoryIds: material == null ? const <String>[] : [material.id],
      fromModel: false,
    );
  }

  static String _ending(bool gentle, bool playful) {
    if (playful) return '等你有空，来跟我说说今天。';
    if (gentle) return '慢慢来，我一直在。';
    return '想到了就记一下，等你想聊的时候再说。';
  }

  static String _trim(String text, int max) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= max) return cleaned;
    return '${cleaned.substring(0, max)}…';
  }

  static List<String> decodeIds(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 忽略损坏的关联字段
    }
    return const <String>[];
  }
}
