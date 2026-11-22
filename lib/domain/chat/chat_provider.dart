// 聊天补全提供方抽象：阶段 2 有开发用 EchoProvider；阶段 3 接入 DeepSeek 流式实现。
// 交付前必须移除 EchoProvider（ROADMAP 阶段 2/3）。
import 'dart:typed_data';

import 'chat_usage.dart';

/// 随消息发送的图片（阶段 12）：vision 模型按 OpenAI 兼容格式转 data URL。
class ChatImagePart {
  const ChatImagePart({required this.mime, required this.bytes});

  final String mime;
  final Uint8List bytes;
}

/// 一轮对话（发送给模型的历史消息，去掉 UI/DB 细节）
class ChatTurn {
  const ChatTurn({
    required this.role,
    required this.content,
    this.images = const [],
  });

  /// user / assistant / system
  final String role;
  final String content;

  /// 本轮附带的图片（仅最后一条用户消息、且模型支持视觉时才会带）
  final List<ChatImagePart> images;
}

/// 聊天补全提供方：以流式增量文本返回回复。
abstract class ChatCompletionProvider {
  const ChatCompletionProvider();

  /// 提供方标识（落库/调试用）
  String get providerId;

  /// 展示名（UI 提示用）
  String get displayName;

  /// 是否为开发用假模型（UI 必须显著标注，禁止冒充真实功能）
  bool get isMock;

  /// 是否支持图片理解（FR-IMG-02：不支持时必须明确提示，不得假装支持）
  bool get supportsVision => false;

  /// 关联的 models 表记录 id（真实模型才有）
  String? get modelId => null;

  /// 最近一次生成的用量（生成结束后可读；假模型为 null）
  ChatUsage? get lastUsage => null;

  /// 最近一次生成的思考链（DeepSeek reasoner 才有）
  String? get lastReasoning => null;

  /// 流式生成。取消订阅即中止生成（调用方负责取消）。
  Stream<String> stream(List<ChatTurn> history);
}
