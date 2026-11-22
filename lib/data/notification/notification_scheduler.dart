// 本地通知调度抽象与实现（T13.3，FR-IOS-03）。
// 抽象层便于单测注入假实现；真机实现基于 flutter_local_notifications + timezone。
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../domain/notification/notification_models.dart';

/// 通知调度能力（实现方必须如实报告 supported/isEnabled）
abstract class NotificationScheduler {
  /// 平台是否支持本地通知
  bool get supported;

  /// 初始化并注册点击回调（payload 为 [NotificationPayload] JSON）
  Future<void> initialize({required void Function(String? payload) onTap});

  /// 请求通知权限（用户主动操作时调用）
  Future<bool> requestPermission();

  /// 当前权限状态
  Future<bool> isEnabled();

  /// 安排一条本地通知
  Future<void> schedule(NotificationPlan plan);

  /// 取消一条本地通知
  Future<void> cancel(String notificationId);

  /// 当前系统尚未投递的通知 int id 列表（重复检测用）
  Future<List<String>> pendingIds();
}

/// 真机实现（iOS/Android）；其他平台 supported=false，不假装可用。
class LocalNotificationScheduler implements NotificationScheduler {
  LocalNotificationScheduler({
    FlutterLocalNotificationsPlugin? plugin,
    String Function()? timezoneName,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       _timezoneName = timezoneName ?? (() => 'Asia/Shanghai');

  static const androidChannelId = 'bubble_proactive';
  static const androidChannelName = '泡泡的主动消息';

  final FlutterLocalNotificationsPlugin _plugin;
  final String Function() _timezoneName;
  tz.Location? _location;
  bool _initialized = false;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {
    if (!supported || _initialized) return;
    tz_data.initializeTimeZones();
    try {
      _location = tz.getLocation(_timezoneName());
    } catch (_) {
      _location = tz.UTC;
    }
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      // 权限延迟到用户点击「开启通知」时请求（避免启动即弹窗）
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) => onTap(response.payload),
    );
    _initialized = true;

    // 冷启动：App 被通知点击拉起时补发 payload
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        onTap(launch?.notificationResponse?.payload);
      }
    } catch (_) {
      // 冷启动详情不可用不影响后续
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (!supported) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final granted = await ios?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final granted = await android?.requestNotificationsPermission();
    return granted ?? false;
  }

  @override
  Future<bool> isEnabled() async {
    if (!supported) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      final options = await ios?.checkPermissions();
      return options?.isEnabled ?? false;
    }
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    return await android?.areNotificationsEnabled() ?? false;
  }

  @override
  Future<void> schedule(NotificationPlan plan) async {
    if (!supported) {
      throw UnsupportedError('当前平台不支持本地通知');
    }
    final location = _location ?? tz.UTC;
    await initialize(onTap: (_) {});
    await _plugin.zonedSchedule(
      id: plan.intId,
      title: plan.title,
      body: plan.body.isEmpty ? null : plan.body,
      scheduledDate: tz.TZDateTime.from(plan.fireAt, location),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          androidChannelId,
          androidChannelName,
          channelDescription: '泡泡主动联系时的本地提醒（仅本机，无云推送）',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: plan.payload.encode(),
    );
  }

  @override
  Future<void> cancel(String notificationId) async {
    if (!supported) return;
    await _plugin.cancel(
      id: NotificationPolicy.notificationIntId(notificationId),
    );
  }

  @override
  Future<List<String>> pendingIds() async {
    if (!supported) return const [];
    final pending = await _plugin.pendingNotificationRequests();
    return [for (final item in pending) item.id.toString()];
  }
}

/// 测试/不支持平台的空实现（明确 supported=false）
class NoopNotificationScheduler implements NotificationScheduler {
  const NoopNotificationScheduler();

  @override
  bool get supported => false;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
  }) async {}

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> schedule(NotificationPlan plan) async {
    throw UnsupportedError('当前平台不支持本地通知');
  }

  @override
  Future<void> cancel(String notificationId) async {}

  @override
  Future<List<String>> pendingIds() async => const [];
}
