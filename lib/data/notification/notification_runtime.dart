// 通知运行时单例（阶段 13）：由主界面初始化后注入，供聊天页删除消息时联动取消通知。
// 未初始化（如测试/通知不可用）时保持 null，调用方需空安全处理。
import 'notification_dispatcher.dart';

class NotificationRuntime {
  NotificationRuntime._();

  static NotificationDispatcher? dispatcher;
}
