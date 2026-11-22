# 泡泡 Bubble V2.0 — 总体架构（ARCHITECTURE）

> 设计原则：**领域纯函数化**（借鉴 dsh-longterm-memory 的 engine 设计——决策逻辑无 IO、可测试）、**SQLite 单一事实来源**、**所有自动行为统一走决策中心**、**平台能力经 Channel 隔离**。

---

## 1. 分层架构

```
┌───────────────────────────────────────────────────────────────┐
│ presentation 层                                                │
│ 聊天页 · 会话抽屉 · 说说 · 日记 · 信件 · 记忆管理 · 人格编辑     │
│ 模型管理 · 主页/时间线 · 搜索 · 数据中心 · 设置 · 锁屏            │
└──────────────┬────────────────────────────────────────────────┘
               │ Riverpod（StateNotifier/AsyncNotifier + watch 流）
┌──────────────▼────────────────────────────────────────────────┐
│ application 层（控制器/编排）                                    │
│ ChatController · MemoryController · PersonaController          │
│ ThinkingOrchestrator（自主思考编排）                             │
│ ProactiveDecisionCenter（主动行为决策中心，唯一入口）             │
│ NotificationScheduler · BackupController · MigrationController │
└──────────────┬────────────────────────────────────────────────┘
               │ 调用 domain 纯函数 + data 仓储
┌──────────────▼────────────────────────────────────────────────┐
│ domain 层（纯 Dart，无 IO，全量单测覆盖）                         │
│ MemoryEngine：提取候选/机密扫描/敏感降级/去重合并/冲突判定        │
│ MemorySearch：bigram 分词/倒排检索/重叠系数/召回预算渲染          │
│ PersonaAssembler：四层人格→系统提示词（版本化+确认门禁）          │
│ ThinkingEngine：思考步骤状态机（可中断恢复）                     │
│ ProactivePolicy：冷却/勿扰/每日上限/重复检测/优先级（纯函数）     │
│ ModelRouter：模型能力检测/上下文预算/Token 计费                  │
└──────────────┬────────────────────────────────────────────────┘
               │ 接口（抽象类）
┌──────────────▼────────────────────────────────────────────────┐
│ data 层                                                        │
│ DriftDatabase（29+ 表，加密）· MemoryRepository 等 10+ 仓储      │
│ DeepSeekClient（dio，SSE 流式）· SecureStore（Keychain）        │
│ AttachmentStore（文件系统）· BackupManager · AstrBotImporter    │
└──────────────┬────────────────────────────────────────────────┘
               │ Platform Channels（Swift）
┌──────────────▼────────────────────────────────────────────────┐
│ platform 层（iOS 原生）                                         │
│ BGTaskChannel（BGTaskScheduler 注册/提交/回调/重提交）            │
│ NotificationChannel（UNUserNotificationCenter 预排/取消/权限）   │
│ AppLifecycleChannel（前后台切换/终止事件）                        │
│ （local_auth / fln 插件覆盖不到的部分才手写）                     │
└───────────────────────────────────────────────────────────────┘
```

**依赖方向**：presentation → application → domain ← data；data 与 platform 只被 application 调用；domain 不 import flutter/dio/drift（保证可单测）。

## 2. 模块清单与职责

| 模块 | 职责 | 关联需求 |
| -- | -- | -- |
| ChatModule | 多会话、连续多气泡、流式渲染、长按菜单、中断/重试/恢复 | FR-CHT |
| PersonaModule | 四层人格、版本管理、确认门禁、提示词组装 | FR-PER |
| MemoryModule | 候选提取→生命周期→检索召回→确认 UI | FR-MEM |
| ModelModule | 注册/启停/能力检测/统计计费/切换 | FR-MDL |
| ThinkingModule | 思考任务状态机、回顾筛选、新发现保存 | FR-ATH |
| ProactiveModule | 决策中心、候选池、限制规则执行 | FR-DEC/PRO |
| ExperienceModule | 共同经历 CRUD、视角记录、回顾 | FR-EXP |
| ContentModules | 说说/日记/信件（共享"人格驱动生成器"与时间线） | FR-POST/DIA/LET |
| ImageModule | 附件、视觉能力检测、OCR、图片搜索 | FR-IMG |
| FeedbackModule | 反馈记录、撤销、行为调整（不动核心人格） | FR-FBK |
| SearchModule | 全局搜索统一入口（分域路由） | FR-MISC-03 |
| DataCenterModule | 库/附件/备份状态、统计、导出、恢复 | FR-MISC-04 |
| SecurityModule | 应用锁、Face ID、自动锁定、失败保护 | FR-SEC |
| NetworkModule | 错误分类、重试、幂等、未发送队列 | FR-NET |
| BackgroundModule | BGTask 桥接、生命周期、恢复评估 | FR-IOS |

## 3. 五条核心数据流

### 3.1 聊天流
```
用户输入 → ChatController
  → 1. 消息落库(messages, status=sending)
  → 2. ContextBuilder：人格提示词(PersonaAssembler) + 常驻记忆(MemorySearch.standing)
       + 按需召回(本次输入触发) + 会话近期历史 → 上下文预算裁剪
  → 3. DeepSeekClient.stream(SSE) → 增量更新消息草稿 → 完成→messages 落库
  → 4. 连续多气泡：解析回复中的分段标记 → 拆成多条独立消息各自落库
  → 5. 延迟批处理队列登记本轮(userText, assistantText)（不立即调模型）
       → 达到触发条件(轮数/间隔/会话结束) → MemoryEngine.extract → 候选落库
```
失败路径：网络异常 → 消息保持 failed + 未发送队列；停止 → 保留已生成部分并标记 interrupted。

### 3.2 记忆流（候选 → 事实）
```
MemoryEngine.extract（纯函数：信号规则+可选LLM提取）
  → 机密扫描(high拒绝/low脱敏) → 敏感类别降级 → 模型主张 grounding 校验
  → compareCandidate：与现有记忆重叠系数≥0.82同类型→merge / 矛盾→conflict / 补充→update / 新→create
  → 策略门禁：high置信度+create/update 自动保存；其余入 memory_candidates(pending)
  → 用户确认 UI → 通过→memories(active)；拒绝→rejected 留痕
  → 全部变更写 journal_logs；增量更新索引表
```

### 3.3 自主思考流（详见 AUTONOMOUS_SYSTEM）
```
触发(前台定时/后台BGTask/启动恢复) → ThinkingOrchestrator
  → 读 thinking_tasks 上次状态(断点续跑) → 分步执行(每步落 checkpoint)
  → 新发现→thinking_results + 记忆候选 + proactive_candidates
  → 提交 ProactiveDecisionCenter → 保存进度
```

### 3.4 主动决策流
```
proactive_candidates(带来源/关联记忆/优先级)
  → ProactivePolicy.filter（冷却/勿扰/每日上限/最短间隔/重复检测/过期）
  → 决策执行：主动聊天→scheduled_messages→通知预排；说说/日记/信件→对应模块；安静→什么都不做
  → proactive_actions 执行记录 + 用户反馈回写
```

### 3.5 通知流（详见 IOS_BACKGROUND_AND_NOTIFICATION）
```
消息落库(唯一ID) → scheduled_messages(scheduled) → NotificationChannel.zonedSchedule
  → iOS 投递(即使强退) → 点击→深链跳转会话+消息 → delivered
  → 取消条件监听(消息删除/已聊过/过期/勿扰变化) → cancel 通知+状态机流转
```

## 4. 关键架构决策记录（ADR 摘要）

| # | 决策 | 理由 | 备选与放弃原因 |
| -- | -- | -- | -- |
| ADR-1 | 记忆引擎做成纯函数（输入上下文→输出决策），由 application 层执行写库 | 全量单测；模型/存储故障隔离；与 dsh 项目同构，机制已验证 | 把引擎直接耦合 Drift（难测试） |
| ADR-2 | 检索用自建 bigram 倒排表而非 FTS5 中文扩展 | 纯 SQL 可重建；避开自定义 tokenizer 的 C 扩展风险 | FTS5+自定义 tokenizer（C 级扩展不可控） |
| ADR-3 | BGTask 用自研 Platform Channel | 时序全可控、与思考状态机深度联动；插件黑盒难做中断恢复 | background_fetch（保留为降级备选） |
| ADR-4 | 主动行为唯一入口=ProactiveDecisionCenter | 满足 FR-DEC-03（禁止四模块各自定时） | 各模块独立定时（明确违规） |
| ADR-5 | 会话隔离但人格/记忆共享 | FR-CHT-03；上下文组装时人格+常驻记忆全局注入，会话历史按 conversation_id 过滤 | 全局共享历史（泄露跨会话内容） |
| ADR-6 | 附件存应用沙盒 Documents/Attachments/<yyyy>/<mm>/，DB 存相对路径 | 备份/迁移/一致性检查可控 | 绝对路径（换机即断链） |
| ADR-7 | 所有自动写入 DB 的路径都必须经过 repository 层业务校验 | FR-MEM-06：模型/LLM 输出只是候选 | LLM 直接生成 SQL（禁止） |

## 5. 启动与生命周期

```
冷启动 → Splash：解锁检查(SecurityModule) → 数据库打开+完整性快检
  → 迁移检查(drift schema version + migration_records)
  → 恢复评估：未完成思考任务重启 / scheduled_messages 重新校验 / 索引完整性抽查
  → 主界面(会话列表)
前台运行中：AppLifecycle resume → 触发"恢复评估"；定时器驱动自主思考
进入后台：提交 BGAppRefreshTask（下次最早 30min，不承诺）+ BGProcessingTask（夜间充电窗口）
被终止/强退：无代码执行；已预排通知由 iOS 投递；状态已在 SQLite
```

## 6. 错误处理与降级总策略

| 故障 | 行为 |
| -- | -- |
| DeepSeek 超时/断网 | 错误分类落库、消息 failed、UI 明示原因；恢复后手动/自动重试（幂等请求 ID） |
| 限流 429 / 余额不足 / Key 失效 | 明确用户提示 + 停止自动重试；不影响本地功能 |
| 模型不支持视觉 | 图片功能降级提示（FR-IMG-02），不假装完成 |
| 数据库打开失败/损坏 | 隔离损坏页 → 尝试 WAL 恢复 → 恢复失败提示从备份恢复；坏行隔离上报 DataCenter（FR-DB-02） |
| 通知权限被关 | 聊天/记忆/保存完全不受影响（FR-IOS-08），DataCenter 提示 |
| BGTask 未获执行 | 无降级动作（接受 iOS 决定）；下次前台运行恢复思考（FR-IOS-02） |
