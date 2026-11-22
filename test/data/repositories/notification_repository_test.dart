// 通知仓储单测（T13.3）：设置持久化、队列上限、状态机、每日计数、过期与重排。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/notification_repository.dart';
import 'package:bubble/domain/notification/notification_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late NotificationRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = NotificationRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<ScheduledMessage> enqueue({
    String messageId = 'm1',
    DateTime? at,
    DateTime? expiresAt,
    int queueLimit = NotificationPolicy.queueLimit,
  }) {
    return repo.enqueue(
      content: '内容',
      scheduledAt: at ?? DateTime(2026, 5, 21, 12),
      notificationId: 'n-${DateTime.now().microsecondsSinceEpoch}',
      timezone: 'Asia/Shanghai',
      conversationId: 'c1',
      messageId: messageId,
      reason: '{"type":"chat"}',
      expiresAt: expiresAt,
      queueLimit: queueLimit,
    );
  }

  test('未保存时返回默认设置（minimal / 10 条 / 23:00-08:00）', () async {
    final settings = await repo.loadSettings();
    expect(settings.privacyMode, NotificationPrivacy.minimal);
    expect(settings.dailyNotifyCap, 10);
    expect(settings.quietStart, '23:00');
    expect(settings.quietEnd, '08:00');
    expect(settings.allowPostNotify, isTrue);
  });

  test('保存并读回通知设置', () async {
    await repo.saveSettings(
      const NotificationSettings(
        privacyMode: NotificationPrivacy.full,
        allowPostNotify: false,
        allowDiaryLetterNotify: false,
        dailyNotifyCap: 3,
        quietStart: '22:30',
        quietEnd: '07:30',
        quietTimezone: 'Asia/Shanghai',
      ),
    );
    final settings = await repo.loadSettings();
    expect(settings.privacyMode, NotificationPrivacy.full);
    expect(settings.allowPostNotify, isFalse);
    expect(settings.allowDiaryLetterNotify, isFalse);
    expect(settings.dailyNotifyCap, 3);
    expect(settings.quietStart, '22:30');
    expect(settings.quietEnd, '07:30');
    expect(settings.updatedAt, isNotNull);
  });

  test('入队初始 pending，可用状态机推进', () async {
    final row = await enqueue();
    expect(row.status, ScheduledStatus.pending);
    expect(await repo.activeCount(), 1);

    await repo.markScheduled(row.id);
    expect((await repo.getById(row.id))!.status, ScheduledStatus.scheduled);

    await repo.markDelivered(row.id);
    expect((await repo.getById(row.id))!.status, ScheduledStatus.delivered);
    expect(await repo.activeCount(), 0);
  });

  test('队列上限：达到上限后抛 NotificationQueueFullException', () async {
    await enqueue(queueLimit: 1);
    await expectLater(
      enqueue(queueLimit: 1),
      throwsA(isA<NotificationQueueFullException>()),
    );
  });

  test('每日计数窗口只统计 scheduled/delivered', () async {
    final a = await enqueue(messageId: 'a');
    await repo.markScheduled(a.id);
    final b = await enqueue(messageId: 'b');
    await repo.markCancelled(b.id);
    final c = await enqueue(messageId: 'c');

    final count = await repo.countInWindow(
      startMs: DateTime(2026, 5, 21).millisecondsSinceEpoch,
      endMs: DateTime(2026, 5, 22).millisecondsSinceEpoch,
    );
    expect(count, 1, reason: 'pending(c) 与 cancelled(b) 不计入已安排');

    await repo.markScheduled(c.id);
    expect(
      await repo.countInWindow(
        startMs: DateTime(2026, 5, 21).millisecondsSinceEpoch,
        endMs: DateTime(2026, 5, 22).millisecondsSinceEpoch,
      ),
      2,
    );
  });

  test('过期扫描：只处理已过期且仍 active 的记录', () async {
    final expired = await enqueue(
      messageId: 'expired',
      expiresAt: DateTime(2026, 5, 21, 11),
    );
    await repo.markScheduled(expired.id);
    final future = await enqueue(
      messageId: 'future',
      expiresAt: DateTime(2026, 5, 21, 20),
    );
    await repo.markScheduled(future.id);
    final noExpiry = await enqueue(messageId: 'none');
    await repo.markScheduled(noExpiry.id);

    final due = await repo.expireDue(
      DateTime(2026, 5, 21, 12).millisecondsSinceEpoch,
    );
    expect(due.map((e) => e.id), [expired.id]);
    expect((await repo.getById(expired.id))!.status, ScheduledStatus.expired);
    expect((await repo.getById(future.id))!.status, ScheduledStatus.scheduled);
    expect(
      (await repo.getById(noExpiry.id))!.status,
      ScheduledStatus.scheduled,
    );
  });

  test('按消息查询与重排更新时区/标识', () async {
    final row = await enqueue(messageId: 'm9');
    await repo.markScheduled(row.id);
    final byMessage = await repo.activeByMessage('m9');
    expect(byMessage.single.id, row.id);
    expect(await repo.activeByMessage('other'), isEmpty);

    await repo.updateSchedule(
      row.id,
      scheduledAt: DateTime(2026, 5, 21, 15),
      timezone: 'Europe/Berlin',
      notificationId: 'n-new',
    );
    final updated = (await repo.getById(row.id))!;
    expect(
      updated.scheduledAt,
      DateTime(2026, 5, 21, 15).millisecondsSinceEpoch,
    );
    expect(updated.scheduledTimezone, 'Europe/Berlin');
    expect(updated.notificationId, 'n-new');
  });
}
