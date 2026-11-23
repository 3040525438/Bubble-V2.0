// 通知设置页测试（T13.5）：隐私三档切换持久化、类别开关、权限状态与队列展示。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/notification_repository.dart';
import 'package:bubble/domain/notification/notification_models.dart';
import 'package:bubble/presentation/pages/notification_settings_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_notification_scheduler.dart';

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 80,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppDatabase db;
  late NotificationRepository repo;
  late FakeNotificationScheduler scheduler;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    repo = NotificationRepository(db);
    scheduler = FakeNotificationScheduler(permission: false);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(950, 1900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: BubbleTheme.light(),
        home: NotificationSettingsPage(
          repository: repo,
          scheduler: scheduler,
          clock: () => DateTime(2026, 5, 21, 12),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('通知里显示什么'));
  }

  testWidgets('默认 minimal，切换完整显示后持久化并更新预览', (tester) async {
    await pumpPage(tester);
    expect(find.text('泡泡有新消息'), findsOneWidget);
    expect(
      (await repo.loadSettings()).privacyMode,
      NotificationPrivacy.minimal,
    );

    await tester.tap(find.byKey(const ValueKey('notif-privacy-full')));
    await tester.pump(const Duration(milliseconds: 150));

    expect((await repo.loadSettings()).privacyMode, NotificationPrivacy.full);
    expect(find.text('泡泡 · 新消息'), findsOneWidget);
    expect(find.textContaining('今天的云像棉花糖'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('关闭说说提醒与日记信件提醒会持久化', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('notif-switch-post')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('notif-switch-diary')));
    await tester.pump(const Duration(milliseconds: 150));

    final settings = await repo.loadSettings();
    expect(settings.allowPostNotify, isFalse);
    expect(settings.allowDiaryLetterNotify, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('权限未开启时显示提示与开启按钮', (tester) async {
    await pumpPage(tester);
    expect(find.text('通知未开启'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notif-permission-action')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('notif-permission-action')));
    await tester.pump(const Duration(milliseconds: 150));
    // 假调度器未授权：保持「未开启」并给出说明
    expect(find.text('通知未开启'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('测试通知按钮安排 3 秒后的聊天通知', (tester) async {
    scheduler = FakeNotificationScheduler(permission: true);
    await pumpPage(tester);

    await tester.tap(find.byKey(const ValueKey('notif-test-send')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(scheduler.scheduled, hasLength(1));
    final plan = scheduler.scheduled.single;
    expect(plan.payload.type, 'chat');
    expect(plan.fireAt, DateTime(2026, 5, 21, 12, 0, 3));
    expect(find.text('已安排，3 秒后到达；请回到桌面查看，点击通知会打开聊天'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('平台不支持通知时如实说明，不显示开启按钮', (tester) async {
    scheduler.supportedValue = false;
    await pumpPage(tester);
    expect(find.text('当前平台不支持本地通知'), findsOneWidget);
    expect(find.byKey(const ValueKey('notif-permission-action')), findsNothing);
    expect(find.textContaining('待投递 0 / 20'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
