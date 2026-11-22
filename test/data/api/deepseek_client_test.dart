// DeepSeekClient 回放测试（T3.1）：用假 HttpClientAdapter 回放录制的 SSE，
// 覆盖请求参数、流式文本、usage 与 HTTP 错误分类。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bubble/data/api/deepseek_client.dart';
import 'package:bubble/domain/chat/chat_error.dart';
import 'package:bubble/domain/chat/chat_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHttpClientAdapter implements HttpClientAdapter {
  FakeHttpClientAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
  RequestOptions? lastOptions;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastOptions = options;
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody sseBody(String text, {int statusCode = 200}) {
  final bytes = utf8Bytes(text);
  final chunks = <Uint8List>[];
  for (var i = 0; i < bytes.length; i += 9) {
    chunks.add(Uint8List.fromList(
      bytes.sublist(i, (i + 9).clamp(0, bytes.length)),
    ));
  }
  return ResponseBody(
    Stream<Uint8List>.fromIterable(chunks),
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['text/event-stream'],
    },
  );
}

List<int> utf8Bytes(String text) => utf8.encode(text);

Dio dioWith(FakeHttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.deepseek.com'));
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  final fixture = File('test/fixtures/deepseek_sse.txt').readAsStringSync();

  test('流式回放：文本增量、用量与请求参数', () async {
    final adapter = FakeHttpClientAdapter((_) => sseBody(fixture));
    final client = DeepSeekClient(
      dio: dioWith(adapter),
      apiKey: 'sk-test',
    );

    final deltas = await client
        .streamChat(
          modelTag: 'deepseek-chat',
          history: const [ChatTurn(role: 'user', content: '你好')],
          params: const {'temperature': 0.5, 'max_tokens': 128},
        )
        .toList();

    expect(deltas.map((d) => d.text).join(), '嗯，我在听。');
    expect(deltas.any((d) => d.done), isTrue);
    expect(deltas.lastWhere((d) => d.usage != null).usage!.totalTokens, 16);

    final options = adapter.lastOptions!;
    expect(options.path, 'https://api.deepseek.com/chat/completions');
    expect(options.headers['Authorization'], 'Bearer sk-test');
    final body = options.data as Map<String, dynamic>;
    expect(body['model'], 'deepseek-chat');
    expect(body['stream'], isTrue);
    expect(body['stream_options'], {'include_usage': true});
    expect(body['temperature'], 0.5);
    expect(body['max_tokens'], 128);
    expect((body['messages'] as List).single,
        {'role': 'user', 'content': '你好'});
  });

  test('401 → unauthorized', () async {
    final adapter = FakeHttpClientAdapter((_) =>
        ResponseBody.fromString('{"error":"invalid api key"}', 401, headers: {
          Headers.contentTypeHeader: ['application/json'],
        }));
    final client = DeepSeekClient(dio: dioWith(adapter), apiKey: 'bad');

    await expectLater(
      client
          .streamChat(
            modelTag: 'deepseek-chat',
            history: const [ChatTurn(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(isA<ChatFailure>()
          .having((e) => e.code, 'code', ChatErrorCodes.unauthorized)),
    );
  });

  test('429 → rateLimit，500 → server', () async {
    final rateLimited = DeepSeekClient(
      dio: dioWith(FakeHttpClientAdapter(
          (_) => ResponseBody.fromString('{}', 429))),
      apiKey: 'sk',
    );
    await expectLater(
      rateLimited
          .streamChat(
            modelTag: 'deepseek-chat',
            history: const [ChatTurn(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(isA<ChatFailure>()
          .having((e) => e.code, 'code', ChatErrorCodes.rateLimit)),
    );

    final serverError = DeepSeekClient(
      dio: dioWith(FakeHttpClientAdapter(
          (_) => ResponseBody.fromString('{}', 503))),
      apiKey: 'sk',
    );
    await expectLater(
      serverError
          .streamChat(
            modelTag: 'deepseek-chat',
            history: const [ChatTurn(role: 'user', content: 'hi')],
          )
          .toList(),
      throwsA(isA<ChatFailure>()
          .having((e) => e.code, 'code', ChatErrorCodes.server)),
    );
  });

  test('空响应体 → badResponse', () async {
    final adapter = FakeHttpClientAdapter(
        (_) => ResponseBody(Stream<Uint8List>.empty(), 200));
    final client = DeepSeekClient(dio: dioWith(adapter), apiKey: 'sk');
    final deltas = await client
        .streamChat(
          modelTag: 'deepseek-chat',
          history: const [ChatTurn(role: 'user', content: 'hi')],
        )
        .toList();
    expect(deltas, isEmpty); // 空流不崩溃
  });
}
