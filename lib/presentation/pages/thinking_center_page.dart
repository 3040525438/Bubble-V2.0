// 思考中心（T7.3）：让泡泡想想、想法史、任务记录与中断恢复入口。
// 依据 AUTONOMOUS_SYSTEM §1；本页只产生想法与候选，主动发送由阶段 8 决策中心执行。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/thinking_repository.dart';
import '../../data/thinking/thinking_factory.dart';
import '../../data/thinking/thinking_orchestrator.dart';
import '../../domain/thinking/thinking_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class ThinkingCenterPage extends StatefulWidget {
  const ThinkingCenterPage({
    super.key,
    this.orchestrator,
    this.repository,
  });

  final ThinkingOrchestrator? orchestrator;
  final ThinkingRepository? repository;

  @override
  State<ThinkingCenterPage> createState() => _ThinkingCenterPageState();
}

class _ThinkingCenterPageState extends State<ThinkingCenterPage> {
  ThinkingOrchestrator? _orchestrator;
  late final ThinkingRepository _repo =
      widget.repository ?? ThinkingRepository(AppDb.instance);

  List<ThinkingTask> _tasks = const <ThinkingTask>[];
  List<ThinkingTask> _resumable = const <ThinkingTask>[];
  List<ThinkingResult> _results = const <ThinkingResult>[];
  int _candidateCount = 0;
  String? _notice;
  bool _loading = true;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _orchestrator = widget.orchestrator;
    if (_orchestrator == null) {
      try {
        final setup = await createThinkingSetup(AppDb.instance);
        _orchestrator = setup.orchestrator;
        _notice = setup.notice;
      } catch (error) {
        _notice = '思考模块初始化失败：$error';
      }
    }
    await _reload();
  }

  Future<void> _reload() async {
    final tasks = await _repo.listTasks(limit: 10);
    final resumable = await _repo.resumableTasks();
    final results = await _repo.listResults(limit: 20);
    final candidates = await _repo.listCandidates();
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _resumable = resumable;
      _results = results;
      _candidateCount = candidates.length;
      _loading = false;
    });
  }

  Future<void> _run() async {
    final orchestrator = _orchestrator;
    if (orchestrator == null || _running) return;
    setState(() => _running = true);
    try {
      final result = await orchestrator.runNew(
        trigger: ThinkingTrigger.manual,
      );
      if (!mounted) return;
      setState(() => _running = false);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(result.state == ThinkingState.done
              ? '想完了：${result.insightCount} 个念头，${result.candidateCount} 个候选'
              : '思考未完成：${result.error ?? result.state.label}'),
          behavior: SnackBarBehavior.floating,
        ));
    } catch (error) {
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('思考失败：$error')));
    }
  }

  Future<void> _recover() async {
    final orchestrator = _orchestrator;
    if (orchestrator == null || _running) return;
    setState(() => _running = true);
    try {
      final results = await orchestrator.recoverInterrupted();
      if (!mounted) return;
      setState(() => _running = false);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text('已恢复 ${results.length} 个未完成任务'),
          behavior: SnackBarBehavior.floating,
        ));
    } catch (error) {
      if (!mounted) return;
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('泡泡的思考'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _running ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
              children: [
                if (_notice != null) ...[
                  MemoryLockBar(_notice!),
                  const SizedBox(height: 10),
                ],
                _heroCard(),
                const SizedBox(height: 12),
                if (_resumable.isNotEmpty) ...[
                  _resumeCard(),
                  const SizedBox(height: 10),
                ],
                _statsRow(),
                const SizedBox(height: 12),
                if (_tasks.isNotEmpty) ...[
                  _sectionTitle('最近任务'),
                  const SizedBox(height: 6),
                  _taskCard(_tasks.first),
                  const SizedBox(height: 12),
                ],
                _sectionTitle('最近的想法'),
                const SizedBox(height: 6),
                if (_results.isEmpty)
                  const MemoryEmptyCard(
                    title: '还没有想法',
                    subtitle: '点上面的按钮，让泡泡安静地回顾一会儿。',
                  )
                else
                  for (final result in _results) ...[
                    _resultCard(result),
                    const SizedBox(height: 8),
                  ],
                const SizedBox(height: 4),
                _sectionTitle('任务记录'),
                const SizedBox(height: 6),
                if (_tasks.isEmpty)
                  const MemoryEmptyCard(
                    title: '还没有思考记录',
                    subtitle: '每次思考都会留下状态与结果，可随时回看。',
                  )
                else
                  for (final task in _tasks) ...[
                    _taskRow(task),
                    const SizedBox(height: 6),
                  ],
                const SizedBox(height: 10),
                const MemoryLockBar('思考只产生想法与候选 · 主动发送由阶段 8 决策中心统一执行'),
              ],
            ),
    );
  }

  Widget _heroCard() {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            semantic.lavender.withValues(alpha: 0.36),
            semantic.bubbleUserB.withValues(alpha: 0.24),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '让泡泡想想',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '不打扰你，只回顾聊天、记忆与约定，整理出她自己的念头。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.55,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.62),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _running || _orchestrator == null ? null : _run,
              icon: _running
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.psychology_rounded, size: 19),
              label: Text(_running ? '正在想…' : '开始思考'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resumeCard() {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: semantic.warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.warn),
      ),
      child: Row(
        children: [
          Icon(Icons.restore_rounded, size: 19, color: semantic.warnDeep),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '有 ${_resumable.length} 个未完成的思考，可从检查点继续',
              style: const TextStyle(fontSize: BubbleFontSize.badge),
            ),
          ),
          TextButton(
            onPressed: _running ? null : _recover,
            child: const Text('恢复'),
          ),
        ],
      ),
    );
  }

  Widget _statsRow() {
    final semantic = context.bubbleColors;
    final chips = <(String, int, Color)>[
      ('想法', _results.length, semantic.lavenderDeep),
      ('候选', _candidateCount, semantic.pinkDeep),
      ('未完成', _resumable.length, semantic.warnDeep),
    ];
    return Row(
      children: [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
              decoration: BoxDecoration(
                color: semantic.surfaceAlt.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(BubbleRadius.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${chips[i].$2}',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: chips[i].$3,
                    ),
                  ),
                  Text(
                    chips[i].$1,
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _taskCard(ThinkingTask task) {
    final semantic = context.bubbleColors;
    final state = ThinkingState.fromWire(task.state);
    final color = state == ThinkingState.done
        ? semantic.successDeep
        : state == ThinkingState.failed
            ? semantic.dangerDeep
            : semantic.warnDeep;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    MemoryBadge(
                      text: state.label,
                      color: color,
                      background: color.withValues(alpha: 0.13),
                    ),
                    const SizedBox(width: 6),
                    MemoryBadge(
                      text: ThinkingTrigger.values
                          .firstWhere(
                            (t) => t.wire == task.trigger,
                            orElse: () => ThinkingTrigger.manual,
                          )
                          .label,
                      color: semantic.lavenderDeep,
                      background:
                          semantic.lavender.withValues(alpha: 0.13),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  '${task.resultCount} 条想法 · ${formatMemoryDateTime(_msToIso(task.startedAt))}',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.5),
                  ),
                ),
                if ((task.scopeNote ?? '').isNotEmpty && state == ThinkingState.failed)
                  Text(
                    task.scopeNote!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: semantic.dangerDeep,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _taskRow(ThinkingTask task) {
    final semantic = context.bubbleColors;
    final state = ThinkingState.fromWire(task.state);
    final color = state == ThinkingState.done
        ? semantic.successDeep
        : state == ThinkingState.failed
            ? semantic.dangerDeep
            : semantic.warnDeep;
    return Row(
      children: [
        MemoryBadge(
          text: state.label,
          color: color,
          background: color.withValues(alpha: 0.12),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            ThinkingTrigger.values
                .firstWhere(
                  (t) => t.wire == task.trigger,
                  orElse: () => ThinkingTrigger.manual,
                )
                .label,
            style: const TextStyle(fontSize: BubbleFontSize.badge),
          ),
        ),
        Text(
          formatMemoryDateTime(_msToIso(task.startedAt)),
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }

  Widget _resultCard(ThinkingResult result) {
    final semantic = context.bubbleColors;
    final kind = ThinkingResultKind.fromWire(result.resultKind);
    final (icon, color) = _kindStyle(kind, semantic);
    final relatedIds = _decodeIds(result.relatedMemoryIds);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: relatedIds.isEmpty
            ? null
            : () => context.push('/memory/detail/${relatedIds.first}'),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BubbleRadius.card),
            border: Border.all(color: semantic.stroke),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 6),
                  MemoryBadge(
                    text: kind.label,
                    color: color,
                    background: color.withValues(alpha: 0.12),
                  ),
                  const Spacer(),
                  Text(
                    formatMemoryDateTime(result.createdAt),
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.35),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                result.content,
                style: const TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  height: 1.6,
                ),
              ),
              if (relatedIds.isNotEmpty) ...[
                const SizedBox(height: 6),
                MemoryBadge(
                  text: '关联记忆',
                  color: semantic.lavenderDeep,
                  background: semantic.lavender.withValues(alpha: 0.12),
                ),
              ],
            ],
          ),
        ),
      ),
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

  static (IconData, Color) _kindStyle(
      ThinkingResultKind kind, BubbleSemanticColors semantic) {
    switch (kind) {
      case ThinkingResultKind.newConnection:
        return (Icons.link_rounded, semantic.lavenderDeep);
      case ThinkingResultKind.reunderstanding:
        return (Icons.psychology_alt_rounded, semantic.bubbleUserB);
      case ThinkingResultKind.topicWorthContinuing:
        return (Icons.chat_bubble_outline_rounded, semantic.successDeep);
      case ThinkingResultKind.shareWorthy:
        return (Icons.favorite_border_rounded, semantic.pinkDeep);
      case ThinkingResultKind.diaryMaterial:
        return (Icons.menu_book_outlined, semantic.warnDeep);
      case ThinkingResultKind.quiet:
        return (Icons.nightlight_outlined, semantic.mist);
    }
  }

  static String _msToIso(int? ms) {
    if (ms == null) return '';
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
        .toIso8601String();
  }

  static List<String> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const <String>[];
    }
  }
}
