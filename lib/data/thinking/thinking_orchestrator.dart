// 思考编排器（T7.2）：八步流程 + 每步检查点 + 中断恢复。
// 流程：loading → reviewing → analyzing（本地 + 可选模型）→ saving → deciding → done。
// 依据 AUTONOMOUS_SYSTEM §1.1；引用校验失败的想法不入候选（FR-PRO 防伪原则）。
import 'dart:convert';
import 'dart:math';

import '../../domain/memory/memory_models.dart';
import '../../domain/thinking/local_insight_scanner.dart';
import '../../domain/thinking/thinking_analyzer.dart';
import '../../domain/thinking/thinking_models.dart';
import '../../domain/thinking/thinking_state_machine.dart';
import '../database/app_database.dart';
import '../repositories/conversation_repository.dart';
import '../repositories/memory_repository.dart';
import '../repositories/persona_repository.dart';
import '../repositories/thinking_repository.dart';

class ThinkingOrchestrator {
  ThinkingOrchestrator(
    AppDatabase db, {
    ThinkingRepository? repository,
    ConversationRepository? conversations,
    MemoryRepository? memories,
    PersonaRepository? personas,
    this.scanner = const LocalInsightScanner(),
    this.modelAnalyzer,
    DateTime Function()? now,
  })  : _repo = repository ?? ThinkingRepository(db),
        _conversations = conversations ?? ConversationRepository(db),
        _memories = memories ?? MemoryRepository(db),
        _personas = personas ?? PersonaRepository(db),
        _now = now ?? DateTime.now;

  final ThinkingRepository _repo;
  final ConversationRepository _conversations;
  final MemoryRepository _memories;
  final PersonaRepository _personas;
  final LocalInsightScanner scanner;
  final ThinkingModelAnalyzer? modelAnalyzer;
  final DateTime Function() _now;

  static const int maxInsights = 8;
  static const int maxNewMessages = 40;
  static const int maxSampledMessages = 12;
  static const int candidateTtlHours = 48;

  ThinkingRepository get repository => _repo;

  int get _nowMs => _now().toUtc().millisecondsSinceEpoch;

  String get _nowIso => _now().toUtc().toIso8601String();

  // ------------------------------------------------------------ 对外入口

  Future<ThinkingTask> start({
    required ThinkingTrigger trigger,
    String? scopeNote,
  }) {
    return _repo.createTask(
      trigger: trigger.wire,
      initialState: 'loading',
      scopeNote: scopeNote,
    );
  }

  /// 手动/定时触发一轮思考并跑完
  Future<ThinkingRunResult> runNew({
    required ThinkingTrigger trigger,
    String? scopeNote,
  }) async {
    final task = await start(trigger: trigger, scopeNote: scopeNote);
    return run(task.id);
  }

  /// 从任意状态/检查点续跑
  Future<ThinkingRunResult> run(String taskId) async {
    var task = await _repo.getTask(taskId);
    if (task == null) {
      throw ArgumentError('思考任务不存在：$taskId');
    }
    var checkpoint =
        ThinkingCheckpoint.fromJson(_decodeMap(task.checkpoint));
    var state = ThinkingState.fromWire(task.state);
    if (state == ThinkingState.interrupted) {
      state = ThinkingStateMachine.resumeTarget(checkpoint);
    }
    if (state == ThinkingState.done) {
      return ThinkingRunResult(
        taskId: taskId,
        state: ThinkingState.done,
        insightCount: checkpoint.insights.length,
        candidateCount: checkpoint.candidateCount,
      );
    }
    if (state == ThinkingState.failed) {
      return ThinkingRunResult(
        taskId: taskId,
        state: ThinkingState.failed,
        insightCount: checkpoint.insights.length,
        candidateCount: checkpoint.candidateCount,
        error: checkpoint.error ?? task.scopeNote,
      );
    }

    try {
      for (var guard = 0; guard < 12; guard++) {
        switch (state) {
          case ThinkingState.created:
          case ThinkingState.loading:
            checkpoint = ThinkingCheckpoint(
              step: 'loading',
              reviewedUntilMs: task.reviewedUntil ?? checkpoint.reviewedUntilMs,
            );
            await _repo.updateTask(taskId,
                state: 'loading', checkpoint: checkpoint);
            state = ThinkingState.reviewing;
            break;

          case ThinkingState.reviewing:
            final reviewedUntil =
                task.reviewedUntil ?? checkpoint.reviewedUntilMs ?? 0;
            final input = await _collect(taskId, reviewedUntil);
            checkpoint = ThinkingCheckpoint(
              step: 'reviewing',
              reviewedUntilMs: input.reviewedUntilMs,
              sampleCursor: input.sampledMessages.length,
            );
            await _repo.updateTask(taskId,
                state: 'analyzing', checkpoint: checkpoint);
            state = ThinkingState.analyzing;
            break;

          case ThinkingState.analyzing:
            // 用任务原始游标重新取样：reviewing 检查点里的 reviewedUntilMs 是
            // 「本轮结束后的新游标」，若拿它取样会把本轮新消息全部排除。
            final reviewedUntil = task.reviewedUntil ?? 0;
            final input = await _collect(taskId, reviewedUntil);
            var insights = scanner.scan(input);
            if (modelAnalyzer != null) {
              try {
                final modelInsights = await modelAnalyzer!.analyze(input);
                insights = _mergeInsights(insights, modelInsights);
              } catch (_) {
                // 模型失败保留本地结果（不重试）
              }
            }
            checkpoint = ThinkingCheckpoint(
              step: 'analyzing',
              reviewedUntilMs: input.reviewedUntilMs,
              insights: insights,
            );
            await _repo.updateTask(taskId,
                state: 'saving', checkpoint: checkpoint);
            state = ThinkingState.saving;
            break;

          case ThinkingState.saving:
            if (checkpoint.insights.isEmpty) {
              // 检查点缺失（旧数据/异常），回到分析步重算
              checkpoint = ThinkingCheckpoint(
                step: 'reviewing',
                reviewedUntilMs: checkpoint.reviewedUntilMs,
              );
              await _repo.updateTask(taskId,
                  state: 'analyzing', checkpoint: checkpoint);
              state = ThinkingState.analyzing;
              break;
            }
            final saved = <int>{...checkpoint.savedIndexes};
            for (var i = 0; i < checkpoint.insights.length; i++) {
              if (saved.contains(i)) continue;
              final grounded = await _ground(checkpoint.insights[i]);
              if (grounded != null) {
                await _saveInsight(taskId, i, grounded);
              }
              saved.add(i);
              checkpoint = ThinkingCheckpoint(
                step: 'saving',
                reviewedUntilMs: checkpoint.reviewedUntilMs,
                insights: checkpoint.insights,
                savedIndexes: saved.toList()..sort(),
                candidateCount: checkpoint.candidateCount,
              );
              await _repo.updateTask(taskId,
                  state: 'saving', checkpoint: checkpoint);
            }
            checkpoint = ThinkingCheckpoint(
              step: 'deciding',
              reviewedUntilMs: checkpoint.reviewedUntilMs,
              insights: checkpoint.insights,
              savedIndexes: saved.toList()..sort(),
              candidateCount: checkpoint.candidateCount,
            );
            await _repo.updateTask(taskId,
                state: 'deciding', checkpoint: checkpoint);
            state = ThinkingState.deciding;
            break;

          case ThinkingState.deciding:
            var candidates = checkpoint.candidateCount;
            for (var i = 0; i < checkpoint.insights.length; i++) {
              final insight = checkpoint.insights[i];
              if (insight.kind.isQuiet ||
                  insight.actionKind == ProactiveActionKind.quiet) {
                continue;
              }
              final grounded = await _ground(insight);
              if (grounded == null) continue;
              if (await _repo.hasCandidateDedup(grounded.effectiveDedupKey)) {
                continue;
              }
              await _repo.insertCandidate(
                id: 'pc_${taskId}_$i',
                insight: grounded,
                relatedTaskId: taskId,
                expiresAt: _nowMs +
                    const Duration(hours: candidateTtlHours).inMilliseconds,
              );
              candidates++;
            }
            checkpoint = ThinkingCheckpoint(
              step: 'done',
              reviewedUntilMs: checkpoint.reviewedUntilMs,
              insights: checkpoint.insights,
              savedIndexes: checkpoint.savedIndexes,
              candidateCount: candidates,
            );
            final resultCount = await _repo.countResults(taskId);
            await _repo.updateTask(
              taskId,
              state: 'done',
              checkpoint: checkpoint,
              finishedAt: _nowMs,
              reviewedUntil: checkpoint.reviewedUntilMs,
              resultCount: resultCount,
            );
            return ThinkingRunResult(
              taskId: taskId,
              state: ThinkingState.done,
              insightCount: checkpoint.insights.length,
              candidateCount: candidates,
            );

          case ThinkingState.done:
          case ThinkingState.failed:
          case ThinkingState.interrupted:
            return ThinkingRunResult(
              taskId: taskId,
              state: state,
              insightCount: checkpoint.insights.length,
              candidateCount: checkpoint.candidateCount,
            );
        }
      }
      throw StateError('思考状态机循环超限');
    } catch (error) {
      await _repo.updateTask(
        taskId,
        state: 'failed',
        checkpoint: ThinkingCheckpoint(
          step: checkpoint.step,
          reviewedUntilMs: checkpoint.reviewedUntilMs,
          insights: checkpoint.insights,
          savedIndexes: checkpoint.savedIndexes,
          candidateCount: checkpoint.candidateCount,
          error: '$error',
        ),
        scopeNote: '$error',
      );
      return ThinkingRunResult(
        taskId: taskId,
        state: ThinkingState.failed,
        insightCount: checkpoint.insights.length,
        candidateCount: checkpoint.candidateCount,
        error: '$error',
      );
    }
  }

  /// 启动/回前台恢复扫描：非终态任务标记 interrupted 后按检查点续跑。
  Future<List<ThinkingRunResult>> recoverInterrupted() async {
    final tasks = await _repo.resumableTasks();
    final results = <ThinkingRunResult>[];
    for (final task in tasks) {
      await _repo.updateTask(task.id,
          state: 'interrupted', interruptedAt: _nowMs);
      results.add(await run(task.id));
    }
    return results;
  }

  // ------------------------------------------------------------ ② 回顾数据

  Future<ThinkingReviewInput> _collect(String taskId, int reviewedUntil) async {
    final messages = <ReviewMessage>[];
    final conversations = await _conversations.listConversations();
    for (final conversation in conversations.take(20)) {
      final rows = await _conversations.messages(conversation.id, limit: 120);
      for (final message in rows) {
        if (message.role != 'user' && message.role != 'assistant') continue;
        if (message.content.trim().isEmpty) continue;
        final at = DateTime.tryParse(message.createdAt)
                ?.toUtc()
                .millisecondsSinceEpoch ??
            0;
        messages.add(ReviewMessage(
          id: message.id,
          conversationId: conversation.id,
          role: message.role,
          content: message.content,
          createdAtMs: at,
        ));
      }
    }
    messages.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));

    final newMessages = messages
        .where((m) => m.createdAtMs > reviewedUntil)
        .toList();
    final boundedNew = newMessages.length > maxNewMessages
        ? newMessages.sublist(newMessages.length - maxNewMessages)
        : newMessages;

    final older = messages.where((m) => m.createdAtMs <= reviewedUntil).toList();
    final random = Random(taskId.hashCode);
    older.shuffle(random);
    final sampled = older.take(maxSampledMessages).toList();

    final memoryRows = await _memories.listMemories(limit: 80);
    final memoryBriefs = [
      for (final memory in memoryRows)
        if (memory.status == 'active')
          MemoryBrief(
            id: memory.id,
            type: memory.type,
            title: memory.title ?? '',
            summary: memory.summary,
            updatedAtMs: DateTime.tryParse(memory.updatedAt)
                    ?.toUtc()
                    .millisecondsSinceEpoch ??
                0,
          ),
    ];
    final agreements =
        memoryBriefs.where((m) => m.type == 'agreement').toList();

    final past = await _repo.listResults(limit: 10);
    final pastThoughts = past.map((r) => r.content).toList();

    final profile = await _personas.profile();
    var personaPrompt = profile.coreSystemPrompt ?? '';
    if (personaPrompt.isEmpty) {
      personaPrompt = await _personas.rebuildPromptSnapshot();
    }
    if (personaPrompt.length > 1500) {
      personaPrompt = personaPrompt.substring(0, 1500);
    }

    final latest = messages.isEmpty
        ? reviewedUntil
        : max(messages.last.createdAtMs, reviewedUntil);
    return ThinkingReviewInput(
      newMessages: boundedNew,
      sampledMessages: sampled,
      memories: memoryBriefs,
      agreements: agreements,
      pastThoughts: pastThoughts,
      personaPrompt: personaPrompt,
      reviewedUntilMs: latest,
    );
  }

  // ------------------------------------------------------------ ⑤ 保存与 ⑥ 候选

  Future<void> _saveInsight(
      String taskId, int index, ThinkingInsight insight) async {
    final alreadySaved = await _repo.hasResultContent(insight.content);
    if (!alreadySaved) {
      await _repo.insertResult(
        id: 'thr_${taskId}_$index',
        taskId: taskId,
        insight: insight,
        createdAt: _nowIso,
      );
    }
    if (insight.kind == ThinkingResultKind.newConnection &&
        insight.relatedMemoryIds.length >= 2) {
      await _memories.addRelation(
        fromMemoryId: insight.relatedMemoryIds[0],
        toMemoryId: insight.relatedMemoryIds[1],
        relationType: 'related',
        strength: 50,
        discoveredBy: 'thinking',
      );
    }
    if (insight.kind == ThinkingResultKind.reunderstanding) {
      final pending = await _memories.listCandidates();
      if (!pending.any((c) => c.proposedSummary == insight.content)) {
        await _memories.ingestDraft(
          MemoryDraft(
            type: MemoryType.opinion,
            title: '新的理解',
            summary: insight.content,
            confidence: MemoryConfidence.medium,
            importance: 55,
            evidence: insight.content,
            rawText: insight.content,
            opinionChange: true,
          ),
          origin: 'thinking',
          sessionId: taskId,
        );
      }
    }
  }

  /// 引用校验（防伪）：返回过滤后的洞察；引用不成立则整条丢弃。
  Future<ThinkingInsight?> _ground(ThinkingInsight insight) async {
    if (insight.kind.isQuiet) return insight;
    final validMemoryIds = <String>[];
    for (final id in insight.relatedMemoryIds) {
      if (await _memories.getMemory(id) != null) validMemoryIds.add(id);
    }
    final validMessageIds = <String>[];
    for (final id in insight.relatedMessageIds) {
      if (await _conversations.getMessage(id) != null) validMessageIds.add(id);
    }
    switch (insight.kind) {
      case ThinkingResultKind.newConnection:
        if (validMemoryIds.length < 2) return null;
        break;
      case ThinkingResultKind.shareWorthy:
      case ThinkingResultKind.diaryMaterial:
        if (validMemoryIds.isEmpty) return null;
        break;
      case ThinkingResultKind.topicWorthContinuing:
        if (validMessageIds.isEmpty) return null;
        break;
      case ThinkingResultKind.reunderstanding:
        if (validMemoryIds.isEmpty && validMessageIds.isEmpty) return null;
        break;
      case ThinkingResultKind.quiet:
        return insight;
    }
    return ThinkingInsight(
      kind: insight.kind,
      content: insight.content,
      confidence: insight.confidence,
      relatedMemoryIds: validMemoryIds,
      relatedMessageIds: validMessageIds,
      actionKind: insight.actionKind,
      priority: insight.priority,
      sourceKind: insight.sourceKind,
      title: insight.title,
      dedupKey: insight.dedupKey,
    );
  }

  List<ThinkingInsight> _mergeInsights(
    List<ThinkingInsight> local,
    List<ThinkingInsight> remote,
  ) {
    final all = <ThinkingInsight>[];
    final seen = <String>{};
    for (final insight in [...local, ...remote]) {
      if (!seen.add(insight.effectiveDedupKey)) continue;
      all.add(insight);
    }
    final hasReal = all.any((i) => !i.kind.isQuiet);
    final filtered =
        hasReal ? all.where((i) => !i.kind.isQuiet).toList() : all;
    return filtered.take(maxInsights).toList();
  }

  static Map<String, dynamic> _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
