// 消息状态机（T2.4）：纯函数层，无 IO。
// 依据 DATABASE_DESIGN §2.2 的 status 取值与 UI_INTERACTION_SPEC §2.1 的
// 发送/生成/停止/失败/重试/继续交互。
library;

/// 消息状态常量（与数据库 CHECK 约束一致）
abstract final class MessageStatuses {
  static const sending = 'sending';
  static const streaming = 'streaming';
  static const sent = 'sent';
  static const failed = 'failed';
  static const interrupted = 'interrupted';
  static const deleted = 'deleted';

  static const all = {sending, streaming, sent, failed, interrupted, deleted};
}

/// 消息类型（与数据库 message_kind 一致）
abstract final class MessageKinds {
  static const normal = 'normal';
  static const continuation = 'continuation';
  static const proactive = 'proactive';
  static const systemNote = 'system_note';
}

/// 允许的状态迁移表。
///
/// - sending   → sent / failed / interrupted / streaming
/// - streaming → sent / failed / interrupted
/// - failed    → sending / streaming（重试复用同一消息，request_id 幂等）
/// - interrupted → streaming（继续生成）
/// - sent / deleted 为终态（重新生成走新消息）
const Map<String, Set<String>> kMessageTransitions = {
  MessageStatuses.sending: {
    MessageStatuses.sent,
    MessageStatuses.failed,
    MessageStatuses.interrupted,
    MessageStatuses.streaming,
  },
  MessageStatuses.streaming: {
    MessageStatuses.sent,
    MessageStatuses.failed,
    MessageStatuses.interrupted,
  },
  MessageStatuses.failed: {
    MessageStatuses.sending,
    MessageStatuses.streaming,
  },
  MessageStatuses.interrupted: {
    MessageStatuses.streaming,
    MessageStatuses.sent,
  },
  MessageStatuses.sent: {},
  MessageStatuses.deleted: {},
};

/// 是否允许从 [from] 迁移到 [to]；同状态视为合法（幂等写入）。
bool canTransitionMessageStatus(String from, String to) {
  if (from == to) return true;
  return kMessageTransitions[from]?.contains(to) ?? false;
}

/// 状态的中文展示名（聊天页/测试共用）。
String messageStatusLabel(String status) {
  switch (status) {
    case MessageStatuses.sending:
      return '发送中';
    case MessageStatuses.streaming:
      return '生成中';
    case MessageStatuses.sent:
      return '已发送';
    case MessageStatuses.failed:
      return '发送失败';
    case MessageStatuses.interrupted:
      return '已停止';
    case MessageStatuses.deleted:
      return '已删除';
    default:
      return status;
  }
}

/// 是否处于「可被启动流程判定为悬挂」的非终态。
bool isUnfinishedStatus(String status) =>
    status == MessageStatuses.sending || status == MessageStatuses.streaming;
