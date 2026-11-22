// 上下文总装（T6.1）：人格块 + 常驻记忆 + 召回记忆 + 会话历史，预算裁剪与缓存友好排序。
// 依据 DEVELOPMENT_ROADMAP 阶段 6、MEMORY_DESIGN §4、ARCHITECTURE §4 上下文组装约定。
// 纯函数：不读写数据库；由 ChatContextAssembler 提供数据。
import '../chat/chat_provider.dart';
import '../memory/memory_context.dart';
import '../memory/memory_models.dart';

/// 组装结果（含审计统计，供调试面板展示）
class ContextBuildResult {
  const ContextBuildResult({
    required this.messages,
    required this.systemText,
    required this.systemTokens,
    required this.historyTokens,
    required this.totalTokens,
    required this.maxPromptTokens,
    required this.droppedTurns,
    required this.droppedRecall,
    required this.droppedStanding,
    required this.standingIds,
    required this.recallIds,
  });

  final List<ChatTurn> messages;
  final String systemText;
  final int systemTokens;
  final int historyTokens;
  final int totalTokens;
  final int maxPromptTokens;

  /// 因预算被裁掉的历史轮数
  final int droppedTurns;
  final bool droppedRecall;
  final bool droppedStanding;
  final List<String> standingIds;
  final List<String> recallIds;

  static const empty = ContextBuildResult(
    messages: <ChatTurn>[],
    systemText: '',
    systemTokens: 0,
    historyTokens: 0,
    totalTokens: 0,
    maxPromptTokens: 0,
    droppedTurns: 0,
    droppedRecall: false,
    droppedStanding: false,
    standingIds: <String>[],
    recallIds: <String>[],
  );
}

class ContextBuilder {
  const ContextBuilder._();

  /// 默认输入预算（token）；可由 app_settings 的 context_max_prompt_tokens 覆盖
  static const int defaultMaxPromptTokens = 8000;

  /// 系统块最多占预算的 70%，其余留给会话历史。
  static const double systemShare = 0.7;

  /// 组装上下文：
  /// 1) system 消息顺序固定为「人格 → 常驻记忆 → 召回记忆」（稳定前缀，缓存友好）；
  /// 2) 系统块超出预算份额时，先丢召回、再丢常驻；
  /// 3) 历史从最旧开始成对裁剪，永远保留最新一轮用户消息。
  static ContextBuildResult build({
    required String personaPrompt,
    required MemoryBlock standing,
    required MemoryBlock recall,
    required List<ChatTurn> history,
    int maxPromptTokens = defaultMaxPromptTokens,
  }) {
    var standingText = standing.text;
    var recallText = recall.text;
    var droppedStanding = false;
    var droppedRecall = false;

    var systemText = _compose(personaPrompt, standingText, recallText);
    var systemTokens = MemoryContextRenderer.estimateTokens(systemText);
    final systemCap = (maxPromptTokens * systemShare).floor();

    if (systemTokens > systemCap && recallText.isNotEmpty) {
      recallText = '';
      droppedRecall = true;
      systemText = _compose(personaPrompt, standingText, recallText);
      systemTokens = MemoryContextRenderer.estimateTokens(systemText);
    }
    if (systemTokens > systemCap && standingText.isNotEmpty) {
      standingText = '';
      droppedStanding = true;
      systemText = _compose(personaPrompt, standingText, recallText);
      systemTokens = MemoryContextRenderer.estimateTokens(systemText);
    }

    final turns = <ChatTurn>[...history];
    var historyTokens = _tokensOf(turns);
    var droppedTurns = 0;
    while (systemTokens + historyTokens > maxPromptTokens && turns.length > 1) {
      final remove = turns.length >= 2 &&
              turns[0].role == 'user' &&
              turns[1].role == 'assistant'
          ? 2
          : 1;
      if (turns.length - remove < 1) break;
      turns.removeRange(0, remove);
      droppedTurns += remove;
      historyTokens = _tokensOf(turns);
    }

    final system = systemText.trim();
    final messages = <ChatTurn>[
      if (system.isNotEmpty) ChatTurn(role: 'system', content: system),
      ...turns,
    ];
    return ContextBuildResult(
      messages: messages,
      systemText: system,
      systemTokens: systemTokens,
      historyTokens: historyTokens,
      totalTokens: systemTokens + historyTokens,
      maxPromptTokens: maxPromptTokens,
      droppedTurns: droppedTurns,
      droppedRecall: droppedRecall,
      droppedStanding: droppedStanding,
      standingIds: droppedStanding ? const <String>[] : standing.itemIds,
      recallIds: droppedRecall ? const <String>[] : recall.itemIds,
    );
  }

  static String _compose(
    String personaPrompt,
    String standingText,
    String recallText,
  ) {
    final buffer = StringBuffer();
    final persona = personaPrompt.trim();
    if (persona.isNotEmpty) buffer.write(persona);
    if (standingText.trim().isNotEmpty) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(standingText.trim());
    }
    if (recallText.trim().isNotEmpty) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(recallText.trim());
    }
    return buffer.toString();
  }

  static int _tokensOf(List<ChatTurn> turns) {
    var total = 0;
    for (final turn in turns) {
      total += MemoryContextRenderer.estimateTokens(turn.content) + 4;
    }
    return total;
  }
}
