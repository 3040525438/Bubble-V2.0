// 通知设置与待投递通知仓储（T13.3，FR-IOS-05/06/08）。
// 表：notification_settings（单行）/ scheduled_messages（五态）。
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/notification/notification_models.dart';
import '../database/app_database.dart';

class NotificationRepository {
  NotificationRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();
  static const settingsId = 'default';

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// 读取通知设置（不存在时返回默认值，不写库）
  Future<NotificationSettings> loadSettings() async {
    final row = await (_db.select(
      _db.notificationSettings,
    )..where((t) => t.id.equals(settingsId))).getSingleOrNull();
    if (row == null) return const NotificationSettings();
    return NotificationSettings(
      privacyMode: NotificationPrivacy.fromWire(row.privacyMode),
      allowPostNotify: row.allowPostNotify == 1,
      allowDiaryLetterNotify: row.allowDiaryLetterNotify == 1,
      dailyNotifyCap: row.dailyNotifyCap,
      quietStart: row.quietStart ?? '23:00',
      quietEnd: row.quietEnd ?? '08:00',
      quietTimezone: row.quietTimezone,
      updatedAt: row.updatedAt,
    );
  }

  Future<void> saveSettings(NotificationSettings settings) async {
    await _db
        .into(_db.notificationSettings)
        .insertOnConflictUpdate(
          NotificationSettingsCompanion.insert(
            id: settingsId,
            privacyMode: Value(settings.privacyMode.wire),
            allowPostNotify: Value(settings.allowPostNotify ? 1 : 0),
            allowDiaryLetterNotify: Value(
              settings.allowDiaryLetterNotify ? 1 : 0,
            ),
            dailyNotifyCap: Value(settings.dailyNotifyCap),
            quietStart: Value(settings.quietStart),
            quietEnd: Value(settings.quietEnd),
            quietTimezone: Value(settings.quietTimezone),
            updatedAt: _nowIso(),
          ),
        );
  }

  /// 入队一条待投递通知；队列已满时抛 [NotificationQueueFullException]（不堆积）。
  Future<ScheduledMessage> enqueue({
    required String content,
    required DateTime scheduledAt,
    required String notificationId,
    required String timezone,
    String? conversationId,
    String? messageId,
    String? candidateId,
    String? reason,
    DateTime? expiresAt,
    int queueLimit = NotificationPolicy.queueLimit,
  }) async {
    final active = await activeCount();
    if (active >= queueLimit) {
      throw NotificationQueueFullException(queueLimit);
    }
    final id = _uuid.v4();
    await _db
        .into(_db.scheduledMessages)
        .insert(
          ScheduledMessagesCompanion.insert(
            id: id,
            content: content,
            scheduledAt: scheduledAt.millisecondsSinceEpoch,
            conversationId: Value(conversationId),
            messageId: Value(messageId),
            candidateId: Value(candidateId),
            reason: Value(reason),
            notificationId: Value(notificationId),
            scheduledTimezone: Value(timezone),
            createdAt: _nowIso(),
            expiresAt: Value(expiresAt?.millisecondsSinceEpoch),
          ),
        );
    return (await getById(id))!;
  }

  Future<ScheduledMessage?> getById(String id) => (_db.select(
    _db.scheduledMessages,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<ScheduledMessage>> activeScheduled() {
    return (_db.select(_db.scheduledMessages)
          ..where((t) => t.status.isIn(ScheduledStatus.active.toList()))
          ..orderBy([(t) => OrderingTerm.asc(t.scheduledAt)]))
        .get();
  }

  Future<int> activeCount() async {
    final rows = await activeScheduled();
    return rows.length;
  }

  /// 某本地时间窗内已安排/已投递的通知数（每日上限计数）
  Future<int> countInWindow({required int startMs, required int endMs}) async {
    final rows =
        await (_db.select(_db.scheduledMessages)..where(
              (t) =>
                  t.scheduledAt.isBiggerOrEqualValue(startMs) &
                  t.scheduledAt.isSmallerThanValue(endMs) &
                  t.status.isIn(const [
                    ScheduledStatus.scheduled,
                    ScheduledStatus.delivered,
                  ]),
            ))
            .get();
    return rows.length;
  }

  Future<void> markScheduled(String id) =>
      _setStatus(id, ScheduledStatus.scheduled);

  /// 重排：更新计划时刻、时区与通知标识（时区变化/勿扰顺延）
  Future<void> updateSchedule(
    String id, {
    required DateTime scheduledAt,
    required String timezone,
    String? notificationId,
  }) async {
    await (_db.update(
      _db.scheduledMessages,
    )..where((t) => t.id.equals(id))).write(
      ScheduledMessagesCompanion(
        scheduledAt: Value(scheduledAt.millisecondsSinceEpoch),
        scheduledTimezone: Value(timezone),
        notificationId: notificationId == null
            ? const Value.absent()
            : Value(notificationId),
        status: const Value(ScheduledStatus.scheduled),
      ),
    );
  }

  Future<void> markDelivered(String id, {String? messageId}) async {
    await (_db.update(
      _db.scheduledMessages,
    )..where((t) => t.id.equals(id))).write(
      ScheduledMessagesCompanion(
        status: const Value(ScheduledStatus.delivered),
        messageId: messageId == null ? const Value.absent() : Value(messageId),
      ),
    );
  }

  Future<void> markCancelled(String id) =>
      _setStatus(id, ScheduledStatus.cancelled);

  Future<void> markExpired(String id) =>
      _setStatus(id, ScheduledStatus.expired);

  Future<void> _setStatus(String id, String status) async {
    await (_db.update(_db.scheduledMessages)..where((t) => t.id.equals(id)))
        .write(ScheduledMessagesCompanion(status: Value(status)));
  }

  /// 过期扫描：返回需要取消通知的记录（状态已置 expired）
  Future<List<ScheduledMessage>> expireDue(int nowMs) async {
    final due =
        await (_db.select(_db.scheduledMessages)..where(
              (t) =>
                  t.status.isIn(ScheduledStatus.active.toList()) &
                  t.expiresAt.isNotNull() &
                  t.expiresAt.isSmallerOrEqualValue(nowMs),
            ))
            .get();
    for (final row in due) {
      await markExpired(row.id);
    }
    return due;
  }

  /// 某条消息关联的未投递通知（消息删除时级联取消）
  Future<List<ScheduledMessage>> activeByMessage(String messageId) {
    return (_db.select(_db.scheduledMessages)..where(
          (t) =>
              t.messageId.equals(messageId) &
              t.status.isIn(ScheduledStatus.active.toList()),
        ))
        .get();
  }

  /// 最近记录（设置页/数据中心展示）
  Future<List<ScheduledMessage>> recent({int limit = 30}) {
    return (_db.select(_db.scheduledMessages)
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
  }

  String nowIso() => _nowIso();
}
