// 通知测试替身：记录计划与取消，可模拟权限/调度失败。
import 'package:bubble/data/notification/notification_scheduler.dart';
import 'package:bubble/domain/notification/notification_models.dart';

class FakeNotificationScheduler implements NotificationScheduler {
  FakeNotificationScheduler({
    this.supportedValue = true,
    this.permission = true,
  });

  bool supportedValue;
  bool permission;
  bool failSchedule = false;
  bool initialized = false;

  final List<NotificationPlan> scheduled = [];
  final List<String> cancelled = [];
  final List<String> pending = [];
  void Function(String? payload)? onTapHandler;

  @override
  bool get supported => supportedValue;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {
    initialized = true;
    onTapHandler = onTap;
  }

  @override
  Future<bool> requestPermission() async => permission;

  @override
  Future<bool> isEnabled() async => permission;

  @override
  Future<void> schedule(NotificationPlan plan) async {
    if (failSchedule) throw StateError('权限未开启');
    scheduled.add(plan);
    pending.add(plan.notificationId);
  }

  @override
  Future<void> cancel(String notificationId) async {
    cancelled.add(notificationId);
    pending.remove(notificationId);
  }

  @override
  Future<List<String>> pendingIds() async => List.of(pending);
}
