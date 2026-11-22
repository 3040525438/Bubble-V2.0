// DeepSeek 聊天提供方（T3.1）：把 DeepSeekClient 适配为 ChatCompletionProvider。
// Token 用量与思考链在生成结束后可从 lastUsage / lastReasoning 读取，由控制器落库。
import '../../data/api/deepseek_client.dart';
import 'chat_provider.dart';
import 'chat_usage.dart';

class DeepSeekProvider implements ChatCompletionProvider {
  DeepSeekProvider({
    required this.client,
    required this.modelTag,
    this.recordId,
    this.params,
    String? displayName,
  }) : _displayName = displayName;

  final DeepSeekClient client;
  final String modelTag;
  final String? recordId;
  final Map<String, dynamic>? params;
  final String? _displayName;

  ChatUsage? _lastUsage;
  String? _lastReasoning;

  @override
  String get providerId => 'deepseek';

  @override
  String get displayName => _displayName ?? 'DeepSeek · $modelTag';

  @override
  bool get isMock => false;

  @override
  String? get modelId => recordId;

  @override
  ChatUsage? get lastUsage => _lastUsage;

  @override
  String? get lastReasoning => _lastReasoning;

  @override
  Stream<String> stream(List<ChatTurn> history) async* {
    _lastUsage = null;
    _lastReasoning = null;
    final reasoning = StringBuffer();
    await for (final delta in client.streamChat(
      modelTag: modelTag,
      history: history,
      params: params,
    )) {
      if (delta.reasoning != null) reasoning.write(delta.reasoning);
      if (delta.usage != null) _lastUsage = delta.usage;
      if (delta.text.isNotEmpty) yield delta.text;
    }
    if (reasoning.isNotEmpty) _lastReasoning = reasoning.toString();
  }
}
