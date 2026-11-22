// 思考编排器工厂（T7.2）：有真实模型时接结构化分析，否则纯本地规则（零成本）。
// 与聊天共用 provider 解析规则：无默认模型/无 Key 时明确回退，不冒充真实模型。
import 'dart:async';

import '../../domain/chat/chat_provider.dart';
import '../../domain/thinking/local_insight_scanner.dart';
import '../../domain/thinking/thinking_analyzer.dart';
import '../../presentation/chat/chat_provider_resolver.dart';
import '../database/app_database.dart';
import '../repositories/model_repository.dart';
import 'thinking_orchestrator.dart';

class ThinkingSetup {
  const ThinkingSetup({required this.orchestrator, this.notice});

  final ThinkingOrchestrator orchestrator;

  /// 降级说明（为空表示真实模型可用）
  final String? notice;
}

Future<ThinkingSetup> createThinkingSetup(AppDatabase db) async {
  ThinkingModelAnalyzer? analyzer;
  String? notice;
  try {
    final resolved = await resolveChatProvider(ModelRepository(db));
    notice = resolved.notice;
    if (!resolved.provider.isMock) {
      analyzer = ModelThinkingAnalyzer(
        caller: (system, user) => _complete(
          resolved.provider,
          system,
          user,
        ),
      );
    }
  } catch (_) {
    notice = '思考模型不可用 · 使用本地规则';
  }
  return ThinkingSetup(
    orchestrator: ThinkingOrchestrator(
      db,
      scanner: const LocalInsightScanner(),
      modelAnalyzer: analyzer,
    ),
    notice: notice,
  );
}

Future<String> _complete(
  ChatCompletionProvider provider,
  String system,
  String user,
) async {
  final buffer = StringBuffer();
  final stream = provider.stream([
    ChatTurn(role: 'system', content: system),
    ChatTurn(role: 'user', content: user),
  ]);
  await for (final chunk in stream.timeout(const Duration(seconds: 60))) {
    buffer.write(chunk);
  }
  return buffer.toString();
}
