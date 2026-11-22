# 泡泡 Bubble V2.0

一款 iOS AI 陪伴应用：有长期记忆、可成长人格、会自主思考并能主动联系你的「泡泡」。

- **技术路线**：Flutter（Windows 开发）+ DeepSeek API + 本地 SQLite（drift + SQLCipher）+ GitHub Actions macOS 出包 + 爱思助手真机安装
- **数据原则**：本地优先，无自建服务器，无云端推送，全部数据存于设备本地加密数据库
- **双版本**（同仓双 flavor，可并存安装）：
  - 测试版：iOS `com.dafeiyu.bubble.test` / 显示名「泡泡·测试」
  - 正式版：iOS `com.dafeiyu.bubble` / 显示名「泡泡」

## 当前状态

| 阶段 | 状态 |
| -- | -- |
| 产品规划 / 技术方案（16 份文档） | ✅ 完成 |
| UI/UX 设计（38 页原型 + 7 份设计文档） | ✅ 完成 |
| 开发前检查（Preflight） | ✅ 完成 |
| 仓库接入（本仓库） | ✅ 完成 |
| 阶段 0：环境与 CI 链路 | 🔶 4/5 完成（CI ✅ / IPA ✅ / 产物归档 ✅；爱思助手安装与真机启动待用户配合） |
| 阶段 1：基础架构、数据库、路由和主题 | ✅ 主体完成（32 表 schema v1 + SQLCipher + 分词索引 + 主题/路由/锁屏；CI 双流水线绿 @ 3321a90；真机验证项 3 项待真机安装） |
| 双版本打包（测试版 / 正式版） | ✅ 完成（iOS 双 scheme + CI 注入 Bundle ID/显示名；Android 双 flavor；产物经 Info.plist 校验） |
| 阶段 2：聊天系统和多会话 | ✅ 主体完成（仓储/状态机/聊天 UI/多会话/失败队列/会话内搜索；本地 68 测试全过；开发用回声假模型，真实 DeepSeek 属阶段 3） |
| 阶段 3：DeepSeek API 和模型管理 | ✅ 主体完成（SSE 客户端/错误矩阵/模型仓储与 Keychain/模型管理 UI/用量估算；98 测试全过；真机真实 Key 流式验收待执行） |
| 阶段 4~15 正式开发 | 🔶 阶段 4 进行中 |

## 双版本构建

| 版本 | flavor | Bundle ID / applicationId | 显示名 | 触发方式 |
| --- | --- | --- | --- | --- |
| 测试版 | `test` | `com.dafeiyu.bubble.test` | 泡泡·测试 | push 到 main 自动构建（默认） |
| 正式版 | `prod` | `com.dafeiyu.bubble` | 泡泡 | Actions 手动运行（workflow_dispatch，选 prod） |

实现方式：Xcode 工程保留 Debug/Release/Profile 三个基础配置与 `test`/`prod` 两个 scheme；版本差异由 CI 通过 `FLUTTER_XCODE_PRODUCT_BUNDLE_IDENTIFIER`、`FLUTTER_XCODE_DISPLAY_NAME` 环境变量在构建时注入（命令行级构建设置优先级最高）。CI 出包后会从 IPA 内 `Info.plist` 提取并校验 Bundle ID 与显示名，不符则构建失败。

| 产物 | 说明 |
| --- | --- |
| `bubble-unsigned-ipa-test` | 未签名测试版 IPA + SHA256 + bundle-id.txt |
| `bubble-unsigned-ipa-prod` | 未签名正式版 IPA + SHA256 + bundle-id.txt |

## 文档导航

| 类别 | 文档 |
| -- | -- |
| 总览与需求 | PROJECT_OVERVIEW / REQUIREMENTS / REQUIREMENTS_SOURCE |
| 架构与技术 | ARCHITECTURE / TECH_STACK / DATABASE_DESIGN / IOS_BACKGROUND_AND_NOTIFICATION |
| 核心设计 | PERSONA_DESIGN / MEMORY_DESIGN / AUTONOMOUS_SYSTEM / MIGRATION_PLAN |
| 质量与安全 | TEST_PLAN / RISK_REGISTER / SECURITY_AND_PRIVACY / REVIEW_REPORT |
| 实施规划 | DEVELOPMENT_ROADMAP（阶段 0~15） |
| UI/UX | UI_DESIGN_PROPOSAL / UI_SPEC / UI_DESIGN_SYSTEM / UI_INFORMATION_ARCHITECTURE / UI_PAGE_SPEC / UI_INTERACTION_SPEC / UI_COMPONENT_CATALOG / UI_DESIGN_REVIEW |
| 原型 | design/UI_PROTOTYPE.html（浏览器直接打开，38 页可点击原型） |
| 检查报告 | PREFLIGHT_REPORT / ENVIRONMENT_AUDIT / USER_PREPARATION_CHECKLIST / BLOCKERS_AND_DEPENDENCIES |

## 规划中的 Flutter 目录结构（阶段 1 建立）

```
lib/
  presentation/   # 页面与组件（Material 3 + 泡泡主题）
  application/    # 状态管理与编排（Riverpod）
  domain/         # 纯函数领域层（全量单测）
  data/           # drift 数据库、仓储、模型客户端
  platform/       # Platform Channel（BGTask / 通知 / 生物识别）
test/             # 单元测试
integration_test/ # 集成测试
.github/workflows/ # CI：analyze + test + iOS 未签名 IPA
```

## 公开仓库安全红线

本仓库为公开仓库，严禁入库的内容（`.gitignore` + pre-commit 钩子双重防护，启用方式 `git config core.hooksPath .githooks`）：

- 一切 API Key / 令牌 / 密码（DeepSeek Key 只录入设备 Keychain）
- SQLite 数据库与任何真实用户数据（聊天 / 记忆 / 日记）
- AstrBot 原始备份与迁移资料（仅存于本地工作区，不入库）
- 图片、语音等私人附件
- Apple 证书、描述文件与签名私钥（签名在本机由爱思助手完成，CI 只出未签名 IPA）

> 本仓库当前包含规划文档、设计产物与阶段 0 空壳工程（Bundle ID `com.dafeiyu.bubble.test`），不含任何业务功能与个人数据。
> CI 证据：[CI analyze+test](https://github.com/3040525438/Bubble-V2.0/actions/runs/44997104863) ✅ / [iOS 未签名 IPA](https://github.com/3040525438/Bubble-V2.0/actions/runs/44997104863) ✅（产物含 SHA256）
