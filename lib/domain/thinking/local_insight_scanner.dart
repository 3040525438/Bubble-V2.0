// 本地关联分析（T7.2 第③步，零成本）：不调用模型，发现记忆间联系、观点变化、
// 未续话题、值得分享与日记素材。输出上限 8 条，空则产出正式「保持安静」决策。
import '../search/tokenizer.dart';
import 'thinking_models.dart';

class LocalInsightScanner {
  const LocalInsightScanner();

  static const int maxInsights = 8;

  List<ThinkingInsight> scan(ThinkingReviewInput input) {
    final insights = <ThinkingInsight>[];
    insights.addAll(_connections(input.memories));
    insights.addAll(_reunderstandings(input.memories));
    insights.addAll(_unfinishedTopics(input.newMessages));
    insights.addAll(_shareWorthy(input.memories));
    insights.addAll(_diaryMaterial(input.memories));

    final seen = <String>{};
    final unique = <ThinkingInsight>[];
    for (final insight in insights) {
      if (!seen.add(insight.effectiveDedupKey)) continue;
      unique.add(insight);
      if (unique.length >= maxInsights) break;
    }
    if (unique.isEmpty) {
      return const <ThinkingInsight>[
        ThinkingInsight(
          kind: ThinkingResultKind.quiet,
          content: '这一轮没有发现值得打扰你的内容，泡泡选择保持安静。',
          actionKind: ProactiveActionKind.quiet,
          priority: 0,
          sourceKind: 'quiet',
          confidence: 'high',
        ),
      ];
    }
    return unique;
  }

  List<ThinkingInsight> _connections(List<MemoryBrief> memories) {
    final candidates = memories.take(30).toList();
    final results = <ThinkingInsight>[];
    for (var i = 0; i < candidates.length; i++) {
      for (var j = i + 1; j < candidates.length; j++) {
        final a = candidates[i];
        final b = candidates[j];
        if (a.id == b.id) continue;
        final aTokens = similarityTokens('${a.title} ${a.summary}');
        final bTokens = similarityTokens('${b.title} ${b.summary}');
        final shared = aTokens.intersection(bTokens).toList();
        if (shared.length < 2) continue;
        final overlap = overlapCoefficient(aTokens, bTokens);
        if (overlap < 0.35) continue;
        final keyword = shared.take(2).join('、');
        results.add(ThinkingInsight(
          kind: ThinkingResultKind.newConnection,
          content: '「${a.display}」和「${b.display}」好像有联系，'
              '它们都和「$keyword」有关。',
          relatedMemoryIds: [a.id, b.id],
          confidence: overlap >= 0.6 ? 'high' : 'medium',
          priority: 60,
          sourceKind: 'memory_relation',
        ));
        if (results.length >= 3) return results;
      }
    }
    return results;
  }

  List<ThinkingInsight> _reunderstandings(List<MemoryBrief> memories) {
    final markers =
        RegExp(r'(以前|之前|曾经).{0,20}(现在|如今|后来)|不再|变了|原来');
    final results = <ThinkingInsight>[];
    for (final memory in memories) {
      if (memory.type != 'opinion' && memory.type != 'relationship') continue;
      final text = '${memory.title} ${memory.summary}';
      if (!markers.hasMatch(text)) continue;
      results.add(ThinkingInsight(
        kind: ThinkingResultKind.reunderstanding,
        content: '关于「${memory.display}」，你的想法好像变了：${memory.summary}',
        relatedMemoryIds: [memory.id],
        confidence: 'medium',
        priority: 55,
        sourceKind: 'opinion_change',
      ));
      if (results.length >= 2) break;
    }
    return results;
  }

  List<ThinkingInsight> _unfinishedTopics(List<ReviewMessage> messages) {
    final marker = RegExp(r'[?？]|下次|改天|以后再说|还没|回头再');
    final results = <ThinkingInsight>[];
    final seen = <String>{};
    for (final message in messages.reversed) {
      if (message.role != 'user') continue;
      if (!marker.hasMatch(message.content)) continue;
      if (!seen.add(message.content)) continue;
      results.add(ThinkingInsight(
        kind: ThinkingResultKind.topicWorthContinuing,
        content: '这个话题好像还没聊完：${_clip(message.content)}',
        relatedMessageIds: [message.id],
        confidence: 'medium',
        priority: 65,
        sourceKind: 'unfinished_topic',
      ));
      if (results.length >= 2) break;
    }
    return results;
  }

  List<ThinkingInsight> _shareWorthy(List<MemoryBrief> memories) {
    final results = <ThinkingInsight>[];
    for (final memory in memories) {
      const types = {'experience_joint', 'important_experience', 'event'};
      if (!types.contains(memory.type)) continue;
      results.add(ThinkingInsight(
        kind: ThinkingResultKind.shareWorthy,
        content: '这段经历也许可以拿出来聊聊：${_clip(memory.summary)}',
        relatedMemoryIds: [memory.id],
        confidence: 'medium',
        priority: 70,
        sourceKind: memory.type == 'experience_joint'
            ? 'shared_experience'
            : 'memory_event',
      ));
      if (results.length >= 2) break;
    }
    return results;
  }

  List<ThinkingInsight> _diaryMaterial(List<MemoryBrief> memories) {
    for (final memory in memories) {
      if (memory.type != 'relationship' && memory.type != 'important_experience') {
        continue;
      }
      return [
        ThinkingInsight(
          kind: ThinkingResultKind.diaryMaterial,
          content: '这一天可以写进日记：${_clip(memory.summary)}',
          relatedMemoryIds: [memory.id],
          confidence: 'medium',
          priority: 50,
          actionKind: ProactiveActionKind.diary,
          sourceKind: 'diary_material',
        ),
      ];
    }
    return const <ThinkingInsight>[];
  }

  static String _clip(String text, [int max = 80]) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length <= max ? clean : '${clean.substring(0, max)}…';
  }
}
