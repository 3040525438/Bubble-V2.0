// 思考编排器单测（T7.2/T7.3）：全流程、话题发现、联动、引用校验、检查点恢复与幂等。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/data/repositories/memory_repository.dart';
import 'package:bubble/data/repositories/thinking_repository.dart';
import 'package:bubble/data/thinking/thinking_orchestrator.dart';
import 'package:bubble/domain/thinking/local_insight_scanner.dart';
import 'package:bubble/domain/thinking/thinking_analyzer.dart';
import 'package:bubble/domain/thinking/thinking_models.dart';
import 'package:flutter_test/flutter_test.dart';

class _QueuedAnalyzer implements ThinkingModelAnalyzer {
  _QueuedAnalyzer(this.insights);

  final List<ThinkingInsight> insights;
  int calls = 0;

  @override
  Future<List<ThinkingInsight>> analyze(ThinkingReviewInput input) async {
    calls++;
    return insights;
  }
}

class _ThrowingScanner extends LocalInsightScanner {
  const _ThrowingScanner();

  @override
  List<ThinkingInsight> scan(ThinkingReviewInput input) {
    throw StateError('模拟分析崩溃');
  }
}

void main() {
  late AppDatabase db;
  late MemoryRepository memories;
  late ConversationRepository conversations;
  late ThinkingRepository thinking;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    memories = MemoryRepository(db);
    conversations = ConversationRepository(db);
    thinking = ThinkingRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedMemories() async {
    await memories.createMemory(
      type: 'preference',
      title: '西湖散步',
      summary: '我喜欢在周末去西湖边散步',
      confidence: 'high',
    );
    await memories.createMemory(
      type: 'preference',
      title: '西湖跑步',
      summary: '我喜欢在周末去西湖边跑步',
      confidence: 'high',
    );
    await memories.createMemory(
      type: 'event',
      title: '搬家',
      summary: '今天搬家了，新家有个小阳台',
      confidence: 'high',
    );
    await memories.createMemory(
      type: 'relationship',
      title: '关系',
      summary: '我们的关系好像更近了一点',
      confidence: 'high',
    );
  }

  test('无新消息也能走完八步并产出想法与候选', () async {
    await seedMemories();
    final orchestrator = ThinkingOrchestrator(
      db,
      repository: thinking,
      memories: memories,
      conversations: conversations,
      now: () => DateTime.utc(2026, 11, 22, 10),
    );

    final result = await orchestrator.runNew(trigger: ThinkingTrigger.manual);
    expect(result.state, ThinkingState.done);
    expect(result.insightCount, greaterThanOrEqualTo(3));
    expect(result.candidateCount, greaterThanOrEqualTo(2));

    final results = await thinking.listResults();
    final kinds = results.map((r) => r.resultKind).toSet();
    expect(kinds, contains('new_connection'));
    expect(kinds, contains('share_worthy'));
    expect(kinds, contains('diary_material'));

    final candidates = await thinking.listCandidates();
    expect(candidates, isNotEmpty);
    expect(candidates.map((c) => c.actionKind), contains('chat'));

    final task = await thinking.getTask(result.taskId);
    expect(task!.state, 'done');
    expect(task.finishedAt, isNotNull);
  });

  test('新联系落 memory_relations（discovered_by=thinking）', () async {
    await seedMemories();
    final orchestrator = ThinkingOrchestrator(db, repository: thinking);
    await orchestrator.runNew(trigger: ThinkingTrigger.manual);

    final all = await memories.listMemories();
    final a = all.firstWhere((m) => m.title == '西湖散步');
    final relations = await memories.relationsOf(a.id);
    expect(relations, isNotEmpty);
    expect(relations.first.relation.discoveredBy, 'thinking');
    expect(relations.first.other.title, '西湖跑步');
  });

  test('历史未续话题被识别并关联真实消息', () async {
    final conv = await conversations.createConversation(title: '闲聊');
    final message = await conversations.appendUserMessage(
        conv.id, '下次我们再聊这个话题好吗？');
    final orchestrator = ThinkingOrchestrator(db, repository: thinking);

    final result = await orchestrator.runNew(trigger: ThinkingTrigger.manual);
    expect(result.state, ThinkingState.done);

    final results = await thinking.listResults();
    final topic = results.firstWhere(
        (r) => r.resultKind == 'topic_worth_continuing');
    expect(topic.relatedMessageIds, contains(message.id));

    final task = await thinking.getTask(result.taskId);
    final messageMs =
        DateTime.parse(message.createdAt).toUtc().millisecondsSinceEpoch;
    expect(task!.reviewedUntil, greaterThanOrEqualTo(messageMs));
  });

  test('观点变化产生重新理解，并写入记忆候选（origin=thinking）', () async {
    await memories.createMemory(
      type: 'opinion',
      title: '独处',
      summary: '以前我觉得独处很好，现在发现有人陪也不错',
      confidence: 'high',
    );
    final orchestrator = ThinkingOrchestrator(db, repository: thinking);
    await orchestrator.runNew(trigger: ThinkingTrigger.manual);

    final results = await thinking.listResults();
    expect(results.any((r) => r.resultKind == 'reunderstanding'), isTrue);

    final memoryCandidates = await memories.listCandidates();
    expect(memoryCandidates, isNotEmpty);
    expect(memoryCandidates.first.origin, 'thinking');
    expect(memoryCandidates.first.proposedTitle, '新的理解');
  });

  test('伪造引用被拒绝：假记忆/消息 id 不产生想法与候选', () async {
    final analyzer = _QueuedAnalyzer(const [
      ThinkingInsight(
        kind: ThinkingResultKind.shareWorthy,
        content: '伪造的分享',
        relatedMemoryIds: ['mem_fake_1'],
        sourceKind: 'model_thinking',
      ),
      ThinkingInsight(
        kind: ThinkingResultKind.topicWorthContinuing,
        content: '伪造的话题',
        relatedMessageIds: ['msg_fake_1'],
        sourceKind: 'model_thinking',
      ),
      ThinkingInsight(
        kind: ThinkingResultKind.newConnection,
        content: '伪造的联系',
        relatedMemoryIds: ['mem_fake_1', 'mem_fake_2'],
        sourceKind: 'model_thinking',
      ),
    ]);
    final orchestrator = ThinkingOrchestrator(
      db,
      repository: thinking,
      modelAnalyzer: analyzer,
    );

    final result = await orchestrator.runNew(trigger: ThinkingTrigger.manual);
    expect(result.state, ThinkingState.done);
    expect(await thinking.listResults(), isEmpty);
    expect(await thinking.listCandidates(), isEmpty);
  });

  test('从 saving 检查点续跑：跳过分析，直接保存并出候选', () async {
    final event =
        await memories.createMemory(type: 'event', summary: '今天搬家了，新家有个小阳台');
    final task = await thinking.createTask(
      trigger: 'manual',
      initialState: 'saving',
    );
    await thinking.updateTask(
      task.id,
      state: 'saving',
      checkpoint: ThinkingCheckpoint(
        step: 'saving',
        reviewedUntilMs: 0,
        insights: [
          ThinkingInsight(
            kind: ThinkingResultKind.shareWorthy,
            content: '这段经历也许可以拿出来聊聊：今天搬家了',
            relatedMemoryIds: [event.id],
          ),
        ],
      ),
    );

    final analyzer = _QueuedAnalyzer(const []);
    final orchestrator = ThinkingOrchestrator(
      db,
      repository: thinking,
      modelAnalyzer: analyzer,
    );
    final result = await orchestrator.run(task.id);

    expect(result.state, ThinkingState.done);
    expect(analyzer.calls, 0);
    expect(await thinking.listResults(), hasLength(1));
    expect(await thinking.listCandidates(), hasLength(1));
  });

  test('从 deciding 检查点续跑：只补候选，不重复保存结果', () async {
    final event =
        await memories.createMemory(type: 'event', summary: '今天搬家了');
    final task = await thinking.createTask(
      trigger: 'manual',
      initialState: 'deciding',
    );
    const insight = ThinkingInsight(
      kind: ThinkingResultKind.shareWorthy,
      content: '这段经历也许可以拿出来聊聊：今天搬家了',
    );
    final grounded = ThinkingInsight(
      kind: insight.kind,
      content: insight.content,
      relatedMemoryIds: [event.id],
    );
    await thinking.insertResult(
      id: 'thr_${task.id}_0',
      taskId: task.id,
      insight: grounded,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    await thinking.updateTask(
      task.id,
      state: 'deciding',
      checkpoint: ThinkingCheckpoint(
        step: 'deciding',
        reviewedUntilMs: 0,
        insights: [grounded],
        savedIndexes: const [0],
      ),
    );

    final orchestrator = ThinkingOrchestrator(db, repository: thinking);
    final result = await orchestrator.run(task.id);
    expect(result.state, ThinkingState.done);
    expect(await thinking.listResults(), hasLength(1));
    expect(await thinking.listCandidates(), hasLength(1));
  });

  test('重复运行保持幂等：想法与候选都不翻倍', () async {
    await seedMemories();
    final orchestrator = ThinkingOrchestrator(db, repository: thinking);
    final first = await orchestrator.runNew(trigger: ThinkingTrigger.manual);
    final firstResults = (await thinking.listResults()).length;
    final firstCandidates = (await thinking.listCandidates()).length;

    await orchestrator.runNew(trigger: ThinkingTrigger.manual);
    expect((await thinking.listResults()).length, firstResults);
    expect((await thinking.listCandidates()).length, firstCandidates);

    final again = await orchestrator.run(first.taskId);
    expect(again.state, ThinkingState.done);
    expect((await thinking.listResults()).length, firstResults);
  });

  test('分析崩溃 → 任务 failed 并保留错误说明', () async {
    await seedMemories();
    final orchestrator = ThinkingOrchestrator(
      db,
      repository: thinking,
      scanner: const _ThrowingScanner(),
    );
    final result = await orchestrator.runNew(trigger: ThinkingTrigger.manual);
    expect(result.state, ThinkingState.failed);
    expect(result.error, contains('模拟分析崩溃'));
    final task = await thinking.getTask(result.taskId);
    expect(task!.state, 'failed');
    expect(task.scopeNote, contains('模拟分析崩溃'));
  });

  test('恢复扫描：非终态任务可续跑完成', () async {
    await seedMemories();
    final task = await thinking.createTask(
      trigger: 'app_resume',
      initialState: 'reviewing',
    );
    final orchestrator = ThinkingOrchestrator(db, repository: thinking);
    final results = await orchestrator.recoverInterrupted();
    expect(results, hasLength(1));
    expect(results.first.state, ThinkingState.done);
    expect((await thinking.getTask(task.id))!.state, 'done');
    expect(await thinking.resumableTasks(), isEmpty);
  });
}
