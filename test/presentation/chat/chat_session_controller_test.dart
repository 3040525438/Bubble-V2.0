// 聊天会话控制器单测（T2.4/T2.5）：发送拆段落库、停止、重试幂等、继续、失败队列。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/domain/chat/message_status.dart';
import 'package:bubble/presentation/chat/chat_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_provider.dart';

Future<void> wait([int ms = 350]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late AppDatabase db;
  late ConversationRepository repo;
  late Conversation conv;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    repo = ConversationRepository(db);
    conv = await repo.createConversation();
  });

  tearDown(() async => db.close());

  test('发送：用户消息落库 + 回复按段落拆成多条独立气泡', () async {
    final provider = FakeProvider();
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
    );
    addTearDown(session.dispose);

    await session.send('你好呀，泡泡');
    await wait();

    final messages = await repo.messages(conv.id);
    expect(messages.length, 3);
    expect(messages[0].role, 'user');
    expect(messages[0].status, MessageStatuses.sent);
    expect(messages[1].content, '第一段回复内容');
    expect(messages[1].status, MessageStatuses.sent);
    expect(messages[2].content, '第二段回复内容');
    expect(messages[2].messageKind, MessageKinds.continuation);
    expect([messages[0].seq, messages[1].seq, messages[2].seq], [1, 2, 3]);
    expect(session.generating, isFalse);
  });

  test('停止：保留半成品并置 interrupted，不再追加后续段落', () async {
    final provider = ManualProvider();
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
    );
    addTearDown(session.dispose);

    await session.send('在吗');
    await wait(60);
    provider.controllers.last.add('已经写了一半');
    await wait(120);
    expect(session.generating, isTrue);

    await session.stop();
    expect(session.generating, isFalse);

    final messages = await repo.messages(conv.id);
    final assistant = messages.last;
    expect(assistant.status, MessageStatuses.interrupted);
    expect(assistant.content, '已经写了一半');
  });

  test('停止时一个字都没生成：占位气泡被清理', () async {
    final provider = ManualProvider();
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
    );
    addTearDown(session.dispose);

    await session.send('在吗');
    await wait(60);
    await session.stop();

    final messages = await repo.messages(conv.id);
    expect(messages.length, 1); // 只剩用户消息
    expect(messages.single.role, 'user');
  });

  test('失败 → 进入未发送队列 → 重试复用同一消息（幂等）', () async {
    final provider = FakeProvider(shouldFail: true);
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
    );
    addTearDown(session.dispose);

    await session.send('你好');
    await wait(200);
    expect(session.generating, isFalse);
    expect(session.pendingFailedCount, 1);

    final failed = (await repo.failedMessages(conv.id)).single;
    final requestId = failed.requestId;

    provider.shouldFail = false;
    await session.retry(failed.id);
    await wait();

    final retried = (await repo.getMessage(failed.id))!;
    expect(retried.status, MessageStatuses.sent);
    expect(retried.requestId, requestId); // 幂等键未变
    expect(session.pendingFailedCount, 0);

    final assistantMessages = (await repo.messages(conv.id))
        .where((m) => m.role == 'assistant')
        .toList();
    // 原消息承载第一段，第二段为新增 continuation，不重复创建重试副本
    expect(assistantMessages.length, 2);
    expect(assistantMessages.first.id, failed.id);
  });

  test('继续：从 interrupted 消息生成新的 continuation 气泡', () async {
    final provider = ManualProvider();
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
    );
    addTearDown(session.dispose);

    await session.send('讲个故事');
    await wait(60);
    provider.controllers.last.add('从前有座山');
    await wait(120);
    await session.stop();

    final interrupted = (await repo.messages(conv.id)).last;
    expect(interrupted.status, MessageStatuses.interrupted);

    await session.resume(interrupted.id);
    await wait(60);
    expect(provider.controllers.length, 2);
    provider.controllers.last.add('，山里有座庙');
    await provider.controllers.last.close();
    await wait(200);

    final messages = await repo.messages(conv.id);
    final continuation = messages.last;
    expect(continuation.messageKind, MessageKinds.continuation);
    expect(continuation.status, MessageStatuses.sent);
    expect(continuation.content, '，山里有座庙');
    // 原消息保持「已停止」不被覆盖
    expect((await repo.getMessage(interrupted.id))!.status,
        MessageStatuses.interrupted);
  });

  test('重试全部失败消息', () async {
    final provider = FakeProvider(shouldFail: true);
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
    );
    addTearDown(session.dispose);

    await session.send('第一句');
    await wait(200);
    expect(session.pendingFailedCount, 1);

    provider.shouldFail = false;
    final count = await session.retryAllFailed();
    expect(count, 1);
    await wait(300);
    expect(session.pendingFailedCount, 0);
  });

  test('打开会话时收敛悬挂状态（不悬挂 streaming）', () async {
    final hanging = await repo.beginAssistantMessage(conv.id);
    await repo.updateMessageContent(hanging.id, '半截内容');

    final session = ChatSessionController(
      repository: repo,
      provider: FakeProvider(),
      conversationId: conv.id,
    );
    addTearDown(session.dispose);
    await session.load();

    expect((await repo.getMessage(hanging.id))!.status,
        MessageStatuses.interrupted);
  });
}
