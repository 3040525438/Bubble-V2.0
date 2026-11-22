// 聊天提供方解析（T3.1/T3.3）：有默认模型且已配置 API Key 时用 DeepSeek，
// 否则回退开发回声并给出明确提示（禁止静默降级、禁止冒充真实模型）。
import 'package:dio/dio.dart';

import '../../data/api/deepseek_client.dart';
import '../../data/database/app_database.dart';
import '../../data/repositories/model_repository.dart';
import '../../domain/chat/chat_provider.dart';
import '../../domain/chat/echo_provider.dart';
import '../../domain/chat/deepseek_provider.dart';

class ResolvedChatProvider {
  const ResolvedChatProvider({
    required this.provider,
    this.model,
    this.notice,
  });

  final ChatCompletionProvider provider;
  final ModelRecord? model;

  /// 降级/提示文案（为空表示正常真实模型）
  final String? notice;
}

Future<ResolvedChatProvider> resolveChatProvider(ModelRepository models) async {
  await models.ensureSeed();
  final model = await models.defaultModel();
  if (model == null) {
    return const ResolvedChatProvider(
      provider: EchoProvider(),
      notice: '没有启用的模型 · 使用开发回声',
    );
  }

  final apiKey = await models.readApiKey(model);
  if (apiKey == null) {
    return ResolvedChatProvider(
      provider: const EchoProvider(),
      model: model,
      notice: '未配置 API Key · 使用开发回声',
    );
  }

  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    sendTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 90),
  ));
  final client = DeepSeekClient(
    dio: dio,
    apiKey: apiKey,
    baseUrl: model.apiBaseUrl ?? kDeepSeekDefaultBaseUrl,
  );
  final params = ModelParams.parse(model.params);

  return ResolvedChatProvider(
    provider: DeepSeekProvider(
      client: client,
      modelTag: model.modelTag,
      recordId: model.id,
      displayName: model.displayName,
      params: {
        'temperature': params.temperature,
        'max_tokens': params.maxTokens,
      },
    ),
    model: model,
  );
}
