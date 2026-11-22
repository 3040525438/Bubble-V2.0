// 模型用量（T3.2）：Token 与费用估算的值对象（domain 纯数据）。
library;

/// 一次调用的用量（DeepSeek 返回的 usage + 本地估算费用）
class ChatUsage {
  const ChatUsage({
    required this.promptTokens,
    required this.completionTokens,
    this.reasoningTokens = 0,
    this.costEst = 0,
  });

  final int promptTokens;
  final int completionTokens;

  /// DeepSeek reasoning 模型的思考 token（completion_tokens_details.reasoning_tokens）
  final int reasoningTokens;

  /// 估算费用（人民币元）
  final double costEst;

  int get totalTokens => promptTokens + completionTokens;

  ChatUsage withCost(double cost) => ChatUsage(
        promptTokens: promptTokens,
        completionTokens: completionTokens,
        reasoningTokens: reasoningTokens,
        costEst: cost,
      );

  Map<String, Object?> toJson() => {
        'prompt_tokens': promptTokens,
        'completion_tokens': completionTokens,
        'reasoning_tokens': reasoningTokens,
        'cost_est': costEst,
      };
}

/// 价格表（人民币元 / 百万 tokens）。集中在此，官方调整价格时只需改这里。
/// 依据 DeepSeek 官方价目（deepseek-chat 输入 ¥2 / 输出 ¥8；deepseek-reasoner 输入 ¥4 / 输出 ¥16）。
class DeepSeekPricing {
  const DeepSeekPricing._();

  static const _inputPerMillion = 2.0;
  static const _outputPerMillion = 8.0;

  static double estimate(String modelTag, ChatUsage usage) {
    final isReasoner = modelTag.contains('reasoner');
    final input = isReasoner ? 4.0 : _inputPerMillion;
    final output = isReasoner ? 16.0 : _outputPerMillion;
    return usage.promptTokens / 1000000 * input +
        usage.completionTokens / 1000000 * output;
  }
}
