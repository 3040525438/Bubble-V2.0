# 泡泡 Bubble V2.0 — 开发环境检查结果（ENVIRONMENT_AUDIT）

> 检查日期：2026-11-22。全部结论基于本轮实际命令输出，无凭空推断项。

---

## 1. 检查命令与证据

| 检查项 | 命令 | 结果 |
| -- | -- | -- |
| Flutter | `flutter doctor -v` | ✅ 3.24.5 stable，Dart 3.5.4，位于 `E:\temp_20261113_01\_tools\flutter`，已配置腾讯镜像 |
| Git | `where.exe git` + `git config` | ✅ `D:\git\Git\cmd\git.exe`；user.name=wsq，user.email 已配置 |
| Java | `where.exe java` | ✅ JDK 17（`C:\Program Files\Java\jdk-17`） |
| ADB | `where.exe adb` | ✅ `E:\temp_20261113_01\_tools\android-sdk\platform-tools\adb.exe` |
| Android SDK | 目录检查 | ✅ cmdline-tools / emulator / platforms / build-tools / **licenses** / **system-images(android-35 google_apis x86_64)** 齐全 |
| Android 模拟器 | `flutter emulators` | ✅ 已有现成 AVD：`dafeiyu_test`（android 镜像在位） |
| Chrome | `flutter doctor` | ✅ Chrome 157（可用于 Web 预览） |
| GitHub API | `curl.exe https://api.github.com/repos/3040525438/DaFeiYu` | ✅ HTTP 200（旧仓库可匿名访问，**即公开仓库**） |
| git 协议连通性 | `git ls-remote https://github.com/.../DaFeiYu.git` | ❌ `Connection was reset`（git 协议本次被重置；api.github.com 通） |
| gh CLI | `where.exe gh` | ❌ 未安装 |

## 2. 发现的问题与定级

### 问题 1：Flutter 版本低于规划要求（需处理）
- 现状 3.24.5 / Dart 3.5.4；TECH_STACK 已锁定 **Flutter 3.50 + Dart 3.14**（go_router 18.x、fln 23.x 等要求 ≥3.41~3.44）。
- **责任与方案**：TRAE 可自行升级（镜像已配置，下载约 1~2GB，耗时主要在网络）。属阶段 0 T0.1。
- **不阻塞文档/架构工作**，但阻塞 `flutter create`（3.50 模板）与全部依赖拉取。

### 问题 2：flutter doctor 的 Android toolchain 检查崩溃（低优先）
- 报错：`Android toolchain ... exceeded maximum allowed duration of 0:04:30`（sdkmanager 检查超时，常见于许可证/网络探测卡顿）。
- **影响**：仅影响 Android 辅助调试链路的 doctor 体检；模拟器镜像与 AVD 实际在位。Android 在本项目仅为辅助调试（不发布 Android 版），iOS 构建走 GitHub Actions macOS runner，**此项不阻塞开发**。
- 方案：阶段 0 顺手修复（重跑 `flutter doctor --android-licenses` / 检查 cmdline-tools），失败也不阻塞主线。

### 问题 3：GitHub git 协议连接被重置（需验证，中优先）
- `git ls-remote` 报 `Connection was reset`，但 api.github.com 匿名访问正常。旧项目 DaFeiYu 曾成功推送并跑 CI（工作区留有 `ci_log*.txt` 共 200 万+ 字节的 Actions 日志与多份 CI 产物），说明此前链路可用——本次失败可能是瞬时网络波动。
- 方案：TRAE 授权后先重试；若持续失败再讨论代理配置。**不阻塞本地开发**，只阻塞推远端与 CI。

### 问题 4：BubbleV2 尚无 git 仓库与 Flutter 工程（预期内）
- `BubbleV2/` 目前 = 23 份 md + design/UI_PROTOTYPE.html（38 页原型，108KB），无 pubspec、无 .git。
- 方案：TRAE 授权后自行 `git init` + `flutter create` + .gitignore（含密钥/备份排除规则）。属 D 级（自行完成）。

### 问题 5：gh CLI 未安装（低优先）
- 旧项目未用 gh 也能完成推送与 CI（纯 git + GitHub 网页配置），非必需。可选安装以管理 workflow 运行状态；也可用 API 查询。

### 环境中不需要的项
- Visual Studio（Windows 桌面构建用）：本项目目标 iOS，不需要。
- Android Studio：命令行 SDK 已够用。
- macOS / Xcode：CI 云端 runner 提供。

## 3. 能否运行项目的结论

- **当前不能**直接跑（工程尚未创建、Flutter 未升级），但这不是"环境坏了"，而是阶段 0 未执行的正常状态。
- 环境底座（SDK 路径/镜像/Git/JDK/模拟器/许可证目录）全部在位，升级 3.50 后即可 `flutter create` 并运行。
- 连接设备清单：Windows / Chrome / Edge / Android 模拟器（dafeiyu_test）——开发期 UI 调试可用模拟器+Chrome，不依赖真机。

## 4. 遗留物说明（未改动）

工作区根目录存在旧项目（DaFeiYu 大肥鱼）的大量产物：IPA 目录（含 3 个未签名 IPA 与 zip）、`_astrbot_review*`、`_ci_*`、`_migration_copy_20261116` 等。本轮**全部未改动、未删除**（遵守"不删除或覆盖原始数据"边界）。其中对 V2 有复用价值的：
- `IPA/正式版`：证明"CI 出未签名 IPA → 爱思助手签名安装"路线此前已走通；
- `_ci` 系列与 `build-artifacts.yml` 模式：CI workflow 可参考复用；
- 两份 AstrBot 数据拷贝：见 PREFLIGHT_REPORT §迁移条件。
