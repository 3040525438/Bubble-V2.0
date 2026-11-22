// 错误分类单测（T3.4）：错误矩阵与用户可执行文案。
import 'package:bubble/domain/chat/chat_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('classifyHttpFailure', () {
    test('401 鉴权失败不可重试且需要用户处理', () {
      final failure = classifyHttpFailure(401, 'invalid api key');
      expect(failure.code, ChatErrorCodes.unauthorized);
      expect(failure.retryable, isFalse);
      expect(failure.needsUserAction, isTrue);
      expect(failure.userMessage, contains('API Key'));
    });

    test('402 余额不足', () {
      expect(classifyHttpFailure(402, 'insufficient balance').code,
          ChatErrorCodes.insufficientBalance);
    });

    test('400 + insufficient 文案识别为余额不足', () {
      expect(
        classifyHttpFailure(400, '{"error":{"message":"Insufficient Balance"}}')
            .code,
        ChatErrorCodes.insufficientBalance,
      );
      expect(
        classifyHttpFailure(400, '{"error":{"message":"invalid params"}}').code,
        ChatErrorCodes.badRequest,
      );
    });

    test('429 限流可重试', () {
      final failure = classifyHttpFailure(429, 'rate limit');
      expect(failure.code, ChatErrorCodes.rateLimit);
      expect(failure.retryable, isTrue);
      expect(failure.userMessage, contains('429'));
    });

    test('5xx 服务端错误可重试', () {
      final failure = classifyHttpFailure(503, 'unavailable');
      expect(failure.code, ChatErrorCodes.server);
      expect(failure.retryable, isTrue);
    });

    test('其他 4xx 视为响应异常', () {
      expect(classifyHttpFailure(404, null).code, ChatErrorCodes.badResponse);
    });
  });

  group('errorCodeOf', () {
    test('ChatFailure 保留自身分类', () {
      expect(
        errorCodeOf(const ChatFailure(ChatErrorCodes.timeout)),
        ChatErrorCodes.timeout,
      );
    });

    test('FormatException 归类为响应异常，未知异常归为生成失败', () {
      expect(errorCodeOf(const FormatException('bad')), ChatErrorCodes.badResponse);
      expect(errorCodeOf(StateError('x')), ChatErrorCodes.generationFailed);
    });
  });

  test('所有错误码都有非空用户文案', () {
    for (final code in {
      ChatErrorCodes.timeout,
      ChatErrorCodes.network,
      ChatErrorCodes.rateLimit,
      ChatErrorCodes.unauthorized,
      ChatErrorCodes.insufficientBalance,
      ChatErrorCodes.badRequest,
      ChatErrorCodes.server,
      ChatErrorCodes.badResponse,
      ChatErrorCodes.cancelled,
      ChatErrorCodes.emptyReply,
      ChatErrorCodes.interrupted,
      ChatErrorCodes.generationFailed,
      ChatErrorCodes.unknown,
    }) {
      expect(chatErrorText(code), isNotEmpty, reason: code);
    }
  });

  test('需要用户处理的错误文案包含行动指引', () {
    expect(chatErrorText(ChatErrorCodes.unauthorized), contains('模型管理'));
    expect(chatErrorText(ChatErrorCodes.insufficientBalance), contains('充值'));
  });
}
