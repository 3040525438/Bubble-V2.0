// 通知领域模型与策略（T13.1/T13.3，FR-IOS-03/06/08）。
// 纯函数设计：不依赖插件与数据库，便于对勿扰顺延、上限、过期、深链做穷举单测。
import 'dart:convert';

/// 通知隐私三档（DATABASE_DESIGN §2.25；D-3 默认 minimal）
enum NotificationPrivacy {
  full('full', '完整显示', '来源与消息摘要都会显示', '泡'),
  minimal('minimal', '只提示有新消息', '不含任何内容，只显示「泡泡有新消息」', '泡'),
  hidden('hidden', '隐藏内容', '通知只显示应用名，不含标题与正文', '泡');

  const NotificationPrivacy(
    this.wire,
    this.label,
    this.description,
    this.iconLabel,
  );

  final String wire;
  final String label;
  final String description;
  final String iconLabel;

  static NotificationPrivacy fromWire(String? value) {
    for (final mode in NotificationPrivacy.values) {
      if (mode.wire == value) return mode;
    }
    return NotificationPrivacy.minimal;
  }
}

/// 渲染后的通知内容（标题/正文/是否带来源）
class NotificationContent {
  const NotificationContent({
    required this.title,
    required this.body,
    this.subtitle,
  });

  final String title;
  final String body;
  final String? subtitle;

  bool get isSilent => title.isEmpty && body.isEmpty;
}

/// 按隐私三档渲染通知（FR-IOS-08）。
///
/// - full：标题带来源，正文为消息摘要；
/// - minimal：固定「泡泡有新消息」，无正文；
/// - hidden：标题仅「泡泡」，无正文。
NotificationContent renderNotification({
  required NotificationPrivacy privacy,
  required String sourceLabel,
  required String messageText,
}) {
  final text = messageText.trim();
  final preview = text.isEmpty
      ? '想和你说句话'
      : (text.length <= 60 ? text : '${text.substring(0, 60)}…');
  switch (privacy) {
    case NotificationPrivacy.full:
      return NotificationContent(
        title: '泡泡 · $sourceLabel',
        body: preview,
        subtitle: sourceLabel,
      );
    case NotificationPrivacy.minimal:
      return const NotificationContent(title: '泡泡有新消息', body: '');
    case NotificationPrivacy.hidden:
      return const NotificationContent(title: '泡泡', body: '');
  }
}

/// 通知设置（notification_settings 单行）
class NotificationSettings {
  const NotificationSettings({
    this.privacyMode = NotificationPrivacy.minimal,
    this.allowPostNotify = true,
    this.allowDiaryLetterNotify = true,
    this.dailyNotifyCap = 10,
    this.quietStart = '23:00',
    this.quietEnd = '08:00',
    this.quietTimezone,
    this.updatedAt,
  });

  final NotificationPrivacy privacyMode;
  final bool allowPostNotify;
  final bool allowDiaryLetterNotify;
  final int dailyNotifyCap;
  final String quietStart; // HH:mm，跨午夜允许
  final String quietEnd;
  final String? quietTimezone;
  final String? updatedAt;

  NotificationSettings copyWith({
    NotificationPrivacy? privacyMode,
    bool? allowPostNotify,
    bool? allowDiaryLetterNotify,
    int? dailyNotifyCap,
    String? quietStart,
    String? quietEnd,
    String? quietTimezone,
    String? updatedAt,
  }) {
    return NotificationSettings(
      privacyMode: privacyMode ?? this.privacyMode,
      allowPostNotify: allowPostNotify ?? this.allowPostNotify,
      allowDiaryLetterNotify:
          allowDiaryLetterNotify ?? this.allowDiaryLetterNotify,
      dailyNotifyCap: dailyNotifyCap ?? this.dailyNotifyCap,
      quietStart: quietStart ?? this.quietStart,
      quietEnd: quietEnd ?? this.quietEnd,
      quietTimezone: quietTimezone ?? this.quietTimezone,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 某类别是否允许提醒（post / diary / letter；chat 始终允许）
  bool allowsKind(String deliverableType) {
    switch (deliverableType) {
      case 'post':
        return allowPostNotify;
      case 'diary':
      case 'letter':
      case 'letter_draft':
        return allowDiaryLetterNotify;
      default:
        return true;
    }
  }
}

/// scheduled_messages 五态（DATABASE_DESIGN §2.16）
class ScheduledStatus {
  static const pending = 'pending';
  static const scheduled = 'scheduled';
  static const delivered = 'delivered';
  static const cancelled = 'cancelled';
  static const expired = 'expired';

  static const active = <String>{pending, scheduled};
}

/// 通知深链载荷（JSON 存 notification payload，点击时解析）
class NotificationPayload {
  const NotificationPayload({
    required this.type,
    this.conversationId,
    this.messageId,
    this.targetId,
  });

  final String type; // chat / post / diary / letter
  final String? conversationId;
  final String? messageId;
  final String? targetId;

  String encode() => jsonEncode({
    'type': type,
    if (conversationId != null) 'conversationId': conversationId,
    if (messageId != null) 'messageId': messageId,
    if (targetId != null) 'targetId': targetId,
  });

  static NotificationPayload? tryDecode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final type = (map['type'] ?? '').toString();
      if (type.isEmpty) return null;
      return NotificationPayload(
        type: type,
        conversationId: map['conversationId']?.toString(),
        messageId: map['messageId']?.toString(),
        targetId: map['targetId']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 点击后的路由路径（无效载荷返回 null，不盲目跳转）
  String? get routePath {
    switch (type) {
      case 'chat':
        final id = conversationId;
        if (id == null || id.isEmpty) return null;
        final focus = messageId;
        return focus == null || focus.isEmpty
            ? '/chat/$id'
            : '/chat/$id?focus=$focus';
      case 'post':
        return targetId == null ? null : '/post/$targetId';
      case 'diary':
        return targetId == null ? null : '/diary/$targetId';
      case 'letter':
        return targetId == null ? null : '/letters/$targetId';
      default:
        return null;
    }
  }
}

/// 待调度通知计划（Dispatcher 交给 Scheduler）
class NotificationPlan {
  const NotificationPlan({
    required this.notificationId,
    required this.fireAt,
    required this.title,
    required this.body,
    required this.payload,
  });

  final String notificationId;
  final DateTime fireAt; // 本地墙钟时间
  final String title;
  final String body;
  final NotificationPayload payload;

  /// 插件使用 int id；由 UUID 稳定哈希得到，取消时使用同一值
  int get intId => NotificationPolicy.notificationIntId(notificationId);
}

/// 通知策略纯函数（勿扰/上限/过期/时区/ID）
class NotificationPolicy {
  const NotificationPolicy();

  /// 队列上限（FR-IOS-06，不无限堆积）
  static const queueLimit = 20;

  /// 稳定 int id（同一 UUID 始终得到同一值）
  static int notificationIntId(String uuid) {
    var hash = 17;
    for (final unit in uuid.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }

  /// 解析 HH:mm（非法返回 null）
  static (int hour, int minute)? parseHhMm(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return (hour, minute);
  }

  /// 是否落在勿扰窗口（支持跨午夜，如 23:00–08:00）
  static bool inQuietHours(DateTime at, String start, String end) {
    final s = parseHhMm(start);
    final e = parseHhMm(end);
    if (s == null || e == null) return false;
    final minutes = at.hour * 60 + at.minute;
    final startMinutes = s.$1 * 60 + s.$2;
    final endMinutes = e.$1 * 60 + e.$2;
    if (startMinutes == endMinutes) return false;
    if (startMinutes < endMinutes) {
      return minutes >= startMinutes && minutes < endMinutes;
    }
    return minutes >= startMinutes || minutes < endMinutes;
  }

  /// 勿扰顺延：落在窗口内则顺延到窗口结束（同日或次日）
  static DateTime deferOutOfQuietHours(
    DateTime fireAt,
    String start,
    String end,
  ) {
    if (!inQuietHours(fireAt, start, end)) return fireAt;
    final e = parseHhMm(end);
    if (e == null) return fireAt;
    final endToday = DateTime(
      fireAt.year,
      fireAt.month,
      fireAt.day,
      e.$1,
      e.$2,
    );
    if (endToday.isAfter(fireAt)) return endToday;
    return endToday.add(const Duration(days: 1));
  }

  /// 计划时刻是否已过期（expires_at 为空不过期）
  static bool isExpired(int? expiresAtMs, DateTime now) {
    if (expiresAtMs == null) return false;
    return now.millisecondsSinceEpoch >= expiresAtMs;
  }

  /// 每日上限判定（按本地日历日）
  static bool exceedsDailyCap(int deliveredOrScheduledToday, int cap) {
    if (cap <= 0) return true;
    return deliveredOrScheduledToday >= cap;
  }

  /// 时区是否变化（用于启动时重排）
  static bool timezoneChanged(String? scheduledTimezone, String current) {
    if (scheduledTimezone == null || scheduledTimezone.trim().isEmpty) {
      return false;
    }
    return scheduledTimezone != current;
  }
}

/// 队列已满（不堆积，明确提示）
class NotificationQueueFullException implements Exception {
  const NotificationQueueFullException(this.limit);

  final int limit;

  @override
  String toString() => '待投递通知已达上限（$limit 条），本条暂不安排';
}
