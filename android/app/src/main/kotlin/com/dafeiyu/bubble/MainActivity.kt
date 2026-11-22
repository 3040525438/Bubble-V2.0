package com.dafeiyu.bubble

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 阶段 13：系统时区（通知预排/会话时区重排）；后台任务仅 iOS 提供
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "bubble/system")
            .setMethodCallHandler { call, result ->
                if (call.method == "getTimezone") {
                    result.success(TimeZone.getDefault().id)
                } else {
                    result.notImplemented()
                }
            }
    }
}
