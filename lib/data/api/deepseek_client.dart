// DeepSeek 流式客户端（T3.1）：dio + SSE。
// 依据 TECH_STACK §3.1：dio ResponseType.stream 逐块解析；
// 错误按 FR-NET-02 矩阵分类为 ChatFailure。
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/chat/chat_error.dart';
import '../../domain/chat/chat_provider.dart';
import '../../domain/chat/sse_parser.dart';

const kDeepSeekDefaultBaseUrl = 'https://api.deepseek.com';
const kDeepSeekDefaultModelTag = 'deepseek-chat';

class DeepSeekClient {
  DeepSeekClient({
    required Dio dio,
    required this.apiKey,
    this.baseUrl = kDeepSeekDefaultBaseUrl,
  }) : _dio = dio;

  final Dio _dio;
  final String apiKey;
  final String baseUrl;

  /// 流式对话：返回增量（文本/思考链/用量）。
  /// 取消订阅会取消底层请求（CancelToken）。
  Stream<DeepSeekDelta> streamChat({
    required String modelTag,
    required List<ChatTurn> history,
    Map<String, dynamic>? params,
  }) async* {
    final cancelToken = CancelToken();
    final parser = DeepSeekStreamParser(modelTag: modelTag);

    final body = <String, dynamic>{
      'model': modelTag,
      'messages': [for (final turn in history) _messageJson(turn)],
      'stream': true,
      'stream_options': {'include_usage': true},
      ...?params,
    };

    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        '$baseUrl/chat/completions',
        data: body,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Accept': 'text/event-stream',
            'Content-Type': 'application/json',
          },
        ),
      );
    } on DioException catch (error) {
      throw _mapDioError(error);
    }

    final data = response.data;
    if (data == null) {
      throw const ChatFailure(ChatErrorCodes.badResponse, detail: '响应体为空');
    }

    try {
      await for (final chunk
          in data.stream.cast<List<int>>().transform(utf8.decoder)) {
        for (final delta in parser.add(chunk)) {
          yield delta;
        }
      }
      for (final delta in parser.flush()) {
        yield delta;
      }
    } on DioException catch (error) {
      throw _mapDioError(error);
    } finally {
      if (!cancelToken.isCancelled) {
        // 流正常结束或异常后释放底层连接
        cancelToken.cancel('stream finished');
      }
    }
  }

  /// 单条消息体：带图片时按 OpenAI 兼容多模态格式（text + image_url data URL）。
  Map<String, dynamic> _messageJson(ChatTurn turn) {
    if (turn.images.isEmpty) {
      return {'role': turn.role, 'content': turn.content};
    }
    final text = turn.content.trim();
    return {
      'role': turn.role,
      'content': [
        if (text.isNotEmpty) {'type': 'text', 'text': turn.content},
        for (final image in turn.images)
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:${image.mime};base64,${base64Encode(image.bytes)}',
            },
          },
      ],
    };
  }

  ChatFailure _mapDioError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return const ChatFailure(ChatErrorCodes.timeout);
      case DioExceptionType.connectionError:
        return ChatFailure(ChatErrorCodes.network, detail: error.message);
      case DioExceptionType.cancel:
        return const ChatFailure(ChatErrorCodes.cancelled);
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode ?? 0;
        return classifyHttpFailure(status, _bodyPreview(error.response));
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return ChatFailure(ChatErrorCodes.network, detail: error.message);
    }
  }

  /// 错误响应体（流式响应的 body 可能是流，取不到内容时返回 null）
  String? _bodyPreview(Response<dynamic>? response) {
    final body = response?.data;
    if (body == null) return null;
    if (body is String) return body.length > 500 ? body.substring(0, 500) : body;
    return null;
  }
}
