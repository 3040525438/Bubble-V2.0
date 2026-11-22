// 思考模型分析（T7.2 第④步）：一次结构化调用，输入 ≤8KiB、输出 ≤8 条。
// 失败/超时/非法 JSON 一律回退本地规则分析（不重试、不重发，借鉴 dsh 降级策略）。
import 'dart:convert';

import 'local_insight_scanner.dart';
import 'thinking_models.dart';

/// 模型调用抽象（测试注入；生产由 ChatCompletionProvider 适配）
typedef ThinkingCompletionCaller = Future<String> Function(
    String system, String user);

abstract class ThinkingModelAnalyzer {
  Future<List<ThinkingInsight>> analyze(ThinkingReviewInput input);
}

class ModelThinkingAnalyzer implements ThinkingModelAnalyzer {
  ModelThinkingAnalyzer({
    required ThinkingCompletionCaller caller,
    LocalInsightScanner fallback = const LocalInsightScanner(),
  })  : _caller = caller,
        _fallback = fallback;

  final ThinkingCompletionCaller _caller;
  final LocalInsightScanner _fallback;

  static const int maxInputBytes = 8 * 1024;
  static const int maxInsights = 8;
  static const int maxContentLength = 300;

  static const String systemPrompt = '''
你是「泡泡」的自主思考模块。你只做内部思考，不直接与用户对话。
根据提供的有限回顾数据，发现：聊天之间的联系、对过去问题的新理解、值得继续的话题、值得分享的内容、日记素材。
严格输出 JSON 数组（不要 Markdown 代码块），最多 8 条，字段：
{"kind":"new_connection|reunderstanding|topic_worth_continuing|share_worthy|diary_material",
 "content":"中文，不超过120字","confidence":"low|medium|high",
 "memoryIds":["只能使用输入中真实存在的 id"],"messageIds":["只能使用输入中真实存在的 id"],
 "action":"chat|post|diary|letter","priority":0-100}
没有值得说的就输出 []，不要编造未提供的经历、记忆 id 或消息 id。''';

  @override
  Future<List<ThinkingInsight>> analyze(ThinkingReviewInput input) async {
    try {
      final user = buildUserPrompt(input);
      final raw = await _caller(systemPrompt, user);
      final parsed = _parse(raw);
      if (parsed.isNotEmpty) return parsed;
      return _fallback.scan(input);
    } catch (_) {
      return _fallback.scan(input);
    }
  }

  /// 构造有界输入包（≤8KiB）：逐级裁剪旧消息、新消息、记忆、旧想法。
  static String buildUserPrompt(ThinkingReviewInput input) {
    List<Map<String, dynamic>> messages(List<ReviewMessage> list) => [
          for (final m in list)
            {
              'id': m.id,
              'role': m.role,
              'content': _clip(m.content, 160),
              'at': m.createdAtMs,
            }
        ];
    List<Map<String, dynamic>> memories(List<MemoryBrief> list) => [
          for (final m in list)
            {
              'id': m.id,
              'type': m.type,
              'title': _clip(m.title, 60),
              'summary': _clip(m.summary, 160),
            }
        ];

    var newMessages = messages(input.newMessages.take(20).toList());
    var sampled = messages(input.sampledMessages.take(8).toList());
    var memoryItems = memories(input.memories.take(20).toList());
    var agreements = memories(input.agreements.take(6).toList());
    var pastThoughts = [
      for (final thought in input.pastThoughts.take(6)) _clip(thought, 80),
    ];

    String encode() => jsonEncode(<String, dynamic>{
          'newMessages': newMessages,
          'sampledMessages': sampled,
          'memories': memoryItems,
          'agreements': agreements,
          'pastThoughts': pastThoughts,
          'scopeNote': _clip(input.scopeNote, 120),
        });

    var output = encode();
    while (output.length > maxInputBytes && sampled.isNotEmpty) {
      sampled = sampled.sublist(1);
      output = encode();
    }
    while (output.length > maxInputBytes && newMessages.length > 4) {
      newMessages = newMessages.sublist(1);
      output = encode();
    }
    while (output.length > maxInputBytes && memoryItems.length > 4) {
      memoryItems = memoryItems.sublist(1);
      output = encode();
    }
    while (output.length > maxInputBytes && pastThoughts.isNotEmpty) {
      pastThoughts = pastThoughts.sublist(1);
      output = encode();
    }
    return output;
  }

  static List<ThinkingInsight> _parse(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return const <ThinkingInsight>[];
    dynamic decoded;
    try {
      decoded = jsonDecode(raw.substring(start, end + 1));
    } catch (_) {
      return const <ThinkingInsight>[];
    }
    if (decoded is! List) return const <ThinkingInsight>[];
    final results = <ThinkingInsight>[];
    for (final item in decoded.take(maxInsights)) {
      if (item is! Map) continue;
      final map = item.cast<String, dynamic>();
      final content = (map['content'] as String? ?? '').trim();
      if (content.isEmpty) continue;
      final kind = ThinkingResultKind.fromWire(map['kind'] as String?);
      results.add(ThinkingInsight(
        kind: kind,
        content: content.length > maxContentLength
            ? '${content.substring(0, maxContentLength)}…'
            : content,
        confidence: _normalizeConfidence(map['confidence'] as String?),
        relatedMemoryIds: _ids(map['memoryIds']),
        relatedMessageIds: _ids(map['messageIds']),
        actionKind: ProactiveActionKind.fromWire(map['action'] as String?),
        priority: _normalizePriority(map['priority']),
        sourceKind: 'model_thinking',
      ));
    }
    return results;
  }

  static List<String> _ids(dynamic value) {
    if (value is! List) return const <String>[];
    return value.whereType<String>().take(6).toList();
  }

  static String _normalizeConfidence(String? value) {
    if (value == 'high' || value == 'low') return value!;
    return 'medium';
  }

  static int _normalizePriority(dynamic value) {
    final parsed = value is int ? value : int.tryParse('$value');
    if (parsed == null) return 50;
    return parsed.clamp(0, 100);
  }

  static String _clip(String text, int max) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= max ? clean : '${clean.substring(0, max)}…';
  }

  /// 生成去重用的内容指纹（供仓储判重）
  static String fingerprint(ThinkingInsight insight) =>
      '${insight.kind.wire}:${stableHash(insight.content)}';
}
