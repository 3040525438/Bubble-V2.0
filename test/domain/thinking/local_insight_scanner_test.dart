// 本地关联分析单测（T7.2 第③步）：联系/重理解/未续话题/分享/日记/安静。
import 'package:bubble/domain/thinking/local_insight_scanner.dart';
import 'package:bubble/domain/thinking/thinking_models.dart';
import 'package:flutter_test/flutter_test.dart';

MemoryBrief _memory(
  String id, {
  String type = 'preference',
  String title = '',
  String summary = '',
}) {
  return MemoryBrief(
    id: id,
    type: type,
    title: title,
    summary: summary,
    updatedAtMs: 0,
  );
}

ReviewMessage _message(String id, String content,
    {String role = 'user', int at = 1}) {
  return ReviewMessage(
    id: id,
    conversationId: 'c1',
    role: role,
    content: content,
    createdAtMs: at,
  );
}

ThinkingReviewInput _input({
  List<MemoryBrief> memories = const <MemoryBrief>[],
  List<ReviewMessage> newMessages = const <ReviewMessage>[],
}) {
  return ThinkingReviewInput(
    newMessages: newMessages,
    sampledMessages: const <ReviewMessage>[],
    memories: memories,
    agreements: memories.where((m) => m.type == 'agreement').toList(),
    pastThoughts: const <String>[],
    personaPrompt: '你是泡泡',
    reviewedUntilMs: 0,
  );
}

void main() {
  const scanner = LocalInsightScanner();

  test('高重叠记忆产生新联系', () {
    final insights = scanner.scan(_input(memories: [
      _memory('m1',
          title: '西湖散步', summary: '我喜欢在周末去西湖边散步'),
      _memory('m2',
          title: '西湖跑步', summary: '我喜欢在周末去西湖边跑步'),
    ]));
    final connection = insights
        .firstWhere((i) => i.kind == ThinkingResultKind.newConnection);
    expect(connection.relatedMemoryIds, containsAll(['m1', 'm2']));
    expect(connection.content.contains('有联系'), isTrue);
  });

  test('观点变化记忆产生重新理解', () {
    final insights = scanner.scan(_input(memories: [
      _memory('m1',
          type: 'opinion',
          title: '独处',
          summary: '以前我觉得独处很好，现在发现有人陪也不错'),
    ]));
    expect(
        insights.any((i) => i.kind == ThinkingResultKind.reunderstanding),
        isTrue);
  });

  test('未续话题从用户消息中识别', () {
    final insights = scanner.scan(_input(newMessages: [
      _message('msg1', '下次我们再聊这个话题好吗？'),
    ]));
    final topic = insights
        .firstWhere((i) => i.kind == ThinkingResultKind.topicWorthContinuing);
    expect(topic.relatedMessageIds, ['msg1']);
  });

  test('经历类记忆产生分享与日记素材', () {
    final insights = scanner.scan(_input(memories: [
      _memory('m1',
          type: 'event', title: '搬家', summary: '今天搬家了，新家有个小阳台'),
      _memory('m2',
          type: 'relationship', title: '关系', summary: '我们的关系好像更近了一点'),
    ]));
    expect(insights.any((i) => i.kind == ThinkingResultKind.shareWorthy), isTrue);
    expect(insights.any((i) => i.kind == ThinkingResultKind.diaryMaterial), isTrue);
  });

  test('空输入产出正式安静决策且无候选', () {
    final insights = scanner.scan(_input());
    expect(insights.length, 1);
    expect(insights.first.kind, ThinkingResultKind.quiet);
    expect(insights.first.actionKind, ProactiveActionKind.quiet);
  });

  test('结果上限 8 条且按去重键去重', () {
    final memories = <MemoryBrief>[
      for (var i = 0; i < 12; i++)
        _memory('m$i',
            title: '跑步$i', summary: '我喜欢在周末去西湖边跑步，第$i次'),
      for (var i = 0; i < 12; i++)
        _memory('a$i',
            type: 'event', title: '事件$i', summary: '今天发生了一件特别的事，第$i次'),
    ];
    final insights = scanner.scan(_input(memories: memories));
    expect(insights.length, lessThanOrEqualTo(8));
    final keys = insights.map((i) => i.effectiveDedupKey).toSet();
    expect(keys.length, insights.length);
  });
}
