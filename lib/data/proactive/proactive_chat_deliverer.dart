// 主动聊天消息投递（T13.3 前置）：把思考产出的候选草稿落成真实 proactive 消息，
// 再交给通知调度器预排提醒（消息先落库，通知与真实消息一致 FR-IOS-03）。
import '../database/app_database.dart';
import '../notification/notification_dispatcher.dart';
import '../repositories/conversation_repository.dart';
import 'proactive_decision_center.dart';

class ProactiveChatDeliverer {
  ProactiveChatDeliverer({
    required ConversationRepository conversations,
    required NotificationDispatcher notifications,
    Duration notifyDelay = const Duration(minutes: 2),
  }) : _conversations = conversations,
       _notifications = notifications,
       _notifyDelay = notifyDelay;

  final ConversationRepository _conversations;
  final NotificationDispatcher _notifications;
  final Duration _notifyDelay;

  Future<ProactiveDelivery> deliver(ProactiveCandidate candidate) async {
    final content = (candidate.contentDraft ?? '').trim();
    if (content.isEmpty) {
      // 没有草稿就宁可不说：不拼接模板句冒充模型输出
      return const ProactiveDelivery(note: '候选没有文字草稿，本轮不发送（避免模板腔）');
    }

    var conversationId = await _conversations.mostRecentConversationId();
    conversationId ??= (await _conversations.createConversation(
      title: '和泡泡的聊天',
    )).id;
    final message = await _conversations.appendProactiveMessage(
      conversationId,
      content,
    );
    final preview = content.length > 20
        ? '${content.substring(0, 20)}…'
        : content;

    String notifyNote;
    try {
      final result = await _notifications.dispatch(
        content: content,
        deliverableType: 'chat',
        sourceLabel: '新消息',
        conversationId: conversationId,
        messageId: message.id,
        candidateId: candidate.id,
        reason: '主动联系',
        delay: _notifyDelay,
      );
      notifyNote = result.ok ? '，提醒已安排' : '，提醒未安排（${result.reason}）';
    } catch (error) {
      notifyNote = '，提醒安排失败';
    }

    return ProactiveDelivery(
      deliverableType: 'message',
      deliverableId: message.id,
      note: '主动联系：$preview$notifyNote',
    );
  }
}
