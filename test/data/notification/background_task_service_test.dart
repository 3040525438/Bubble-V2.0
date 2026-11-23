// 后台任务桥接单测（T13.1/T13.6）：仅 iOS 上报、提交参数、原生回调与日志留痕。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/notification/background_task_service.dart';
import 'package:bubble/data/repositories/background_task_log_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(BackgroundTaskService.channelName);
  final codec = const StandardMethodCodec();
  final calls = <MethodCall>[];

  late AppDatabase db;
  late BackgroundTaskLogRepository logs;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    logs = BackgroundTaskLogRepository(db);
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'submitRefresh' ||
              call.method == 'submitProcessing') {
            return {'ok': true};
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
  });

  /// 模拟原生 → Dart 回调
  Future<void> nativeCall(String method, Map<String, dynamic> args) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          BackgroundTaskService.channelName,
          codec.encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('非 iOS：提交被明确跳过并留日志', () async {
    final service = BackgroundTaskService(
      logs: logs,
      isIOS: () => false,
      clock: () => DateTime(2026, 5, 21, 12),
    );
    final result = await service.submitRefresh();
    expect(result.ok, isFalse);
    expect(result.reason, contains('仅 iOS'));
    expect(calls, isEmpty);
    final rows = await logs.recent();
    expect(rows.single.event, 'submit_skipped');
  });

  test('iOS 提交：传递 earliestSeconds 并记录下一次时间', () async {
    final service = BackgroundTaskService(
      logs: logs,
      isIOS: () => true,
      clock: () => DateTime(2026, 5, 21, 12),
    );
    final result = await service.submitProcessing(
      earliest: const Duration(hours: 6),
    );
    expect(result.ok, isTrue);
    expect(calls.single.method, 'submitProcessing');
    expect(calls.single.arguments['earliestSeconds'], 6 * 3600);
    final rows = await logs.recent();
    final row = rows.firstWhere((r) => r.event == 'submit');
    expect(row.nextSubmitAt, isNotNull);
  });

  test('原生 onTaskStart：写 start/finish 并回传 completeTask', () async {
    final service = BackgroundTaskService(
      logs: logs,
      isIOS: () => true,
      clock: () => DateTime(2026, 5, 21, 12),
    );
    service.initialize();
    await nativeCall('onTaskStart', {
      'taskId': 'com.dafeiyu.bubble.test.refresh',
      'taskType': 'refresh',
    });

    final events = (await logs.recent()).map((r) => r.event).toSet();
    expect(events, containsAll(['start', 'finish', 'complete']));
    final complete = calls.lastWhere((c) => c.method == 'completeTask');
    expect(complete.arguments['success'], isTrue);
    expect(complete.arguments['taskId'], 'com.dafeiyu.bubble.test.refresh');
  });

  test('原生 onTaskExpired：记录中断并结束失败', () async {
    final service = BackgroundTaskService(
      logs: logs,
      isIOS: () => true,
      clock: () => DateTime(2026, 5, 21, 12),
    );
    service.initialize();
    await nativeCall('onTaskExpired', {
      'taskId': 'task-1',
      'taskType': 'processing',
    });

    final events = (await logs.recent()).map((r) => r.event).toSet();
    expect(events, containsAll(['expired', 'complete']));
    final complete = calls.lastWhere((c) => c.method == 'completeTask');
    expect(complete.arguments['success'], isFalse);
  });

  test('BGTaskScheduler Code=3：归为跳过并给出可读原因', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return {
            'ok': false,
            'errorCode':
                'Error Domain=BGTaskSchedulerErrorDomain Code=3 "(null)"',
          };
        });
    final service = BackgroundTaskService(logs: logs, isIOS: () => true);

    final result = await service.submitRefresh();

    expect(result.ok, isFalse);
    expect(result.reason, contains('系统暂不提供后台刷新'));
    final row = (await logs.recent()).single;
    expect(row.event, 'submit_skipped');
    expect(row.payload, contains('系统暂不提供后台刷新'));
  });

  test('错误码映射：1/2/3 与未知', () {
    expect(
      BackgroundTaskService.describeBackgroundError('Code=1'),
      contains('未获许可'),
    );
    expect(
      BackgroundTaskService.describeBackgroundError('Code=2'),
      contains('已有待执行'),
    );
    expect(
      BackgroundTaskService.describeBackgroundError(
        'Error Domain=BGTaskSchedulerErrorDomain Code=3 "(null)"',
      ),
      contains('系统暂不提供'),
    );
    expect(
      BackgroundTaskService.describeBackgroundError(null),
      contains('未获得系统机会'),
    );
    expect(BackgroundTaskService.isTemporaryUnavailable('Code=3'), isTrue);
    expect(BackgroundTaskService.isTemporaryUnavailable('Code=1'), isFalse);
  });
}
