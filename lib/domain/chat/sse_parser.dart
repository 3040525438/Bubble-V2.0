// SSE 解析器（T3.1）：纯函数，支持任意切包与 CRLF，非法数据跳过不崩溃。
// 依据 TECH_STACK「dio ResponseType.stream 支持 SSE 流式解析」与
// TEST_PLAN §3「mock SSE 流：增量渲染/取消/超时/非法 chunk 容错」。
import 'dart:convert';

import 'chat_error.dart';
import 'chat_usage.dart';

/// 单个 SSE 事件
class SseEvent {
  const SseEvent({this.event, required this.data});

  final String? event;
  final String data;
}

/// 行缓冲 SSE 解析：add() 可传入任意分块文本，返回本次完整事件。
class SseEventParser {
  final StringBuffer _pending = StringBuffer();
  final StringBuffer _data = StringBuffer();
  String? _eventName;

  List<SseEvent> add(String chunk) {
    if (chunk.isEmpty) return const [];
    _pending.write(chunk);
    final text = _pending.toString();
    final lines = text.split('\n');
    _pending.clear();
    // 最后一段可能是半个行，留到下次
    _pending.write(lines.removeLast());

    final events = <SseEvent>[];
    for (final raw in lines) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty) {
        _emitInto(events);
        continue;
      }
      if (line.startsWith(':')) continue; // 注释行
      final sep = line.indexOf(':');
      if (sep <= 0) continue;
      final field = line.substring(0, sep);
      var value = line.substring(sep + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        _eventName = value;
      } else if (field == 'data') {
        if (_data.isNotEmpty) _data.write('\n');
        _data.write(value);
      }
    }
    return events;
  }

  /// 流结束时冲刷残留（容忍末尾没有空行的实现）。
  List<SseEvent> flush() {
    final rest = _pending.toString();
    _pending.clear();
    final events = <SseEvent>[];
    if (rest.isNotEmpty && !rest.startsWith(':')) {
      final line = rest.endsWith('\r') ? rest.substring(0, rest.length - 1) : rest;
      final sep = line.indexOf(':');
      if (sep > 0) {
        final field = line.substring(0, sep);
        var value = line.substring(sep + 1);
        if (field == 'data') {
          if (value.startsWith(' ')) value = value.substring(1);
          if (_data.isNotEmpty) _data.write('\n');
          _data.write(value);
        }
      }
    }
    _emitInto(events);
    return events;
  }

  void _emitInto(List<SseEvent> events) {
    if (_data.isEmpty) {
      _eventName = null;
      return;
    }
    events.add(SseEvent(event: _eventName, data: _data.toString()));
    _data.clear();
    _eventName = null;
  }
}

/// DeepSeek 流式增量
class DeepSeekDelta {
  const DeepSeekDelta({
    this.text = '',
    this.reasoning,
    this.usage,
    this.done = false,
  });

  final String text;

  /// reasoning 模型的思考链增量（可选保存）
  final String? reasoning;

  /// 最后一个带 usage 的 chunk
  final ChatUsage? usage;

  final bool done;
}

/// 把 SSE 事件流转换为 DeepSeek 增量（非法 JSON 静默跳过）。
class DeepSeekStreamParser {
  DeepSeekStreamParser({this.modelTag = 'deepseek-chat'});

  final String modelTag;
  final SseEventParser _sse = SseEventParser();

  List<DeepSeekDelta> add(String chunk) => _parseAll(_sse.add(chunk));

  List<DeepSeekDelta> flush() => _parseAll(_sse.flush());

  List<DeepSeekDelta> _parseAll(List<SseEvent> events) {
    final deltas = <DeepSeekDelta>[];
    for (final event in events) {
      final data = event.data.trim();
      if (data.isEmpty) continue;
      if (data == '[DONE]') {
        deltas.add(const DeepSeekDelta(done: true));
        continue;
      }
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map<String, dynamic>) continue;
        json = decoded;
      } catch (_) {
        continue; // 非法 chunk 容错
      }

      final choices = json['choices'];
      var text = '';
      String? reasoning;
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map<String, dynamic>) {
          final delta = first['delta'];
          if (delta is Map<String, dynamic>) {
            final content = delta['content'];
            if (content is String) text = content;
            final reasoningContent = delta['reasoning_content'];
            if (reasoningContent is String && reasoningContent.isNotEmpty) {
              reasoning = reasoningContent;
            }
          }
        }
      }

      ChatUsage? usage;
      final rawUsage = json['usage'];
      if (rawUsage is Map<String, dynamic>) {
        usage = ChatUsage(
          promptTokens: _intOf(rawUsage['prompt_tokens']),
          completionTokens: _intOf(rawUsage['completion_tokens']),
          reasoningTokens: _intOf(
            (rawUsage['completion_tokens_details']
                    as Map<String, dynamic>?)?['reasoning_tokens'],
          ),
        );
        usage = usage.withCost(DeepSeekPricing.estimate(modelTag, usage));
      }

      if (text.isEmpty && reasoning == null && usage == null) continue;
      deltas.add(DeepSeekDelta(
        text: text,
        reasoning: reasoning,
        usage: usage,
      ));
    }
    return deltas;
  }

  int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}

/// 将 HTTP 状态与响应体映射为 [ChatFailure]（供客户端与测试共用）。
ChatFailure failureFromStatus(int statusCode, String? body) =>
    classifyHttpFailure(statusCode, body);
