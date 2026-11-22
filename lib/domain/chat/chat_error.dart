// 聊天错误分类（T3.4）：纯函数层，统一落库 code 与用户可执行文案。
// 依据 REQUIREMENTS FR-NET-02 / FR-MDL-03 与 UI_INTERACTION_SPEC 原则
//（错误文案必须给出用户可执行的动作）。
library;

/// 错误类别（同时作为 messages.error_code 落库值）
abstract final class ChatErrorCodes {
  static const timeout = 'timeout';
  static const network = 'network';
  static const rateLimit = 'rate_limit';
  static const unauthorized = 'unauthorized';
  static const insufficientBalance = 'insufficient_balance';
  static const badRequest = 'bad_request';
  static const server = 'server';
  static const badResponse = 'bad_response';
  static const cancelled = 'cancelled';
  static const generationFailed = 'generation_failed';
  static const emptyReply = 'empty_reply';
  static const interrupted = 'interrupted';
  static const unknown = 'unknown';

  /// 可重试的错误（暂停/恢复后重试有意义）
  static const retryable = {
    timeout,
    network,
    rateLimit,
    server,
    badResponse,
    generationFailed,
    emptyReply,
    interrupted,
    unknown,
  };

  /// 需要用户去设置页处理、重试无效的错误
  static const needsUserAction = {
    unauthorized,
    insufficientBalance,
    badRequest,
  };
}

/// 网络/接口错误的标准异常：携带分类与用户文案。
class ChatFailure implements Exception {
  const ChatFailure(this.code, {this.detail, this.statusCode});

  final String code;
  final String? detail;
  final int? statusCode;

  bool get retryable => ChatErrorCodes.retryable.contains(code);
  bool get needsUserAction => ChatErrorCodes.needsUserAction.contains(code);

  /// 用户可执行文案
  String get userMessage {
    switch (code) {
      case ChatErrorCodes.timeout:
        return '网络超时，请检查网络后重试';
      case ChatErrorCodes.network:
        return '网络不可用，恢复网络后重试';
      case ChatErrorCodes.rateLimit:
        return '请求过于频繁（429），稍等片刻再试';
      case ChatErrorCodes.unauthorized:
        return 'API Key 无效或已失效，请到模型管理更新 Key';
      case ChatErrorCodes.insufficientBalance:
        return '账户余额不足，请到 DeepSeek 平台充值后重试';
      case ChatErrorCodes.badRequest:
        return '请求被模型拒绝，请检查模型参数或上下文长度';
      case ChatErrorCodes.server:
        return '模型服务暂时不可用，请稍后重试';
      case ChatErrorCodes.badResponse:
        return '模型返回内容无法解析，点按重试';
      case ChatErrorCodes.cancelled:
        return '已取消';
      case ChatErrorCodes.emptyReply:
        return '泡泡没有生成内容，点按重试';
      case ChatErrorCodes.interrupted:
        return '上次生成被中断，点按重试';
      default:
        return '生成失败，点按重试';
    }
  }

  @override
  String toString() =>
      'ChatFailure($code${statusCode == null ? '' : ', status=$statusCode'}'
      '${detail == null ? '' : ', detail=$detail'})';
}

/// 按 HTTP 状态码与响应体分类（纯函数，便于覆盖错误矩阵）。
ChatFailure classifyHttpFailure(int statusCode, String? body) {
  final text = (body ?? '').toLowerCase();
  switch (statusCode) {
    case 401:
      return ChatFailure(ChatErrorCodes.unauthorized,
          statusCode: statusCode, detail: body);
    case 402:
      return ChatFailure(ChatErrorCodes.insufficientBalance,
          statusCode: statusCode, detail: body);
    case 429:
      return ChatFailure(ChatErrorCodes.rateLimit,
          statusCode: statusCode, detail: body);
    case 400:
      // DeepSeek 在余额不足时也可能用 400 + insufficient balance 文案
      if (text.contains('insufficient') || text.contains('balance')) {
        return ChatFailure(ChatErrorCodes.insufficientBalance,
            statusCode: statusCode, detail: body);
      }
      return ChatFailure(ChatErrorCodes.badRequest,
          statusCode: statusCode, detail: body);
    default:
      if (statusCode >= 500) {
        return ChatFailure(ChatErrorCodes.server,
            statusCode: statusCode, detail: body);
      }
      return ChatFailure(ChatErrorCodes.badResponse,
          statusCode: statusCode, detail: body);
  }
}

/// 把任意生成异常归一到错误码（controller 落库用）。
String errorCodeOf(Object error) {
  if (error is ChatFailure) return error.code;
  if (error is FormatException) return ChatErrorCodes.badResponse;
  return ChatErrorCodes.generationFailed;
}

/// 错误码 → 用户文案（供消息气泡直接显示）
String chatErrorText(String? errorCode) {
  if (errorCode == null || errorCode.isEmpty) return '生成失败，点按重试';
  if (ChatErrorCodes.retryable.contains(errorCode) ||
      ChatErrorCodes.needsUserAction.contains(errorCode)) {
    return ChatFailure(errorCode).userMessage;
  }
  switch (errorCode) {
    case ChatErrorCodes.generationFailed:
      return '生成中断，点按重试';
    default:
      return '生成失败，点按重试';
  }
}
