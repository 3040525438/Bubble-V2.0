// 通知投递编排单测（T13.3）：隐私渲染、勿扰顺延、开关、每日上限、队列、失败、
// 过期、删除联动与时区重排。全部使用假调度器，不触碰系统通知。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/notification/notification_dispatcher.dart';
import 'package:bubble/data/repositories/notification_repository.dart';
import 'package:bubble/domain/notification/notification_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_notification_scheduler.dart';

void main() {
  late AppDatabase db;
  late NotificationRepository repo;
  late FakeNotificationScheduler scheduler;
  late DateTime now;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = NotificationRepository(db);
    scheduler = FakeNotificationScheduler();
    now = DateTime(2026, 5, 21, 12, 0);
  });

  tearDown(() async {
    await db.close();
  });

  NotificationDispatcher build({String timezone = 'Asia/Shanghai'}) {
    return NotificationDispatcher(
      db,
      scheduler: scheduler,
      clock: () => now,
      timezone: () => timezone,
    );
  }

  Future<NotificationDispatchResult> dispatch(
    NotificationDispatcher dispatcher, {
    String type = 'chat',
    String? messageId = 'm1',
    String content = '今天的云很好看',
    Duration delay = const Duration(minutes: 1),
    DateTime? expiresAt,
  }) {
    return dispatcher.dispatch(
      content: content,
      deliverableType: type,
      sourceLabel: '新消息',
      conversationId: 'c1',
      messageId: messageId,
      targetId: messageId,
      delay: delay,
      expiresAt: expiresAt,
    );
  }

  test('正常安排：入队 scheduled 且用于系统通知', () async {
    final dispatcher = build();
    final result = await dispatch(dispatcher);

    expect(result.ok, isTrue);
    expect(result.fireAt, now.add(const Duration(minutes: 1)));
    expect(scheduler.scheduled.length, 1);
    // 默认 minimal：不泄露内容
    expect(scheduler.scheduled.single.title, '泡泡有新消息');
    expect(scheduler.scheduled.single.body, isEmpty);

    final rows = await repo.recent();
    expect(rows.single.status, ScheduledStatus.scheduled);
    expect(rows.single.messageId, 'm1');
    expect(rows.single.notificationId, result.notificationId);
  });

  test('full 隐私模式渲染来源与摘要', () async {
    await repo.saveSettings(
      const NotificationSettings(privacyMode: NotificationPrivacy.full),
    );
    final dispatcher = build();
    final result = await dispatch(dispatcher);
    expect(result.ok, isTrue);
    final plan = scheduler.scheduled.single;
    expect(plan.title, '泡泡 · 新消息');
    expect(plan.body, '今天的云很好看');
    expect(
      NotificationPayload.tryDecode(plan.payload.encode())?.messageId,
      'm1',
    );
  });

  test('深夜通知顺延到勿扰结束（次日 08:00）', () async {
    now = DateTime(2026, 5, 21, 23, 30);
    final dispatcher = build();
    await dispatch(dispatcher);
    final fireAt = scheduler.scheduled.single.fireAt;
    expect(fireAt, DateTime(2026, 5, 22, 8, 0));
  });

  test('类别开关关闭时不安排提醒', () async {
    await repo.saveSettings(const NotificationSettings(allowPostNotify: false));
    final dispatcher = build();
    final result = await dispatch(dispatcher, type: 'post', messageId: null);
    expect(result.ok, isFalse);
    expect(result.reason, contains('关闭'));
    expect(scheduler.scheduled, isEmpty);
  });

  test('每日上限：达到后跳过并说明原因', () async {
    await repo.saveSettings(const NotificationSettings(dailyNotifyCap: 1));
    final dispatcher = build();
    final first = await dispatch(dispatcher, messageId: 'a');
    expect(first.ok, isTrue);
    final second = await dispatch(dispatcher, messageId: 'b');
    expect(second.ok, isFalse);
    expect(second.reason, contains('今天'));
    expect(scheduler.scheduled.length, 1);
  });

  test('队列满：不堆积，明确跳过', () async {
    for (var i = 0; i < NotificationPolicy.queueLimit; i++) {
      await repo.enqueue(
        content: '占位 $i',
        scheduledAt: now.add(Duration(minutes: i + 5)),
        notificationId: 'n-$i',
        timezone: 'Asia/Shanghai',
        messageId: 'pre-$i',
      );
    }
    final dispatcher = build();
    final result = await dispatch(dispatcher, messageId: 'new');
    expect(result.ok, isFalse);
    expect(result.reason, contains('上限'));
    expect(scheduler.scheduled, isEmpty);
  });

  test('同一条消息不重复安排', () async {
    final dispatcher = build();
    expect((await dispatch(dispatcher, messageId: 'm1')).ok, isTrue);
    final again = await dispatch(dispatcher, messageId: 'm1');
    expect(again.ok, isFalse);
    expect(again.reason, contains('队列'));
    expect(scheduler.scheduled.length, 1);
  });

  test('调度失败（权限关闭）：记录 cancelled，不假装成功', () async {
    scheduler.failSchedule = true;
    final dispatcher = build();
    final result = await dispatch(dispatcher);
    expect(result.ok, isFalse);
    expect(result.reason, contains('未能安排'));
    final rows = await repo.recent();
    expect(rows.single.status, ScheduledStatus.cancelled);
  });

  test('已过期内容不安排', () async {
    final dispatcher = build();
    final result = await dispatch(
      dispatcher,
      expiresAt: now.subtract(const Duration(minutes: 1)),
    );
    expect(result.ok, isFalse);
    expect(result.reason, contains('过期'));
    expect(scheduler.scheduled, isEmpty);
  });

  test('过期扫描取消系统通知并置 expired', () async {
    final row = await repo.enqueue(
      content: '旧消息',
      scheduledAt: now.add(const Duration(minutes: 30)),
      notificationId: 'n-old',
      timezone: 'Asia/Shanghai',
      messageId: 'm-old',
      expiresAt: now.subtract(const Duration(minutes: 1)),
    );
    await repo.markScheduled(row.id);
    final dispatcher = build();
    final count = await dispatcher.reconcileExpired();
    expect(count, 1);
    expect(scheduler.cancelled, ['n-old']);
    expect((await repo.getById(row.id))!.status, ScheduledStatus.expired);
  });

  test('消息删除联动取消未投递通知', () async {
    final dispatcher = build();
    await dispatch(dispatcher, messageId: 'm-del');
    final cancelled = await dispatcher.cancelForMessage('m-del');
    expect(cancelled, 1);
    expect(scheduler.cancelled, hasLength(1));
    final row = (await repo.recent()).single;
    expect(row.status, ScheduledStatus.cancelled);
  });

  test('时区变化时重排并更新记录', () async {
    final dispatcher = build(timezone: 'Asia/Shanghai');
    final result = await dispatch(dispatcher);
    expect(result.ok, isTrue);
    final originalNotification = result.notificationId;

    final berlin = build(timezone: 'Europe/Berlin');
    final changed = await berlin.reschedulePending();
    expect(changed, 1);
    expect(scheduler.cancelled, contains(originalNotification));

    final row = (await repo.recent()).single;
    expect(row.scheduledTimezone, 'Europe/Berlin');
    expect(row.notificationId, isNot(originalNotification));
    expect(row.status, ScheduledStatus.scheduled);
  });

  test('不支持通知的平台如实跳过', () async {
    scheduler.supportedValue = false;
    final dispatcher = build();
    final result = await dispatch(dispatcher);
    expect(result.ok, isFalse);
    expect(result.reason, contains('不支持'));
    expect(await repo.activeCount(), 0);
  });
}
