// 后台任务桥接服务（T13.1，FR-IOS-01/02/07）：自研 Platform Channel，
// 如实上报「仅 iOS 支持」；所有 submit/start/finish/expired 事件写入 background_task_logs。
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../domain/thinking/thinking_models.dart';
import '../database/app_database.dart';
import '../database/db_provider.dart';
import '../repositories/background_task_log_repository.dart';
import '../thinking/thinking_orchestrator.dart';

/// 提交结果（明确失败原因，不虚构成功）
class BackgroundSubmitResult {
  const BackgroundSubmitResult({required this.ok, required this.reason});

  final bool ok;
  final String reason;
}

class BackgroundTaskService {
  BackgroundTaskService({
    AppDatabase? db,
    MethodChannel? channel,
    BackgroundTaskLogRepository? logs,
    ThinkingOrchestrator? orchestrator,
    bool Function()? isIOS,
    DateTime Function()? clock,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _logs = logs ?? BackgroundTaskLogRepository(db ?? AppDb.instance),
       _orchestrator = orchestrator,
       _isIOS = isIOS ?? (() => defaultTargetPlatform == TargetPlatform.iOS),
       _clock = clock ?? DateTime.now;

  static const channelName = 'bubble/background_task';

  final MethodChannel _channel;
  final BackgroundTaskLogRepository _logs;
  final ThinkingOrchestrator? _orchestrator;
  final bool Function() _isIOS;
  final DateTime Function() _clock;

  /// 注册原生回调（onTaskStart / onTaskExpired）
  void initialize() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    final args = <String, dynamic>{};
    if (call.arguments is Map) {
      args.addAll(Map<String, dynamic>.from(call.arguments as Map));
    }
    final taskId = args['taskId']?.toString() ?? '';
    switch (call.method) {
      case 'onTaskStart':
        final startedAt = _clock().millisecondsSinceEpoch;
        await _log(
          'start',
          taskType: args['taskType']?.toString(),
          payload: args,
        );
        try {
          await _orchestrator?.runNew(
            trigger: ThinkingTrigger.backgroundBgTask,
          );
          await _log('finish', payload: {'taskId': taskId, 'ok': true});
          await completeTask(taskId, success: true);
        } catch (error) {
          await _log('fail', payload: {'taskId': taskId, 'error': '$error'});
          await completeTask(taskId, success: false);
        }
        await _log(
          'finish_meta',
          payload: {'durationMs': _clock().millisecondsSinceEpoch - startedAt},
        );
      case 'onTaskExpired':
        // 中断：Dart 侧每步已落 checkpoint，这里只记录并结束任务
        await _log('expired', payload: args);
        await completeTask(taskId, success: false);
      default:
        await _log('unknown_callback', payload: {'method': call.method});
    }
  }

  Future<BackgroundSubmitResult> submitRefresh({
    Duration earliest = const Duration(minutes: 30),
  }) {
    return _submit('submitRefresh', earliest);
  }

  Future<BackgroundSubmitResult> submitProcessing({
    Duration earliest = const Duration(hours: 6),
  }) {
    return _submit('submitProcessing', earliest);
  }

  Future<BackgroundSubmitResult> _submit(
    String method,
    Duration earliest,
  ) async {
    if (!_isIOS()) {
      const reason = '后台任务仅 iOS 支持（其他平台不伪装可用）';
      await _log('submit_skipped', payload: {'method': method});
      return const BackgroundSubmitResult(ok: false, reason: reason);
    }
    try {
      final result = await _channel.invokeMethod<dynamic>(method, {
        'earliestSeconds': earliest.inSeconds,
      });
      final map = result is Map ? Map<String, dynamic>.from(result) : null;
      final ok = map?['ok'] == true;
      final nextSubmitAt = ok
          ? _clock().add(earliest).millisecondsSinceEpoch
          : null;
      await _log(
        ok ? 'submit' : 'submit_failed',
        payload: {'method': method, 'errorCode': map?['errorCode']},
        nextSubmitAt: nextSubmitAt,
      );
      return BackgroundSubmitResult(
        ok: ok,
        reason: ok ? '已提交后台任务' : '提交失败：${map?['errorCode'] ?? '未知原因'}',
      );
    } on PlatformException catch (error) {
      await _log(
        'submit_failed',
        payload: {
          'method': method,
          'code': error.code,
          'message': error.message,
        },
      );
      return BackgroundSubmitResult(ok: false, reason: '提交失败：${error.code}');
    } on MissingPluginException {
      await _log(
        'submit_failed',
        payload: {'method': method, 'error': 'no_native'},
      );
      return const BackgroundSubmitResult(
        ok: false,
        reason: '原生后台任务通道未注册（需 iOS 真机构建）',
      );
    }
  }

  /// 任务完成后必须回调原生（BGTask 语义：每次执行完都要重新 submit）
  Future<void> completeTask(String taskId, {required bool success}) async {
    if (!_isIOS()) return;
    try {
      await _channel.invokeMethod<void>('completeTask', {
        'taskId': taskId,
        'success': success,
      });
      await _log('complete', payload: {'taskId': taskId, 'success': success});
    } on PlatformException catch (error) {
      await _log(
        'complete_failed',
        payload: {'taskId': taskId, 'error': error.code},
      );
    } on MissingPluginException {
      await _log(
        'complete_failed',
        payload: {'taskId': taskId, 'error': 'no_native'},
      );
    }
  }

  /// 清理 90 天前日志（滚动保留）
  Future<int> purgeOldLogs() => _logs.purgeExpired(now: _clock());

  Future<void> _log(
    String event, {
    String? taskType,
    Map<String, dynamic>? payload,
    int? nextSubmitAt,
  }) async {
    final now = _clock().millisecondsSinceEpoch;
    try {
      await _logs.append(
        event: event,
        taskType: taskType,
        payload: payload,
        startedAt: now,
        finishedAt: event.startsWith('finish') || event == 'complete'
            ? now
            : null,
        nextSubmitAt: nextSubmitAt,
      );
    } catch (error) {
      debugPrint('后台任务日志写入失败：$error');
    }
  }
}
