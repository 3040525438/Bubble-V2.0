// SSE 解析单测（T3.1）：任意切包、[DONE]、usage、非法 chunk 容错、reasoning 增量。
import 'dart:io';

import 'package:bubble/domain/chat/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

String fixture() =>
    File('test/fixtures/deepseek_sse.txt').readAsStringSync();

void main() {
  group('SseEventParser', () {
    test('基础事件解析（data/event/注释）', () {
      final parser = SseEventParser();
      final events = parser.add('event: message\n: keepalive\ndata: hello\n\n');
      expect(events.length, 1);
      expect(events.single.event, 'message');
      expect(events.single.data, 'hello');
    });

    test('任意切包仍能还原完整事件', () {
      final parser = SseEventParser();
      final text = fixture();
      final events = <SseEvent>[];
      // 每 7 字节切一次，覆盖多字节字符边界
      for (var i = 0; i < text.length; i += 7) {
        events.addAll(parser.add(text.substring(i, (i + 7).clamp(0, text.length))));
      }
      events.addAll(parser.flush());
      final dataEvents = events.where((e) => e.data.isNotEmpty).toList();
      expect(dataEvents.length, 5);
      expect(dataEvents.last.data, '[DONE]');
    });

    test('CRLF 行尾兼容', () {
      final parser = SseEventParser();
      final events = parser.add('data: a\r\n\r\ndata: b\r\n\r\n');
      expect(events.map((e) => e.data), ['a', 'b']);
    });

    test('多行 data 用换行拼接', () {
      final parser = SseEventParser();
      final events = parser.add('data: line1\ndata: line2\n\n');
      expect(events.single.data, 'line1\nline2');
    });
  });

  group('DeepSeekStreamParser', () {
    test('回放录制流：文本增量、usage 与 [DONE]', () {
      final parser = DeepSeekStreamParser();
      final deltas = [
        ...parser.add(fixture()),
        ...parser.flush(),
      ];
      final text = deltas.map((d) => d.text).join();
      expect(text, '嗯，我在听。');
      expect(deltas.any((d) => d.done), isTrue);

      final usage = deltas.lastWhere((d) => d.usage != null).usage!;
      expect(usage.promptTokens, 12);
      expect(usage.completionTokens, 4);
      expect(usage.totalTokens, 16);
      expect(usage.costEst, greaterThan(0));
    });

    test('切包流式解析与整块结果一致', () {
      final whole = DeepSeekStreamParser();
      final wholeText =
          [...whole.add(fixture()), ...whole.flush()].map((d) => d.text).join();

      final chunked = DeepSeekStreamParser();
      final buffer = <String>[];
      final text = fixture();
      for (var i = 0; i < text.length; i += 5) {
        buffer.addAll(chunked
            .add(text.substring(i, (i + 5).clamp(0, text.length)))
            .map((d) => d.text));
      }
      buffer.addAll(chunked.flush().map((d) => d.text));
      expect(buffer.join(), wholeText);
    });

    test('非法 JSON chunk 被跳过而不崩溃', () {
      final parser = DeepSeekStreamParser();
      final deltas = [
        ...parser.add('data: {oops not json}\n\n'),
        ...parser.add(
            'data: {"choices":[{"delta":{"content":"正常"}}]}\n\n'),
      ];
      expect(deltas.map((d) => d.text).join(), '正常');
    });

    test('reasoning_content 增量被识别', () {
      final parser = DeepSeekStreamParser(modelTag: 'deepseek-reasoner');
      final deltas = parser.add(
          'data: {"choices":[{"delta":{"reasoning_content":"先想一下"}}]}\n\n');
      expect(deltas.single.reasoning, '先想一下');
      expect(deltas.single.text, isEmpty);
    });

    test('usage 的 reasoning_tokens 与 reasoner 定价', () {
      final parser = DeepSeekStreamParser(modelTag: 'deepseek-reasoner');
      final deltas = parser.add(
          'data: {"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":1000,'
          '"completion_tokens_details":{"reasoning_tokens":300}}}\n\n');
      final usage = deltas.single.usage!;
      expect(usage.reasoningTokens, 300);
      // reasoner：输入 ¥4/百万 + 输出 ¥16/百万 = 0.004 + 0.016
      expect(usage.costEst, closeTo(0.02, 0.0001));
    });
  });
}
