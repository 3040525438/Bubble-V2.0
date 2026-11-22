// 聊天上下文数据装配（T6.1）：把人格快照与记忆两条通道喂给 ContextBuilder。
// 数据库异常由调用方回退到原始历史（聊天永不因上下文失败而不可用）。
import '../../domain/chat/chat_provider.dart';
import '../../domain/context/context_builder.dart';
import '../../domain/memory/memory_models.dart';
import '../database/app_database.dart';
import '../repositories/memory_repository.dart';
import '../repositories/persona_repository.dart';

class ChatContextAssembler {
  ChatContextAssembler(
    this._db, {
    PersonaRepository? personaRepository,
    MemoryRepository? memoryRepository,
    int? maxPromptTokens,
  })  : _persona = personaRepository ?? PersonaRepository(_db),
        _memory = memoryRepository ?? MemoryRepository(_db),
        _maxPromptTokens = maxPromptTokens;

  final AppDatabase _db;
  final PersonaRepository _persona;
  final MemoryRepository _memory;
  final int? _maxPromptTokens;

  static const budgetKey = 'context_max_prompt_tokens';

  /// 组装完整上下文；[latestQuery] 为空时取历史最后一条用户消息作为召回查询。
  Future<ContextBuildResult> assemble(
    List<ChatTurn> history, {
    String? latestQuery,
  }) async {
    final profile = await _persona.profile();
    var personaPrompt = profile.coreSystemPrompt ?? '';
    if (personaPrompt.trim().isEmpty) {
      personaPrompt = await _persona.rebuildPromptSnapshot();
    }

    final query = (latestQuery ?? _lastUserText(history)).trim();
    final standing = await _memory.standingBlock();
    final recall = query.isEmpty
        ? MemoryBlock.empty
        : await _memory.recallBlock(query);
    final budget = _maxPromptTokens ?? await _readBudget();

    return ContextBuilder.build(
      personaPrompt: personaPrompt,
      standing: standing,
      recall: recall,
      history: history,
      maxPromptTokens: budget,
    );
  }

  /// 控制器直接消费的消息列表
  Future<List<ChatTurn>> assembleMessages(List<ChatTurn> history) async {
    final result = await assemble(history);
    return result.messages;
  }

  Future<int> _readBudget() async {
    final row = await (_db.select(_db.appSettings)
          ..where((t) => t.key.equals(budgetKey)))
        .getSingleOrNull();
    final parsed = int.tryParse(row?.value ?? '');
    if (parsed == null || parsed < 500) {
      return ContextBuilder.defaultMaxPromptTokens;
    }
    return parsed;
  }

  static String _lastUserText(List<ChatTurn> history) {
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].role == 'user') return history[i].content;
    }
    return '';
  }
}
