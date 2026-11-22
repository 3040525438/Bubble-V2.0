# 泡泡 Bubble V2.0 — 技术选型（TECH_STACK）

> 版本核对日期：2026-11-22（pub.dev API 实时查询）。全部选型均核实了当前版本、发布时间与 Flutter SDK 要求。

---

## 1. 基准环境结论

| 项 | 核对结果 | 对本项目的影响 |
| -- | -- | -- |
| Flutter 稳定版 | **3.50**（2026-11-11 发布，Dart 3.14） | 本地开发环境需升级（现 3.24.5 偏旧）；GitHub Actions 统一用 3.50.x |
| Dart SDK | 3.14 | 多数主流包已要求 SDK ≥3.10~3.12 |
| 关键兼容线 | go_router 18.x、flutter_local_notifications 23.x、image_picker 1.2.x 要求 Flutter ≥3.41~3.44 | 锁定 Flutter 3.50 才能使用全部最新包 |

> ⚠️ 兼容性策略：`pubspec.yaml` 中对全部第三方包使用**锁定下限的上界约束**（如 `>=2.35.4 <2.36.0`），并提交 `pubspec.lock`；CI 与本地使用同一 Flutter 版本，避免 Windows 本地与云端 macOS 构建行为漂移。

## 2. 技术选型总表

| 技术 | 版本(2026-11-22) | 负责功能 | 推荐原因 | 替代方案 | 兼容性风险 |
| -- | -- | -- | -- | -- | -- |
| Flutter | 3.50 stable | 主框架 | 官方当前稳定版；满足全部最新插件 SDK 要求；Windows 开发+iOS 交付唯一可行路线 | React Native / 原生 Swift（已否决：需 Mac） | 每次升级需同步更新全部插件 |
| Dart | 3.14 | 语言 | 随 Flutter | — | — |
| flutter_riverpod | 3.5.0（2026-11-06） | 状态管理+依赖注入 | 事实标准；`Ref` 编译期安全；支持 Provider 生命周期与 autoDispose，适合会话级/任务级状态隔离 | Bloc / MobX | Riverpod 3.x 与 2.x 生态有 API 差异，锁定 3.x |
| go_router | 18.1.4（2026-11-09） | 路由 | Flutter 官方 packages 仓库维护；声明式路由+深层跳转（通知点击跳转会话必需） | auto_route | 随 Flutter 官方仓库发布，风险低 |
| drift | 2.35.4（2026-11-08） | SQLite ORM/响应式查询 | 类型安全 SQL、schema 迁移工具链（drift_dev+migrations）、Stream 查询天然适配 UI 响应；配合 sqlite3 3.x 支持 SQLCipher 加密 | sqflite（弱类型，迁移弱）、Isar（维护风险） | 代码生成需 build_runner，CI 时间增加 |
| sqlite3 | 3.9.1（2026-11-08） | SQLite 绑定 | drift 底层；**3.x 起经 Dart hooks 机制自动捆绑预编译 SQLite（含 SQLCipher 变体）**，见下 | — | hooks 构建时需访问 GitHub releases 下载二进制（CI 无碍；本地走代理） |
| sqlite3_flutter_libs | **0.6.0+eol（已 EOL 空壳）** | — | **不采用**。官方指示：升级 sqlite3 3.x 后移除；原生库供给已并入 sqlite3 3.x hooks 机制（2026-11-22 pub get 实测确认） | — | 明确避开此包 |
| dio | 5.11.1（2026-09-04） | 网络请求 | 拦截器/取消/超时/重试齐备；`ResponseType.stream` 支持 SSE 流式解析 | http（无拦截器） | — |
| freezed + json_serializable | 4.0.3 + 6.15.2 | 数据模型/序列化 | 不可变模型+copyWith+union 类型，适合消息/候选等状态机建模 | 手写模型（易错） | 代码生成成本 |
| path_provider | 2.1.6（2026-06-15） | 文件目录 | Flutter 官方维护 | — | — |
| flutter_secure_storage | 10.3.1（2026-05-27） | API Key 等敏感配置 | iOS 落 Keychain（kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly），防 iTunes 备份导出 | 手写 Keychain Channel | 无法绝对防越狱提取（诚实边界） |
| local_auth | 3.0.2（2026-07-09） | Face ID / 应用锁 | Flutter 官方维护；支持 biometricOnly 锁定 Face ID | 手写 LocalAuthentication Channel | 真机验证 Face ID 权限文案 |
| image_picker | 1.2.4（2026-10-06） | 图片选择 | Flutter 官方维护 | photo_manager（过重） | — |
| flutter_local_notifications | 23.0.3（2026-11-18） | 本地通知 | iOS UserNotifications 全覆盖：预排通知、点击动作、权限管理；配合 timezone 包处理时区 | 手写 UNUserNotificationCenter Channel（作为兜底备选） | 强退后投递行为需真机验证 |
| timezone | 0.11.x | 时区数据库 | fln 官方依赖；勿扰时段/跨时区调度必需 | 手写 | — |
| background_fetch | 2.0.1（2026-11-18） | iOS 后台任务（备选） | transistorsoft 维护活跃，封装 BGAppRefreshTask/BGProcessingTask | **主方案：自研 Platform Channel**（见 §4） | 插件后台 Dart 回调稳定性需真机验证 |
| uuid / intl | 最新稳定 | ID 生成/本地化 | 标准件 | — | — |
| flutter_test + integration_test | 随 SDK | 测试 | 官方 | patrol（未必要） | — |
| build_runner / drift_dev / freezed_annotation 等 | 与主包匹配 | 代码生成 | 官方生态 | — | CI 构建时长 |

## 3. 专项选型说明

### 3.1 为什么是 drift 而不是 sqflite

- 需求 FR-DB 要求字段级 schema、迁移、版本兼容、事务——drift 的 `schemaVersion + MigrationStrategy + drift_dev schema 导出/校验` 工具链是 Flutter 生态中最完整的 SQLite 迁移方案。
- drift 的 `watch()` Stream 查询让聊天/记忆/说说列表天然响应式，无需手写失效通知。
- drift 直接暴露 `sqlite3` 底层，可执行 `PRAGMA`、VACUUM、INTO 错误恢复，损坏隔离（FR-DB-02）可落地。
- 加密：sqlite3 3.x 经 Dart hooks 启用 SQLCipher——`pubspec.yaml` 加 `hooks.user_defines.sqlite3.source: sqlcipher`（UPGRADING_TO_V3.md 官方路径，2026-11-22 实测）；降级候选 `source: sqlite3mc`。

### 3.2 中文检索方案（关系 15 项能力中的"中文检索"）

| 方案 | 结论 |
| -- | -- |
| SQLite FTS5 + unicode61 | 对中文按整段切分，检索质量差 → 仅作英文/数字辅助 |
| 注册自定义 FTS5 中文 tokenizer | 需 C 级扩展，sqlite3.dart 注册自定义 tokenizer 受限，风险高 |
| **自建 bigram 倒排索引表（推荐）** | 借鉴 dsh-longterm-memory 的 CJK 单字+双字分词与字段加权（标题×8/别名标签×6/摘要×3/正文×1），用普通 SQLite 表（`*_index_terms`）+ SQL 聚合实现检索与相似度（重叠系数 `|A∩B|/min(|A|,|B|)`）；索引可随时全量重建，符合"SQLite 是唯一事实来源、索引是派生数据"（FR-MEM-06） |

### 3.3 iOS 后台任务：自研 Platform Channel 为主方案

理由：
1. 自主思考系统需要与业务层（SQLite、思考状态机、决策中心）深度联动，需要精确控制任务的注册/提交/完成/失败/重提交时序（FR-IOS-01/02）；
2. Swift 侧桥接代码量可控（BGTaskScheduler 注册+提交+回调转发约 200~300 行），完全可控优于第三方插件的黑盒行为；
3. `background_fetch 2.0.1`（transistorsoft，2026-11-18 仍在维护）作为**备选降级方案**保留：若自研在真机验证中受阻，切换插件以降低风险。
两者均必须在 iPhone 真机验证（FR-TST-02），文档不声称"插件装好即完成"。

### 3.4 模型接入与统一提供者接口（D-6 最终决策）

- **当前阶段只开发 DeepSeek 云端 API**（OpenAI 兼容协议，dio 直连，SSE 流式解析）。
- **架构必须预留统一模型提供者接口**：`abstract class ModelProvider`（能力：`chatStream` / `capabilities` 探测 / `healthCheck` / 计费上报），DeepSeek 实现为第一个子类；其他云端模型走同一接口接入（`openai_compatible` 通道）。
- **设备端本地模型运行时适配能力仅做接口预留**：`local_reserved` provider 位 + 能力描述字段，**当前阶段不实现本地真实推理、不下载任何模型、不引入推理依赖（无 llama.cpp/bindings）**，模型管理 UI 中该选项明确标注「预留、未实现」（FR-MDL-04、FR-NEG）。
- 超时/重试/取消/幂等（请求 ID）/限流/余额不足/Key 失效 → 统一 `ModelClient` 错误分类层（FR-NET-02）。
- 记录每次调用的 prompt/completion/reasoning token 与估算费用（FR-MDL-03、FR-MEM-07）。

### 3.5 不引入的东西（避免过度工程）

- 不引入向量数据库/外部 embedding（dsh 项目明确论证：伪造语义检索比没有更糟；本项目首期用关键词+双字重叠系数，语义检索留待有可信本地 embedding 时再评估）。
- 不引入 Firebase/云推送/自建后端（FR-NEG）。
- 不引入 get_it（Riverpod 已覆盖 DI）。

## 4. 依赖清单（pubspec 草案锁定版本）

```yaml
environment:
  sdk: ">=3.14.0 <4.0.0"
  flutter: ">=3.50.0 <3.51.0"

dependencies:
  flutter_riverpod: 3.5.0
  go_router: 18.1.4
  drift: 2.35.4
  sqlite3: 3.9.1                 # sqlite3_flutter_libs 已 EOL 移除；原生库经 hooks 供给
  dio: 5.11.1
  freezed_annotation: 3.1.0
  json_annotation: ^4.9.0
  path_provider: 2.1.6
  flutter_secure_storage: 10.3.1
  local_auth: 3.0.2
  image_picker: 1.2.4
  flutter_local_notifications: 23.0.3
  timezone: ^0.11.0
  uuid: ^4.5.1
  intl: ^0.20.0

dev_dependencies:
  build_runner: ^2.17.1
  drift_dev: ^2.35.4
  freezed: 4.0.3
  json_serializable: 6.15.2
  flutter_test: {sdk: flutter}
  integration_test: {sdk: flutter}
```

> 注：`sqlite3_flutter_libs` 的确切版本与 SQLCipher 集成方式在阶段 1 用真机验证后再锁定（见 RISK_REGISTER R-01）。

## 5. 版本兼容矩阵核对记录

| 包 | 发布时间 | Flutter 要求 | 结论 |
| -- | -- | -- | -- |
| flutter_riverpod 3.5.0 | 2026-11-06 | ≥3.0.0 | ✅ |
| go_router 18.1.4 | 2026-11-09 | ≥3.44.0 | ✅（3.50 满足） |
| drift 2.35.4 | 2026-11-08 | SDK ≥3.10 | ✅ |
| dio 5.11.1 | 2026-09-04 | SDK ≥2.18 | ✅ |
| fln 23.0.3 | 2026-11-18 | ≥3.44.0 | ✅ |
| secure_storage 10.3.1 | 2026-05-27 | ≥3.19.0 | ✅ |
| local_auth 3.0.2 | 2026-07-09 | ≥3.38.0 | ✅ |
| image_picker 1.2.4 | 2026-10-06 | ≥3.41.0 | ✅ |
| path_provider 2.1.6 | 2026-06-15 | ≥3.38.0 | ✅ |
| freezed 4.0.3 | 2026-10-17 | SDK ≥3.13 | ✅ |
| background_fetch 2.0.1 | 2026-11-18 | ≥3.38.0 | ✅（备选） |
| sqlcipher_flutter_libs 0.7.0+eol | 2026-02-15 | — | ❌ EOL，不采用 |

### 5.1 iOS 兼容性核对（目标设备 iPhone 17 Pro）

| 项 | 核对结果 |
| -- | -- |
| iOS 最低部署目标 | 建议 **iOS 16.0**（BGTaskScheduler 需 13+；UserNotifications 预排需 10+；local_auth/fln 23.x 均兼容 16）；目标设备 iPhone 17 Pro 出厂系统为 iOS 26 系，向下兼容无压力 |
| 纯 Dart 包（riverpod/drift/dio/freezed/go_router 等） | 无原生代码，iOS 兼容性不构成风险 |
| 原生插件 iOS 支持 | flutter_local_notifications（iOS 全功能）、flutter_secure_storage（Keychain）、local_auth（Face ID）、image_picker、path_provider、sqlite3_flutter_libs——均声明 iOS 支持，版本已核对 |
| iOS 权限声明清单 | Face ID（NSFaceIDUsageDescription）、通知（运行时请求）、相册（image_picker 自动管理）、后台模式（processing，见 IOS_BACKGROUND §2.1） |
| 构建链 | GitHub Actions macOS runner + Xcode（runner 自带当前稳定版），Flutter 3.50 + CocoaPods；签名走爱思助手/自签证书，非 App Store 分发 |
| 待真机验证项 | SQLCipher 加密构建、BGTask 真实触发、强退后通知投递、Face ID 文案与降级（全部标注「待真机验证」，见 TEST_PLAN §5/§7） |
| 维护状态汇总 | 全部在用包近 90 天内均有版本发布或属 Flutter 官方仓库维护；唯一 EOL 项 sqlcipher_flutter_libs 已排除 |
