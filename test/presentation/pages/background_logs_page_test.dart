// 后台任务日志页测试（T13.6）：空态、日志渲染、导出文本。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/background_task_log_repository.dart';
import 'package:bubble/presentation/pages/background_logs_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
  late BackgroundTaskLogRepository logs;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    logs = BackgroundTaskLogRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpPage(WidgetTester tester, {LogExporter? exporter}) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: BubbleTheme.light(),
        home: BackgroundLogsPage(
          repository: logs,
          exporter: exporter,
          clock: () => DateTime(2026, 5, 21, 12),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('空态明确说明只有 iOS 真机才产生日志', (tester) async {
    await pumpPage(tester);
    await pumpUntilFound(tester, find.text('还没有后台任务日志'));
    expect(find.text('还没有后台任务日志'), findsOneWidget);
    expect(find.textContaining('iOS 真机'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('展示事件中文标签与倒序列表', (tester) async {
    await tester.runAsync(() async {
      await logs.append(
        event: 'submit',
        taskType: 'refresh',
        startedAt: DateTime(2026, 5, 21, 11).millisecondsSinceEpoch,
        nextSubmitAt: DateTime(2026, 5, 21, 11, 30).millisecondsSinceEpoch,
      );
      await logs.append(
        event: 'expired',
        taskType: 'processing',
        startedAt: DateTime(2026, 5, 21, 12).millisecondsSinceEpoch,
        payload: {'taskId': 'x'},
      );
    });

    await pumpPage(tester);
    await pumpUntilFound(tester, find.byKey(const ValueKey('bg-logs-list')));
    expect(find.text('提交后台任务'), findsOneWidget);
    expect(find.text('超时中断'), findsOneWidget);
    expect(find.text('refresh'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('导出：通过注入的导出器写出文本并提示路径', (tester) async {
    await tester.runAsync(() async {
      await logs.append(
        event: 'start',
        taskType: 'refresh',
        startedAt: DateTime(2026, 5, 21, 12).millisecondsSinceEpoch,
      );
    });
    String? exported;
    await pumpPage(
      tester,
      exporter: (text, now) async {
        exported = text;
        return '/tmp/bg_task_logs.txt';
      },
    );
    await pumpUntilFound(tester, find.byKey(const ValueKey('bg-logs-export')));

    await tester.tap(find.byKey(const ValueKey('bg-logs-export')));
    await pumpUntilFound(tester, find.textContaining('日志已导出'));

    expect(exported, isNotNull);
    expect(exported, contains('# 泡泡后台任务日志'));
    expect(exported, contains('"event":"start"'));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
