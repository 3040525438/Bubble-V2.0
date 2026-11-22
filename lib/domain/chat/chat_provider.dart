// 聊天补全提供方抽象（T2.4 前置）：阶段 2 只有开发用 EchoProvider；
// 阶段 3 接入 DeepSeek 真实流式实现，交付前移除 EchoProvider（ROADMAP 阶段2）。
library;

/// 一轮对话（发送给模型的历史消息，去掉 UI/DB 细节）
class ChatTurn {
  const ChatTurn({required this.role, required this.content});

  /// user / assistant / system
  final String role;
  final String content;
}

/// 聊天补全提供方：以流式增量文本返回回复。
abstract class ChatCompletionProvider {
  /// 提供方标识（落库/调试用）
  String get providerId;

  /// 展示名（UI 提示用）
  String get displayName;

  /// 是否为开发用假模型（UI 必须显著标注，禁止冒充真实功能）
  bool get isMock;

  /// 流式生成。取消订阅即中止生成（调用方负责取消）。
  Stream<String> stream(List<ChatTurn> history);
}
