// 模型思考分析单测（T7.2 第④步）：结构化解析、边界裁剪与降级。
import 'package:bubble/domain/thinking/thinking_analyzer.dart';
import 'package:bubble/domain/thinking/thinking_models.dart';
import 'package:flutter_test/flutter_test.dart';

ThinkingReviewInput _input({int messages = 0, int memories = 0}) {
  return ThinkingReviewInput(
    newMessages: [
      for (var i = 0; i < messages; i++)
        ReviewMessage(
          id: 'msg$i',
          conversationId: 'c1',
          role: 'user',
          content: '第$i条消息：今天聊了很多关于工作和生活的事情，${'啊' * 60}',
          createdAtMs: i,
        ),
    ],
    sampledMessages: const <ReviewMessage>[],
    memories: [
      for (var i = 0; i < memories; i++)
        MemoryBrief(
          id: 'm$i',
          type: 'preference',
          title: '记忆$i',
          summary: '我喜欢在周末去西湖边散步，第$i次，${'嗯' * 60}',
          updatedAtMs: i,
        ),
    ],
    agreements: const <MemoryBrief>[],
    pastThoughts: const <String>[],
    personaPrompt: '你是泡泡',
    reviewedUntilMs: 0,
  );
}

void main() {
  test('合法 JSON 解析为洞察，过滤空内容并限 8 条', () async {
    final json = '''
[
 ${List.generate(10, (i) => '{"kind":"share_worthy","content":"想法$i","confidence":"high","memoryIds":["m$i"],"priority":${100 + i}}').join(',')}
]
''';
    final analyzer = ModelThinkingAnalyzer(
      caller: (system, user) async => json,
    );
    final insights = await analyzer.analyze(_input(memories: 10));
    expect(insights.length, 8);
    expect(insights.first.kind, ThinkingResultKind.shareWorthy);
    expect(insights.first.confidence, 'high');
    expect(insights.first.priority, 100);
  });

  test('非法/空输出回退本地规则', () async {
    final analyzer = ModelThinkingAnalyzer(
      caller: (system, user) async => '抱歉，我无法输出 JSON',
    );
    final insights = await analyzer.analyze(_input());
    expect(insights.length, 1);
    expect(insights.first.kind, ThinkingResultKind.quiet);
  });

  test('调用异常回退本地规则且不抛出', () async {
    final analyzer = ModelThinkingAnalyzer(
      caller: (system, user) async => throw StateError('timeout'),
    );
    final insights = await analyzer.analyze(_input());
    expect(insights, isNotEmpty);
    expect(insights.first.kind, ThinkingResultKind.quiet);
  });

  test('输入包 ≤8KiB（逐级裁剪）', () {
    final prompt = ModelThinkingAnalyzer.buildUserPrompt(
      _input(messages: 200, memories: 200),
    );
    expect(prompt.length, lessThanOrEqualTo(ModelThinkingAnalyzer.maxInputBytes));
    expect(prompt.contains('newMessages'), isTrue);
  });

  test('字段规范化：未知置信度回 medium，优先级收敛 0-100', () async {
    final analyzer = ModelThinkingAnalyzer(
      caller: (system, user) async =>
          '[{"kind":"new_connection","content":"一条联系","confidence":"weird","priority":999}]',
    );
    final insights = await analyzer.analyze(_input());
    expect(insights.first.confidence, 'medium');
    expect(insights.first.priority, 100);
  });
}
