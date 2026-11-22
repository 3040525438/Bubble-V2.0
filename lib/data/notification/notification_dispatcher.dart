// 通知投递编排（T13.3）：消息已落库 → 受隐私/开关/勿扰/上限/队列约束 → 预排本地通知。
// 职责边界：本类不生成内容、不改消息；只负责 scheduled_messages 与系统通知的一致性。
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../domain/notification/notification_models.dart';
import '../database/app_database.dart';
import '../repositories/background_task_log_repository.dart';
import '../repositories/notification_repository.dart';
import 'notification_scheduler.dart';

/// 一次通知安排的结果（明确失败原因，不假装成功）
class NotificationDispatchResult {
  const NotificationDispatchResult({
    required this.ok,
    required this.reason,
    this.scheduledId,
    this.notificationId,
    this.fireAt,
  });

  final bool ok;
  final String reason;
  final String? scheduledId;
  final String? notificationId;
  final DateTime? fireAt;

  static NotificationDispatchResult skipped(String reason) =>
      NotificationDispatchResult(ok: false, reason: reason);

  static NotificationDispatchResult failed(String reason) =>
      NotificationDispatchResult(ok: false, reason: reason);
}

class NotificationDispatcher {
  NotificationDispatcher(
    AppDatabase db, {
    NotificationRepository? repository,
    NotificationScheduler? scheduler,
    BackgroundTaskLogRepository? logs,
    DateTime Function()? clock,
    String Function()? timezone,
  }) : _repository = repository ?? NotificationRepository(db),
       _scheduler = scheduler ?? const NoopNotificationScheduler(),
       _logs = logs ?? BackgroundTaskLogRepository(db),
       _clock = clock ?? DateTime.now,
       _timezone = timezone ?? (() => 'Asia/Shanghai');

  final NotificationRepository _repository;
  final NotificationScheduler _scheduler;
  final BackgroundTaskLogRepository _logs;
  final DateTime Function() _clock;
  final String Function() _timezone;
  static const _uuid = Uuid();

  NotificationRepository get repository => _repository;
  NotificationScheduler get scheduler => _scheduler;

  Future<void> initialize({required void Function(String? payload) onTap}) =>
      _scheduler.initialize(onTap: onTap);

  /// 为一条已落库内容预排通知。
  ///
  /// [deliverableType]：chat / post / diary / letter（决定开关与深链）；
  /// [messageId]：聊天消息 id（点击后锚定）；[targetId]：post/diary/letter 实体 id。
  Future<NotificationDispatchResult> dispatch({
    required String content,
    required String deliverableType,
    required String sourceLabel,
    String? conversationId,
    String? messageId,
    String? targetId,
    String? candidateId,
    String? reason,
    Duration delay = const Duration(minutes: 1),
    DateTime? expiresAt,
  }) async {
    if (!_scheduler.supported) {
      return NotificationDispatchResult.skipped('当前平台不支持本地通知');
    }
    final settings = await _repository.loadSettings();
    if (!settings.allowsKind(deliverableType)) {
      await _log('notify_skipped', {
        'reason': 'kind_disabled',
        'type': deliverableType,
      });
      return NotificationDispatchResult.skipped('该类提醒已在设置中关闭');
    }

    final now = _clock();
    var fireAt = now.add(delay);
    fireAt = NotificationPolicy.deferOutOfQuietHours(
      fireAt,
      settings.quietStart,
      settings.quietEnd,
    );
    final expiresAtMs = expiresAt?.millisecondsSinceEpoch;
    if (NotificationPolicy.isExpired(expiresAtMs, fireAt)) {
      await _log('notify_skipped', {
        'reason': 'expired',
        'type': deliverableType,
      });
      return NotificationDispatchResult.skipped('内容已过期，不再提醒');
    }

    // 每日上限：按投递日（本地日历日）统计
    final dayStart = DateTime(fireAt.year, fireAt.month, fireAt.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final usedToday = await _repository.countInWindow(
      startMs: dayStart.millisecondsSinceEpoch,
      endMs: dayEnd.millisecondsSinceEpoch,
    );
    if (NotificationPolicy.exceedsDailyCap(
      usedToday,
      settings.dailyNotifyCap,
    )) {
      await _log('notify_skipped', {'reason': 'daily_cap', 'used': usedToday});
      return NotificationDispatchResult.skipped(
        '今天已经提醒 ${settings.dailyNotifyCap} 次了，明天再说',
      );
    }

    // 同一条消息不重复安排
    if (messageId != null) {
      final existing = await _repository.activeByMessage(messageId);
      if (existing.isNotEmpty) {
        return NotificationDispatchResult.skipped('这条消息已经在待投递队列里');
      }
    }

    final rendered = renderNotification(
      privacy: settings.privacyMode,
      sourceLabel: sourceLabel,
      messageText: content,
    );
    final notificationId = _uuid.v4();
    final type = deliverableType == 'letter_draft' ? 'letter' : deliverableType;
    final payload = NotificationPayload(
      type: type,
      conversationId: conversationId,
      messageId: messageId,
      targetId: targetId,
    );
    // reason 列复用为 JSON 元数据（type/targetId/说明），供重排与来源识别
    final reasonMeta = jsonEncode({
      'type': type,
      'targetId': targetId,
      'note': reason,
    });

    final ScheduledMessage row;
    try {
      row = await _repository.enqueue(
        content: content,
        scheduledAt: fireAt,
        notificationId: notificationId,
        timezone: _timezone(),
        conversationId: conversationId,
        messageId: messageId,
        candidateId: candidateId,
        reason: reasonMeta,
        expiresAt: expiresAt,
      );
    } on NotificationQueueFullException catch (error) {
      await _log('notify_skipped', {
        'reason': 'queue_full',
        'limit': error.limit,
      });
      return NotificationDispatchResult.skipped(error.toString());
    }

    try {
      await _scheduler.schedule(
        NotificationPlan(
          notificationId: notificationId,
          fireAt: fireAt,
          title: rendered.title,
          body: rendered.body,
          payload: payload,
        ),
      );
      await _repository.markScheduled(row.id);
      await _log('notify_scheduled', {
        'scheduledId': row.id,
        'type': deliverableType,
        'fireAt': fireAt.toIso8601String(),
        'privacy': settings.privacyMode.wire,
      });
      return NotificationDispatchResult(
        ok: true,
        reason: '已安排提醒',
        scheduledId: row.id,
        notificationId: notificationId,
        fireAt: fireAt,
      );
    } catch (error) {
      // 权限关闭/平台异常：不重试、不假装成功；消息本身已落库不受影响（FR-IOS-08）
      await _repository.markCancelled(row.id);
      await _log('notify_failed', {'scheduledId': row.id, 'error': '$error'});
      return NotificationDispatchResult.failed('通知未能安排：$error');
    }
  }

  /// 过期扫描：把过期记录置 expired 并取消通知
  Future<int> reconcileExpired() async {
    final due = await _repository.expireDue(_clock().millisecondsSinceEpoch);
    for (final row in due) {
      if (row.notificationId != null) {
        await _scheduler.cancel(row.notificationId!);
      }
      await _log('notify_expired', {'scheduledId': row.id});
    }
    return due.length;
  }

  /// 恢复时重排：时区变化或勿扰窗口变化导致计划时刻需要调整
  Future<int> reschedulePending() async {
    if (!_scheduler.supported) return 0;
    final rows = await _repository.activeScheduled();
    if (rows.isEmpty) return 0;
    final settings = await _repository.loadSettings();
    final currentTz = _timezone();
    var changed = 0;
    for (final row in rows) {
      final originalLocal = DateTime.fromMillisecondsSinceEpoch(
        row.scheduledAt,
      );
      final target = NotificationPolicy.deferOutOfQuietHours(
        originalLocal,
        settings.quietStart,
        settings.quietEnd,
      );
      final timezoneChanged = NotificationPolicy.timezoneChanged(
        row.scheduledTimezone,
        currentTz,
      );
      if (!timezoneChanged && target == originalLocal) continue;
      if (row.notificationId != null) {
        await _scheduler.cancel(row.notificationId!);
      }
      final notificationId = _uuid.v4();
      final meta = _metaOf(row);
      final rendered = renderNotification(
        privacy: settings.privacyMode,
        sourceLabel: _sourceLabelOf(meta.type),
        messageText: row.content,
      );
      final payload = NotificationPayload(
        type: meta.type,
        conversationId: row.conversationId,
        messageId: row.messageId,
        targetId: meta.targetId,
      );
      try {
        await _scheduler.schedule(
          NotificationPlan(
            notificationId: notificationId,
            fireAt: target,
            title: rendered.title,
            body: rendered.body,
            payload: payload,
          ),
        );
        await _repository.updateSchedule(
          row.id,
          scheduledAt: target,
          timezone: currentTz,
          notificationId: notificationId,
        );
        changed++;
        await _log('notify_rescheduled', {
          'scheduledId': row.id,
          'from': originalLocal.toIso8601String(),
          'to': target.toIso8601String(),
          'timezoneChanged': timezoneChanged,
        });
      } catch (error) {
        await _repository.markCancelled(row.id);
        await _log('notify_failed', {'scheduledId': row.id, 'error': '$error'});
      }
    }
    return changed;
  }

  /// 消息删除联动取消（FR-IOS-06）
  Future<int> cancelForMessage(String messageId) async {
    final rows = await _repository.activeByMessage(messageId);
    for (final row in rows) {
      if (row.notificationId != null) {
        await _scheduler.cancel(row.notificationId!);
      }
      await _repository.markCancelled(row.id);
      await _log('notify_cancelled', {'scheduledId': row.id});
    }
    return rows.length;
  }

  /// 应用回到前台：读取当前权限状态（供设置页展示，不主动请求）
  Future<bool> notificationsEnabled() => _scheduler.isEnabled();

  Future<bool> requestPermission() => _scheduler.requestPermission();

  Future<NotificationSettings> loadSettings() => _repository.loadSettings();

  Future<void> saveSettings(NotificationSettings settings) =>
      _repository.saveSettings(settings);

  ({String type, String? targetId, String? note}) _metaOf(
    ScheduledMessage row,
  ) {
    final raw = row.reason;
    if (raw != null && raw.trim().startsWith('{')) {
      try {
        final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        return (
          type: (map['type'] ?? 'chat').toString(),
          targetId: map['targetId']?.toString(),
          note: map['note']?.toString(),
        );
      } catch (_) {
        // 旧格式/损坏 JSON 时回退聊天
      }
    }
    return (type: 'chat', targetId: null, note: raw);
  }

  String _sourceLabelOf(String type) {
    switch (type) {
      case 'post':
        return '说说';
      case 'diary':
        return '日记';
      case 'letter':
        return '信件';
      default:
        return '新消息';
    }
  }

  Future<void> _log(String event, Map<String, dynamic> payload) async {
    try {
      await _logs.append(event: event, payload: payload);
    } catch (error) {
      // 日志失败不影响通知主流程
      debugPrint('通知日志写入失败：$error');
    }
  }
}
