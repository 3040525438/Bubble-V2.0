// 上下文调试预览（T6.2）：展示人格块 + 常驻/召回记忆 + 会话历史的总装结果与预算统计。
import 'package:flutter/material.dart';

import '../../data/context/chat_context_assembler.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../domain/chat/chat_provider.dart';
import '../../domain/context/context_builder.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class ContextPreviewPage extends StatefulWidget {
  const ContextPreviewPage({
    super.key,
    this.conversationId,
    this.assembler,
    this.conversationRepository,
  });

  final String? conversationId;
  final ChatContextAssembler? assembler;
  final ConversationRepository? conversationRepository;

  @override
  State<ContextPreviewPage> createState() => _ContextPreviewPageState();
}

class _ContextPreviewPageState extends State<ContextPreviewPage> {
  late final ConversationRepository _repo =
      widget.conversationRepository ?? ConversationRepository(AppDb.instance);
  late final ChatContextAssembler _assembler =
      widget.assembler ?? ChatContextAssembler(AppDb.instance);
  final TextEditingController _queryController = TextEditingController();

  String? _conversationId;
  String _conversationTitle = '';
  List<ChatTurn> _history = const <ChatTurn>[];
  ContextBuildResult? _result;
  bool _loading = true;
  bool _assembling = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final conversations = await _repo.listConversations();
      final id = widget.conversationId ??
          (conversations.isEmpty ? null : conversations.first.id);
      var history = const <ChatTurn>[];
      var title = '';
      if (id != null) {
        final messages = await _repo.messages(id);
        history = [
          for (final message in messages)
            if ((message.role == 'user' || message.role == 'assistant') &&
                message.content.trim().isNotEmpty)
              ChatTurn(role: message.role, content: message.content),
        ];
        title = '';
        for (final conversation in conversations) {
          if (conversation.id == id) {
            title = conversation.title;
            break;
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _conversationId = id;
        _conversationTitle = title;
        _history = history;
        _loading = false;
      });
      _queryController.text = _lastUser(history);
      await _assemble();
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _assemble() async {
    final query = _queryController.text.trim();
    var history = _history;
    if (query.isNotEmpty && _lastUser(history) != query) {
      history = [...history, ChatTurn(role: 'user', content: query)];
    }
    setState(() => _assembling = true);
    try {
      final result =
          await _assembler.assemble(history, latestQuery: query);
      if (!mounted) return;
      setState(() {
        _result = result;
        _assembling = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _assembling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('上下文预览'),
        actions: [
          IconButton(
            tooltip: '重新组装',
            onPressed: _assembling ? null : _assemble,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
              children: [
                _conversationCard(),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryController,
                        decoration: const InputDecoration(
                          hintText: '按这句话预览召回（可留空）',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _assemble(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _assembling ? null : _assemble,
                      child: Text(_assembling ? '组装中' : '组装'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (result != null) ...[
                  _statsCard(result),
                  const SizedBox(height: 10),
                  _sectionTitle('System 消息（提示词 + 记忆块）'),
                  const SizedBox(height: 6),
                  _systemCard(result),
                  const SizedBox(height: 10),
                  _sectionTitle('会话历史 · ${result.messages.length - 1} 条'
                      '${result.droppedTurns > 0 ? '（已裁 ${result.droppedTurns}）' : ''}'),
                  const SizedBox(height: 6),
                  _historyList(result),
                  const SizedBox(height: 10),
                  const MemoryLockBar('调试面板仅本地展示 · 不发送、不落库 · 预算可在 app_settings 调整'),
                ],
              ],
            ),
    );
  }

  Widget _conversationCard() {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Row(
        children: [
          Icon(Icons.chat_bubble_outline_rounded,
              size: 18, color: semantic.lavenderDeep),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _conversationId == null
                  ? '还没有会话 · 输入一句话做空上下文预览'
                  : '当前会话：${_conversationTitle.isEmpty ? _conversationId : _conversationTitle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: BubbleFontSize.secondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statsCard(ContextBuildResult result) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final chips = <String>[
      '总 ${result.totalTokens}/${result.maxPromptTokens} token',
      '系统 ${result.systemTokens}',
      '历史 ${result.historyTokens}',
      '常驻 ${result.standingIds.length} 条',
      '召回 ${result.recallIds.length} 条',
      if (result.droppedTurns > 0) '裁剪 ${result.droppedTurns} 轮',
      if (result.droppedRecall) '召回已让位',
      if (result.droppedStanding) '常驻已让位',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final chip in chips)
            MemoryBadge(
              text: chip,
              color: onSurface.withValues(alpha: 0.7),
              background: semantic.surfaceAlt,
            ),
        ],
      ),
    );
  }

  Widget _systemCard(ContextBuildResult result) {
    final semantic = context.bubbleColors;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 360),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          result.systemText.isEmpty ? '（空上下文）' : result.systemText,
          style: const TextStyle(
            fontSize: BubbleFontSize.badge,
            height: 1.7,
          ),
        ),
      ),
    );
  }

  Widget _historyList(ContextBuildResult result) {
    final semantic = context.bubbleColors;
    final turns = result.messages.where((m) => m.role != 'system').toList();
    if (turns.isEmpty) {
      return const MemoryEmptyCard(
        title: '没有可预览的历史',
        subtitle: '去聊几句，或在上面输入一句话生成合成查询。',
      );
    }
    return Column(
      children: [
        for (final turn in turns)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(BubbleRadius.card),
              border: Border.all(color: semantic.stroke),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MemoryBadge(
                  text: turn.role == 'user' ? '你' : '泡泡',
                  color: turn.role == 'user'
                      ? semantic.bubbleUserA
                      : semantic.lavenderDeep,
                  background: (turn.role == 'user'
                          ? semantic.bubbleUserA
                          : semantic.lavender)
                      .withValues(alpha: 0.13),
                ),
                const SizedBox(height: 5),
                Text(
                  turn.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: BubbleFontSize.badge, height: 1.55),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Text(
        text,
        style: TextStyle(
          fontSize: BubbleFontSize.cardTitle,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      );

  static String _lastUser(List<ChatTurn> history) {
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].role == 'user') return history[i].content;
    }
    return '';
  }
}
