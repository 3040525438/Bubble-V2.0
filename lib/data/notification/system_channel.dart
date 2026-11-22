// 系统能力通道（阶段 13）：设备时区等平台信息。
// 后台任务走 bubble/background_task（见 background_task_service.dart）。
import 'package:flutter/services.dart';

class SystemChannel {
  const SystemChannel._();

  static const channelName = 'bubble/system';
  static const _channel = MethodChannel(channelName);

  /// 设备 IANA 时区；通道不可用（如测试/桌面）时回退默认值并明确来源。
  static Future<String> localTimezone({
    String fallback = 'Asia/Shanghai',
  }) async {
    try {
      final value = await _channel.invokeMethod<String>('getTimezone');
      if (value == null || value.trim().isEmpty) return fallback;
      return value;
    } catch (_) {
      return fallback;
    }
  }
}
