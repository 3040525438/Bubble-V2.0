// 会话/消息仓储单测（T2.1/T2.5/T2.6）：seq 分配、计数维护、软删与范围删除、
// 悬挂状态恢复、失败队列、会话内 bigram 检索。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/domain/chat/message_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ConversationRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = ConversationRepository(db);
  });

  tearDown(() async => db.close());

  group('会话', () {
    test('新建会话使用默认名', () async {
      final conv = await repo.createConversation();
      expect(conv.title, kDefaultConversationTitle);
      expect(conv.messageCount, 0);
    });

    test('首条用户消息自动命名会话（截断 20 字）', () async {
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, '我最近开始学做手冲咖啡了，感觉很有意思');
      final updated = await repo.getConversation(conv.id);
      expect(updated!.title, startsWith('我最近开始学做手冲咖啡了'));
      expect(updated.title.runes.length, lessThanOrEqualTo(21));
    });

    test('列表按最后消息时间倒序且未读数正确', () async {
      final first = await repo.createConversation(title: '较早');
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final second = await repo.createConversation(title: '较晚');

      await repo.markConversationRead(first.id);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final assistant = await repo.beginAssistantMessage(first.id);
      await repo.finishMessage(assistant.id, content: '你好呀');

      final list = await repo.listConversations();
      expect(list.length, 2);
      expect(list.first.id, first.id); // 有消息的排前面
      expect(list.first.unreadCount, 1);
      expect(list.first.lastContent, '你好呀');
      expect(list.last.id, second.id);
      expect(list.last.unreadCount, 0);
    });

    test('标记已读后未读数清零', () async {
      final conv = await repo.createConversation();
      final assistant = await repo.beginAssistantMessage(conv.id);
      await repo.finishMessage(assistant.id, content: '在的');
      expect((await repo.listConversations()).single.unreadCount, 1);
      await repo.markConversationRead(conv.id);
      expect((await repo.listConversations()).single.unreadCount, 0);
    });

    test('软删会话：保留消息 / 连带删除消息两种范围', () async {
      final keep = await repo.createConversation(title: '保留消息');
      await repo.appendUserMessage(keep.id, '这条要留着');
      await repo.softDeleteConversation(keep.id, deleteMessages: false);
      expect(await repo.listConversations(), isEmpty);
      expect((await repo.messages(keep.id)).length, 1); // 归档保留

      final wipe = await repo.createConversation(title: '全部删除');
      await repo.appendUserMessage(wipe.id, '这条要删掉');
      await repo.softDeleteConversation(wipe.id, deleteMessages: true);
      expect(await repo.messages(wipe.id), isEmpty);
      final wiped = await repo.getConversation(wipe.id);
      expect(wiped!.messageCount, 0);
    });
  });

  group('消息', () {
    test('seq 连续分配且会话计数/最后时间同步', () async {
      final conv = await repo.createConversation();
      final m1 = await repo.appendUserMessage(conv.id, '第一条');
      final m2 = await repo.appendAssistantSegment(conv.id, '第二条');
      final m3 = await repo.appendUserMessage(conv.id, '第三条');

      expect([m1.seq, m2.seq, m3.seq], [1, 2, 3]);
      final updated = await repo.getConversation(conv.id);
      expect(updated!.messageCount, 3);
      expect(updated.lastMessageAt, isNotNull);

      // 软删中间一条：剩余 seq 不回退（避免复用序号）
      await repo.softDeleteMessage(m2.id);
      final m4 = await repo.appendUserMessage(conv.id, '第四条');
      expect(m4.seq, 4);
      expect((await repo.getConversation(conv.id))!.messageCount, 3);
      expect((await repo.messages(conv.id)).length, 3);
    });

    test('悬挂 streaming 消息恢复：有内容转 interrupted，无内容转 failed', () async {
      final conv = await repo.createConversation();
      final withContent = await repo.beginAssistantMessage(conv.id);
      await repo.updateMessageContent(withContent.id, '已经写了一半的内容');
      final empty = await repo.beginAssistantMessage(conv.id);

      final recovered =
          await repo.recoverUnfinishedMessages(conversationId: conv.id);
      expect(recovered, 2);
      final a = (await repo.getMessage(withContent.id))!;
      expect(a.status, MessageStatuses.interrupted);
      expect(a.content, '已经写了一半的内容');
      final b = (await repo.getMessage(empty.id))!;
      expect(b.status, MessageStatuses.failed);
      expect(b.errorCode, 'interrupted');
    });

    test('失败消息构成未发送队列，重试复用同一 request_id', () async {
      final conv = await repo.createConversation();
      final assistant = await repo.beginAssistantMessage(conv.id);
      final requestId = assistant.requestId;
      await repo.failMessage(assistant.id, errorCode: 'generation_failed');

      final queue = await repo.failedMessages(conv.id);
      expect(queue.length, 1);
      expect(queue.single.id, assistant.id);

      await repo.resetForRetry(assistant.id);
      final retried = (await repo.getMessage(assistant.id))!;
      expect(retried.status, MessageStatuses.sending);
      expect(retried.content, isEmpty);
      expect(retried.requestId, requestId); // 幂等键不变
      expect((await repo.failedMessages(conv.id)), isEmpty);
    });

    test('对话历史只包含已落定且有内容的消息', () async {
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, '早上好');
      final failed = await repo.beginAssistantMessage(conv.id);
      await repo.failMessage(failed.id, errorCode: 'generation_failed');
      final ok = await repo.beginAssistantMessage(conv.id);
      await repo.finishMessage(ok.id, content: '早上好呀');

      final history = await repo.history(conv.id);
      expect(history.length, 2);
      expect(history.map((t) => t.content), ['早上好', '早上好呀']);
      expect(history.map((t) => t.role), ['user', 'assistant']);
    });
  });

  group('会话内搜索', () {
    test('中文子串与单字查询命中', () async {
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, '我最近开始学做咖啡，手冲比意式难一点');
      await repo.appendUserMessage(conv.id, '周末去了公园散步');

      expect((await repo.searchMessages(conv.id, '咖啡')).length, 1);
      expect((await repo.searchMessages(conv.id, '咖')).length, 1); // 单字走子串
      expect((await repo.searchMessages(conv.id, '公园')).length, 1);
      expect(await repo.searchMessages(conv.id, '旅行'), isEmpty);
    });

    test('bigram 过滤：子串不存在但双字 token 全命中时命中', () async {
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, '咖啡与啡店');
      // 「咖啡店」不是连续子串，但 bigram 集合 {咖啡, 啡店} 全命中
      final hit = await repo.searchMessages(conv.id, '咖啡店');
      expect(hit.length, 1);
      expect(await repo.searchMessages(conv.id, '咖茶店'), isEmpty);
    });

    test('英文整词匹配忽略大小写', () async {
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, 'I love Coffee in the morning');
      expect((await repo.searchMessages(conv.id, 'coffee')).length, 1);
      expect(await repo.searchMessages(conv.id, 'coffees'), isEmpty);
    });

    test('空查询返回空列表', () async {
      final conv = await repo.createConversation();
      await repo.appendUserMessage(conv.id, '你好');
      expect(await repo.searchMessages(conv.id, '   '), isEmpty);
    });
  });
}
