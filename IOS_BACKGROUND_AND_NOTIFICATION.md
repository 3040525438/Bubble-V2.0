# 泡泡 Bubble V2.0 — iOS 后台任务与本地通知（IOS_BACKGROUND_AND_NOTIFICATION）

> 本项目最重要的技术风险专项（需求第四章全文逐条落实）。核心立场：**诚实标注 iOS 的能力边界，不承诺系统不保证的事**。

---

## 1. 三种能力严格区分（FR-IOS-01）

| 能力 | 机制 | 何时发生 | 保证程度 |
| -- | -- | -- | -- |
| A. 前台自主思考 | App 运行中，Dart 直接执行完整思考流水线 | 用户打开 App 期间（含定时器触发） | **完全可控** |
| B. 后台自主思考 | BGTaskScheduler（BGAppRefreshTask + BGProcessingTask） | App 退后台后，由 iOS 择时给机会 | **尽力而为**：iOS 决定是否/何时执行；earliestBeginDate 仅是下限；执行时长有限（刷新任务约 30s 级，处理任务可达数分钟，均为系统裁量） |
| C. 划掉后通知投递 | 消息先落 SQLite → UNUserNotificationCenter 预排本地通知 | 用户强退 App 后 | **调度不依赖 App 进程**：已安排的本地通知的投递由 iOS 系统负责，App 被强退/终止后仍会执行调度；但**实际展示受 iOS 通知权限、专注模式、系统通知设置影响，不承诺任何情况下绝对送达**（用户修订 5 措辞） |

**绝对不做**：不滥用后台音频/VOIP/位置等伪后台模式绕过系统限制（FR-IOS-02 精神；且审核/签名风险高）。

## 2. BGTaskScheduler 实施方案

### 2.1 任务标识与注册

```
Info.plist（完整示例，实验版 Bundle ID）:
  UIBackgroundModes:
    - processing
  BGTaskSchedulerPermittedIdentifiers:
    - com.dafeiyu.bubble.bgtask.refresh
    - com.dafeiyu.bubble.bgtask.processing
  <!-- 注意：BGTaskSchedulerPermittedIdentifiers 中的每个 ID 必须与代码注册的
      identifier 完全一致（含大小写），不一致时 submit 返回
      BGTaskSchedulerErrorDomain Code=3 (unavailable)。
      因此这里使用「固定标识」而不拼接 Bundle ID：未签名 IPA 经爱思助手等
      第三方重签时 Bundle ID 可能被改写，而 plist 中的 $(PRODUCT_BUNDLE_IDENTIFIER)
      是构建期展开值，运行期 Bundle.main.bundleIdentifier 会变化，两者不一致即触发 Code=3。 -->
```

AppDelegate didFinishLaunching（必须在对 submit 前注册，否则 submit 返回错误）:
  BGTaskScheduler.shared.register(forTaskWithIdentifier: "…refresh", using: nil) { task in
    BackgroundChannel.forward(task)   // 转发给 Flutter 引擎
  }
```

- `BGAppRefreshTask`：期望最早间隔 30 分钟（`earliestBeginDate = now+30min`）。**明确不承诺 30 分钟一次**——iOS 按使用习惯/电量/网络自行决定（FR-IOS-02）。
- `BGProcessingTask`：设置 `requiresExternalPower + requiresNetworkConnectivity`，用于夜间充电+WiFi 窗口的长时间整理（记忆整理、深度回顾、备份）。
- `TaskCompletion` 必须显式调用（`task.setTaskCompleted(success:)`）；过期（`expirationHandler`）触发时立即保存 checkpoint 并结束——这是"中断恢复"设计的根源之一。

### 2.2 Flutter 侧桥接协议与 Swift 骨架（自研 Platform Channel，ADR-3）

**Channel 名称**：`bubble/background_task`；方法契约：

| 方向 | 方法 | 参数 |
| -- | -- | -- |
| Dart→原生 | `submitRefresh` | `{earliestSeconds: 1800}` |
| Dart→原生 | `submitProcessing` | `{earliestSeconds: <夜窗>}` |
| Dart→原生 | `completeTask` | `{taskId, success}` |
| 原生→Dart | `onTaskStart` | `{taskId, taskType, isExpirationGrace}` |
| 原生→Dart | `onTaskExpired` | `{taskId}` |
| 原生→Dart | `onSubmitResult` | `{ok, errorCode}` |

Swift 端骨架（AppDelegate.swift，示意级，实施时按此结构展开）：

```swift
import UIKit
import BackgroundTasks
import Flutter

enum BgTaskIdentifiers {
    static let refresh    = "com.<用户前缀>.bubble.test.refresh"
    static let processing = "com.<用户前缀>.bubble.test.processing"
}

@main
class AppDelegate: FlutterAppDelegate {
    private var channel: FlutterMethodChannel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 1. Flutter 引擎与 Channel（必须先于任务注册建立，保证 onTaskStart 能送达 Dart）
        let controller = window?.rootViewController as? FlutterViewController
        channel = FlutterMethodChannel(
            name: "bubble/background_task",
            binaryMessenger: controller!.binaryMessenger)

        // 2. 注册必须在 didFinishLaunching 内同步完成；且必须在任何 submit 之前。
        //    注册晚于首次 submit 时，submit 会返回 Code=3 (immediateRequestTooSoon) 或不可用。
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BgTaskIdentifiers.refresh,
                                        using: nil) { [weak self] task in
            self?.handleRefresh(task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BgTaskIdentifiers.processing,
                                        using: nil) { [weak self] task in
            self?.handleProcessing(task as! BGProcessingTask)
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // 3. 两个任务的 expirationHandler 都必须"先挂 handler 再干活"，
    //    且 handler 内只做：通知 Dart 保存 checkpoint + setTaskCompleted(false)。
    private func handleRefresh(_ task: BGAppRefreshTask) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.dispatchTask(task, type: "apprefresh")
        }
        task.expirationHandler = { [weak self, workItem] in
            self?.channel?.invokeMethod("onTaskExpired",
                arguments: ["taskId": task.identifier])
            workItem.cancel()
            task.setTaskCompleted(success: false)   // 中断恢复入口已由 Dart checkpoint 兜底
        }
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    private func handleProcessing(_ task: BGProcessingTask) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.dispatchTask(task, type: "processing")
        }
        task.expirationHandler = { [weak self, workItem] in
            self?.channel?.invokeMethod("onTaskExpired",
                arguments: ["taskId": task.identifier])
            workItem.cancel()
            task.setTaskCompleted(success: false)
        }
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    // 4. 转发 Dart；等待 Dart completeTask 回调；Dart 完成时 submit 下一轮
    private func dispatchTask(_ task: BGTaskProtocol, type: String) {
        channel?.invokeMethod("onTaskStart", arguments: [
            "taskId": task.identifier, "taskType": type])
    }
}
```

Dart 侧执行协议（ThinkingOrchestrator 集成）：

```dart
// onTaskStart → 以限时模式启动思考（记录 thinking_tasks.bg_task_id = taskId）
//   每 5s 落 checkpoint 到 thinking_tasks.checkpoint
// onTaskExpired → 立即中断保存 → completeTask(taskId, false)
// 正常完成     → completeTask(taskId, true) → 立即 submitRefresh(下一轮)
//   ⚠️ 每次任务执行完必须重新 submit，否则系统不再调度（BGTasks 语义）
```

失败与恢复：
- 注册时机错误/submit 失败 → 记录 background_task_logs，前台下次启动补救提交
- 手机重启：任务注册由系统保留，但**不假设立即运行**（FR-IOS-02）；首启 App 时重新提交
- 强制退出：BGTask 不再运行（iOS 对强退 App 停止后台调度）；已预排通知照投；下次打开恢复（FR-IOS-04）

### 2.3 真机验证清单与日志取证（未验证前全部功能标注「待真机验证」）

验证手段（无 Mac，用 App 内日志替代 debugger）：
1. **日志取证**：App 内置 `bg_task_log` 调试通道（background_task_logs 全量+时间戳毫秒级），数据中心「导出调试日志」生成文件，经爱思助手/文件 App 取出分析——这是无 Mac 条件下的主验证证据链
2. **自然触发观察**：真机锁屏放置过夜/正常使用一天，次日导出日志核对 BGTask 实际触发时刻与 iOS 调度行为（同时验证"不承诺 30 分钟"的真实分布）
3. **通知取证**：记录每条通知的 schedule/cancel/deliver 事件与 scheduled_messages 状态流转，对照系统通知中心实际收到的通知

检查项：

- [ ] 注册后 submit 首次成功（无 Mac 时以 onSubmitResult(ok=true) 日志为证；有 Mac 环境可辅以 `e -lobjc --print BGTaskScheduler`）
- [ ] 锁屏/退后台后任务真实触发（真机自然触发为主，日志取证核对）
- [ ] expirationHandler 中断→checkpoint 恢复链路
- [ ] 强退后：通知投递 ✅、BGTask 停止 ✅、重启后状态恢复
- [ ] 低电量模式/飞行网络对执行的影响观察

> Android 模拟器测试通过 ≠ iOS 通过（FR-TST-02）。iOS 侧验证依赖 GitHub Actions 构建产物 + 真机（无 Mac，debugger 模拟触发不可用，需采用真机自然观察+日志导出验证，规划中预留更长验证周期）。

## 3. 本地通知方案

### 3.1 投递流程（FR-IOS-03 逐步）

```
1. ProactiveDecisionCenter 产出主动消息草稿
2. messages 落库（status=sent, message_kind=proactive，唯一 ID）——通知与真实消息一致
3. scheduled_messages 落库（status=scheduled，notification_id=UUID）
4. NotificationChannel.zonedSchedule(
     id: notification_id,
     title: 按 privacy_mode 渲染（FR-IOS-08）,
     body: full=消息全文 / minimal="泡泡有新消息" / hidden=空,
     fireAt: scheduled_at（timezone 包 TZDateTime，时区感知）)
5. iOS 投递（强退/重启后仍投）→ 用户点击 → 通知响应 payload 深链
   → go_router push 到 conversation/:id 并锚定 message_id
6. App 启动/前台运行时发现已投递 → scheduled_messages → delivered + 回填 message_id
```

### 3.2 防重复与取消（FR-IOS-06 全项）

| 风险 | 机制 |
| -- | -- |
| 通知重复 | notification_id 唯一 + 投递前查询 UNUserNotificationCenter pending 区重检测 |
| 消息重复 | dedup_key（candidate 级）+ 投递前"最近 N 条消息语义查重"（同一话题不再发） |
| 消息删除后通知取消 | messages 软删钩子 → 级联 cancel 通知 + scheduled_messages=cancelled |
| 用户已聊过相同话题 | 投递检查：scheduled_at 前 K 小时该会话有用户消息 → 重新评估或取消 |
| 消息失去意义 | expires_at 到期 → expired，同时 cancel 通知 |
| 通知权限关闭 | 聊天/记忆/落库完全不受影响（FR-IOS-08）；DataCenter 提示开启 |
| 时区变化 | timezone TZDateTime + 监听时区变更事件重排 pending 通知 |
| 勿扰时间 | 投递时刻落在勿扰窗口 → 顺延到窗口结束（ProactivePolicy 统一判定） |
| 每日通知上限 | notification_settings.daily_notify_cap 计数（按本地日历日） |
| 队列上限 | scheduled_messages 非终态 ≤20 条，超限不再安排并提示（不无限堆积） |

### 3.3 自主状态持久化（FR-IOS-07 字段级落实）

落库位置：
- 上次思考时间 / 上次回顾位置 / 未完成任务 → `thinking_tasks`（checkpoint、reviewed_until）
- 待处理记忆 → `memory_candidates(pending)`
- 最近关注话题 → `thinking_results(result_kind=topic_worth_continuing)` + `proactive_candidates`
- 已生成主动消息 → `messages(message_kind=proactive)`
- 待投递通知 → `scheduled_messages(scheduled)`
- 最近主动联系时间 / 上次执行结果 → `app_settings` KV + `background_task_logs`

中断恢复协议：任何步骤崩溃/过期后，`state + checkpoint` 足以从断点续跑；app_resume 时扫描 `state IN (created..deciding)` 的任务恢复执行。

### 3.4 强退行为承诺表

| 事项 | 行为 | 级别 |
| -- | -- | -- |
| 已保存聊天消息 | 不丢失 | 保证 |
| 已保存自主状态 | 不丢失 | 保证 |
| 已预排通知 | 调度不依赖 App 进程，系统照常执行投递；**实际展示受通知权限/专注模式/系统设置影响，不承诺绝对送达** | 尽力保证（修订 5 措辞） |
| 调 DeepSeek 生成新消息 | 不承诺（无执行机会） | 明确不承诺 |
| 后台任务继续 | 停止 | iOS 限制，不绕过 |
| 下次打开 App | 恢复思考任务 + 重新评估待发消息 + 补提交 BGTask | 保证 |

### 3.5 明确不使用云端推送（FR-IOS-09）

无 APNs 远程推送、无服务器。四件套：DeepSeek API（获得运行机会时生成内容）+ SQLite（本地保存）+ UserNotifications（投递）+ BGTaskScheduler（争取机会）。**不依赖自建服务器 ≠ 完全离线**——生成内容仍需网络。
