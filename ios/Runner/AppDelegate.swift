import BackgroundTasks
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// 自研 BGTask 桥接（阶段 13）：Flutter 侧通过 bubble/background_task 提交与结束任务。
  private var backgroundChannel: FlutterMethodChannel?
  private var systemChannel: FlutterMethodChannel?
  private var pendingTasks: [String: BGTask] = [:]

  /// 固定任务标识：不随 Bundle ID 变化。
  /// 未签名 IPA 经第三方（爱思助手等）重签后 Bundle ID 可能被改写，
  /// 若运行期用 Bundle ID 拼接而 Info.plist 是构建期展开值，两者不一致会导致
  /// BGTaskScheduler 返回 Code=3（unavailable）。固定值可彻底规避该问题。
  private let refreshIdentifier = "com.dafeiyu.bubble.bgtask.refresh"
  private let processingIdentifier = "com.dafeiyu.bubble.bgtask.processing"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    registerBackgroundTasks()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// 必须在启动完成前注册，否则系统不会回调（Info.plist 的
  /// BGTaskSchedulerPermittedIdentifiers 需与这里完全一致）。
  private func registerBackgroundTasks() {
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: refreshIdentifier,
      using: nil
    ) { [weak self] task in
      self?.handle(task: task, type: "refresh")
    }
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: processingIdentifier,
      using: nil
    ) { [weak self] task in
      self?.handle(task: task, type: "processing")
    }
  }

  private func handle(task: BGTask, type: String) {
    pendingTasks[task.identifier] = task
    // 系统即将超时：通知 Flutter 侧中断（Dart 每步已写 checkpoint）
    task.expirationHandler = { [weak self] in
      self?.backgroundChannel?.invokeMethod(
        "onTaskExpired",
        arguments: ["taskId": task.identifier, "taskType": type]
      )
    }
    guard let channel = backgroundChannel else {
      task.setTaskCompleted(success: false)
      return
    }
    channel.invokeMethod(
      "onTaskStart",
      arguments: ["taskId": task.identifier, "taskType": type]
    )
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "BubbleBackground"
    ) else {
      return
    }
    let messenger = registrar.messenger()

    let background = FlutterMethodChannel(
      name: "bubble/background_task",
      binaryMessenger: messenger
    )
    background.setMethodCallHandler { [weak self] call, result in
      self?.handleBackgroundCall(call, result: result)
    }
    backgroundChannel = background

    // 系统时区（用于通知预排与会话时区重排，不依赖第三方插件）
    let system = FlutterMethodChannel(
      name: "bubble/system",
      binaryMessenger: messenger
    )
    system.setMethodCallHandler { call, result in
      if call.method == "getTimezone" {
        result(TimeZone.current.identifier)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    systemChannel = system
  }

  private func handleBackgroundCall(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "submitRefresh":
      result(submitRefresh(earliestSeconds: seconds(from: call)))
    case "submitProcessing":
      result(submitProcessing(earliestSeconds: seconds(from: call)))
    case "completeTask":
      let args = call.arguments as? [String: Any] ?? [:]
      let taskId = args["taskId"] as? String ?? ""
      let success = args["success"] as? Bool ?? false
      if let task = pendingTasks.removeValue(forKey: taskId) {
        task.setTaskCompleted(success: success)
      }
      // BGTask 语义：每次执行完都要重新提交下一次（否则不会再被调度）
      _ = submitRefresh(earliestSeconds: 30 * 60)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func seconds(from call: FlutterMethodCall) -> TimeInterval {
    let args = call.arguments as? [String: Any] ?? [:]
    return TimeInterval(args["earliestSeconds"] as? Int ?? 1800)
  }

  private func submitRefresh(earliestSeconds: TimeInterval) -> [String: Any] {
    let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: earliestSeconds)
    do {
      try BGTaskScheduler.shared.submit(request)
      return ["ok": true]
    } catch {
      return ["ok": false, "errorCode": "\(error)"]
    }
  }

  private func submitProcessing(earliestSeconds: TimeInterval) -> [String: Any] {
    let request = BGProcessingTaskRequest(identifier: processingIdentifier)
    request.requiresNetworkConnectivity = false
    request.requiresExternalPower = false
    request.earliestBeginDate = Date(timeIntervalSinceNow: earliestSeconds)
    do {
      try BGTaskScheduler.shared.submit(request)
      return ["ok": true]
    } catch {
      return ["ok": false, "errorCode": "\(error)"]
    }
  }
}
