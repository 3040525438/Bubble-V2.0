# 泡泡 Bubble V2.0 — 开发阶段规划（DEVELOPMENT_ROADMAP）

> 依赖关系驱动的阶段 0–15（对齐需求第十章；顺序可微调、模块不删减）。每阶段含：前置依赖 / 具体任务 / 交付成果 / 自动化测试 / 验收标准。
> 不给日历工期承诺（依用户节奏），但给出各阶段的相对体量（S/M/L）供排序参考。

---

## 阶段 0：环境、资料和技术调研（体量 S）

> **完成度口径（严格区分，无实际证据不得标记完成）**：
> - ✅ **已完成（有证据）**：技术与需求调研——本文档集 16 份（含 pub.dev 版本核对记录、dsh-longterm-memory 源码研读、AstrBot 源结构确认）。
> - ✅ **已完成（有证据，2026-11-22）**：本地 Flutter 3.50.1 升级（flutter doctor 通过）、CI 流水线搭建（ci.yml + ios-build.yml）、**CI 构建通过**（run 44996644352 / 44997104863）、**IPA 生成**（run 44997104863，未签名 IPA 产物已归档含 SHA256）。
> - ⬜ **未完成（无证据，不得标完成）**：**爱思助手安装成功**、**iPhone 17 Pro 真机启动**——需用户配合执行并留档（安装截图/日志、真机首启截图）。

- 前置：无
- 任务：需求确认（本文档集）；Flutter 3.50 环境就位（Windows 升级本地 SDK）；GitHub Actions iOS 构建流水线打通（含实验版 Bundle ID 与签名文件管理）；AstrBot 资料归档与备份；dsh-longterm-memory 机制研究（已完成）
- 交付：五步证据链逐项落地——① CI analyze/test 通过 → ② CI 构建 IPA 成功 → ③ IPA 产物存档（路径+sha256）→ ④ 爱思助手真机安装成功 → ⑤ iPhone 17 Pro 真机启动并截图
- 测试：CI 冒烟（flutter analyze/test 通过）
- 验收标准：五步证据全部留档；任何一步无证据即视为未完成

## 阶段 1：基础架构、数据库、路由和主题（体量 L）

- 前置：阶段 0
- 任务：分层骨架（ARCHITECTURE §1）；Drift 29+ 表 schema v1 + 迁移框架 + schema 快照测试；加密验证（SQLCipher 真机构建验证，失败则启用降级方案并如实记录）；bigram 分词器与索引表；GoRouter 全路由表；Material3 泡泡主题；应用锁骨架（local_auth）
- 交付：可运行骨架 App：建库/加密/检索索引/锁屏可工作
- 测试：schema 迁移测试、分词器单测（中英文语料）、事务单测
- 验收：真机打开加密库 + Face ID 锁通过（真机验证项）

## 阶段 2：聊天系统和多会话（体量 L）

- 前置：阶段 1
- 任务：conversations/messages 仓储；QQ 式聊天 UI（品牌气泡/头像/靠右靠左/时间/状态/长按菜单）；多会话列表与抽屉（切换/新建/重命名/删除）；连续多气泡拆分与独立持久化；停止/重试/继续/中断恢复；失败消息队列与未发送队列
- 交付：无模型后端的完整聊天 UI（EchoProvider 假模型仅用于开发，交付前移除，不冒充真功能）
- 测试：聊天域全部单测（TEST_PLAN §3 除真实网络项）
- 验收：模拟器全流程 + 长会话压力测试通过

## 阶段 3：DeepSeek API 和模型管理（体量 M）

- 前置：阶段 2
- 任务：ModelClient（dio+SSE 流式解析）；models/model_usage 仓储；模型注册/启停/参数/切换 UI；能力检测（视觉/上下文/流式）；错误分类（超时/断网/429/401/余额）；Token 计费落库；API Key 入 Keychain
- 交付：真实 DeepSeek 聊天可用（流式/停止/重试）
- 测试：SSE 解析单测（录制回放）、错误矩阵单测
- 验收：真机流式聊天成功（需网络）

## 阶段 4：人格中心（体量 M）

- 前置：阶段 3
- 任务：persona 四表；PersonaAssembler 组装器；版本管理与恢复 UI；成长建议审批流；表达样本收集；主页静态层
- 测试：人格域全部（TEST_PLAN §1）
- 验收：核心人格门禁穷举测试通过；恢复版本可用

## 阶段 5：长期记忆系统（体量 L）

- 前置：阶段 4
- 任务：MemoryEngine（规则提取/机密扫描/敏感降级/比较决策）；批量延迟处理管线；memories 生命周期与版本；检索（倒排+相关性地板+预算渲染）；收件箱/列表/冲突裁决 UI；索引重建；standing/recall 注入接入聊天上下文
- 测试：记忆域全部（TEST_PLAN §2）
- 验收：语料集提取命中率达标；索引重建一致；注入预算正确

## 阶段 6：人格与记忆联合上下文（体量 S）

- 前置：阶段 5
- 任务：ContextBuilder 总装（人格块+standing+recall+会话历史+预算裁剪）；缓存友好排序；上下文预览调试面板
- 测试：组装快照测试/预算裁剪边界测试
- 验收：聊天中泡泡能正确引用常驻记忆与人格细节

## 阶段 7：自主思考系统基础（体量 L）

- 前置：阶段 6
- 任务：thinking_tasks 状态机+checkpoint；ThinkingOrchestrator 八步流程；thinking_results；前台定时触发；恢复评估（启动扫描）；"让泡泡想想"入口
- 测试：自主行为域（TEST_PLAN §4 除 BGTask 项）
- 验收：无新消息触发思考全流程+中断恢复一致性

## 阶段 8：主动行为决策中心（体量 M）

- 前置：阶段 7
- 任务：proactive_candidates/actions；ProactivePolicy 过滤流水线（冷却/勿扰/上限/间隔/重复/过期）；主动程度设置页；反馈记录与行为调整
- 测试：决策策略全项（fakeAsync 时钟）
- 验收：任何候选无法绕过硬限制

## 阶段 9：共同经历与关系发展（体量 S）

- 前置：阶段 8
- 任务：shared_experiences 仓储与 UI（视角双栏/回顾记录只追加）；经历与记忆/会话关联；从思考/记忆流自动提名经历候选
- 验收：历史事实字段防改测试通过

## 阶段 10：性格说说（体量 M）

- 前置：阶段 8
- 任务：posts 仓储；说说列表/详情/时间线；自主发布（决策中心出队）+ 用户指定主题生成；心情/话题/图片/连续说说；主界面独立入口
- 验收：内容由人格驱动且重复检测生效

## 阶段 11：日记与信件（体量 M）

- 前置：阶段 10
- 任务：diaries/letters 仓储；AI 整理日记（版本保留）/手动编辑/导出；信件双向/草稿/已发送/归档；关联记忆与经历
- 验收：导出 Markdown 可读；信件无模板腔

## 阶段 12：图片系统（体量 M）

- 前置：阶段 3（模型能力检测）
- 任务：attachments 仓储与 AttachmentStore；发送/预览/删除；视觉能力检测与降级提示；OCR（云端模型或本地 Vision 框架评估，实施时定）与图片文字搜索；多图分析；一致性检查
- 验收：不支持视觉的模型明确提示；附件完整性检查通过

## 阶段 13：本地通知和 iOS 后台任务（体量 L，风险最高）

- 前置：阶段 8（候选→消息链路已通）
- 任务：自研 BGTask Platform Channel（注册/提交/回调/过期/重提交）；scheduled_messages 全状态机；通知预排/取消/点击深链；防重复/勿扰/上限/时区；通知隐私三档；background_task_logs；强退/重启/系统终止三场景处理；（备选：background_fetch 插件切换验证）
- 测试：通知域单测层全过
- 验收：**真机四场景验收通过**（TEST_PLAN §5 真机列），未过不进入后续阶段

## 阶段 14：反馈、搜索、隐私、安全、备份和迁移（体量 L）

- 前置：阶段 5/10/11/12
- 任务：feedback_records 完整闭环；全局搜索（content_index_terms 六域）；数据管理中心（状态/统计/导出/恢复/完整性/孤立附件清理）；备份体系（manifest/对账/恢复）；AstrBot 导入向导（dry-run/正式/回滚/对账）；删除范围确认流
- 测试：数据域全部（TEST_PLAN §6）
- 验收：真实 AstrBot 样本迁移对账三向一致；备份恢复往返成功（真机）

## 阶段 15：全面测试和 iPhone 真机验收（体量 L）

- 前置：全部
- 任务：TEST_PLAN §7 全清单执行；性能基线；电池观察；未验证标注清零；RISK_REGISTER 关闭复核；文档更新
- 验收：全部真机项通过 + 自动化测试全绿 + 用户 UAT

## 里程碑视图

```
M1 骨架可用      = 阶段 0-1  （加密库+锁+CI 出包）
M2 能聊天        = 阶段 2-3
M3 有灵魂        = 阶段 4-6  （人格+记忆+联合上下文）
M4 会自主        = 阶段 7-9  （思考+决策+经历）
M5 有生活        = 阶段 10-12（说说+日记信件+图片）
M6 能主动联系    = 阶段 13   （通知+后台，最大风险点）
M7 数据闭环      = 阶段 14
M8 交付          = 阶段 15
```

## 关键顺序说明（对需求第十章的两处调整及理由）

1. 需求建议顺序中图片系统（12）在通知（13）之前——保持一致。通知后置的理由：候选→消息→通知链路依赖决策中心与多模块内容形态就绪，13 一次到位减少真机反复。
2. 迁移（在需求中列于阶段 14）：真实导入数据越早越好，故**建议在阶段 14 期间并行插入「迁移试运行」**（用样本库），正式全量迁移在阶段 14 完成后执行——避免中途 schema 变更导致返工。

## 附录：任务拆分清单（可勾选，执行时逐项核对）

### 阶段 0
- [x] T0.1 本地 Flutter 升级 3.50 并跑通 `flutter doctor`（实际 3.50.1 + Dart 3.14.0，doctor 2026-11-22 通过）
- [x] T0.2 GitHub Actions 仓库：analyze+test workflow / IPA 构建 workflow（实际方案：未签名 IPA，CI 无需证书 Secrets；run 44997104863 双流水线成功）
- [ ] T0.3 空壳 App（实验版 Bundle ID）→ CI 出 IPA ✅（com.dafeiyu.bubble.test 已归档）→ 爱思助手真机安装成功 ⬜（待用户配合，见阶段0报告.md §10）
- [ ] T0.4 AstrBot 资料双副本备份 + sha256 清单
- [ ] T0.5 §7 的 D-1~D-8 决策项与用户确认

### 阶段 1
- [x] T1.1 drift schema v1（32 表）+ 快照导出与升级测试骨架（schema_v1 + make-migrations，2026-11-22）
- [x] T1.2 加密验证 spike：sqlite3 3.x hooks + SQLCipher 编译成功（本地 Win + CI macOS 双验证）；真机打开加密库待真机安装后确认
- [x] T1.3 PRAGMA 约定与 QueryExecutor 单连接封装（key→WAL→page_size）
- [x] T1.4 bigram 分词器 + 索引表读写 + 重建协议（15+5 单测）
- [x] T1.5 GoRouter 路由表 + Material3 主题（深浅 token 与 UI_DESIGN_SYSTEM 一致，9 例校验）
- [x] T1.6 local_auth 应用锁骨架（锁屏/失败保护；Face ID 真机文案待真机验证）
- [x] T1.7 双版本打包（iOS 双 scheme + CI 按 flavor 注入 Bundle ID/显示名；Android 双 flavor；产物 Info.plist 自动校验）

### 阶段 2
- [x] T2.1 conversations/messages 仓储 + seq 分配 + 软删（2026-11-22，conversation_repository.dart）
- [x] T2.2 聊天页 UI（气泡/头像靠右靠左/时间条/状态/长按菜单）（chat_page + message_bubble）
- [x] T2.3 多会话列表 + 抽屉（切换/新建/重命名/删除范围确认）（conversation_list_page + conversation_drawer）
- [x] T2.4 连续多气泡拆分落库 + 中断/停止/重试/继续状态机（bubble_splitter + message_status + chat_session_controller）
- [x] T2.5 失败消息与未发送队列（failedMessages + 全部重试 + 悬挂恢复）
- [x] T2.6 会话内搜索（bigram 过滤）（searchMessages + 搜索弹层定位高亮）

### 阶段 3
- [x] T3.1 ModelClient（dio+SSE 解析器，录制回放测试）（deepseek_client + sse_parser，回放 fixture）
- [x] T3.2 models/model_usage 仓储 + Keychain Key 读写（model_repository + secure_key_store）
- [x] T3.3 模型管理 UI（注册/启停/参数/能力徽章/用量图）（model_manage_page + 我的页入口）
- [x] T3.4 错误分类层（超时/断网/429/401/余额）+ UI 文案映射（chat_error，含错误矩阵单测）
- [ ] T3.5 真机流式聊天验收（需真实 API Key 与真机，待用户执行）

### 阶段 4
- [x] T4.1 persona 四表仓储 + 版本流转（persona_repository：全局版本号递增/激活唯一/核心门禁）
- [x] T4.2 PersonaAssembler（四层+反模板约束+快照落库）（persona_assembler + core_system_prompt 快照）
- [x] T4.3 核心人格编辑 diff 确认流 + 成长审批队列 UI（persona_center_page + core_persona_edit_page）
- [x] T4.4 表达样本收集与 pin（列表/手动添加/从对话沉淀/置顶/软删）
- [x] T4.5 人格域全量测试（仓储 13 + 组装器 5 + 页面 3，本地 116 测试全过）

### 阶段 5
- [x] T5.1 MemoryEngine 纯函数层（信号规则/机密扫描/敏感降级/比较决策）
- [x] T5.2 批量延迟处理管线（缓冲表+触发条件）
- [x] T5.3 memories 生命周期/版本/撤销 + relations
- [x] T5.4 检索：倒排+相关性地板+预算渲染
- [x] T5.5 收件箱/列表/详情/冲突裁决/注入预览 UI
- [x] T5.6 索引重建与对账
- [x] T5.7 中文语料集（≥100 例）测试通过

### 阶段 6
- [x] T6.1 ContextBuilder 总装 + 预算裁剪 + 缓存友好排序
- [x] T6.2 上下文调试预览面板

### 阶段 7
- [x] T7.1 thinking_tasks 状态机 + checkpoint 协议
- [x] T7.2 八步 Orchestrator（含回顾抽样游标）
- [x] T7.3 前台定时触发 + app_resume 恢复扫描 + 「让泡泡想想」
- [x] T7.4 thinking_results 与记忆/候选联动

### 阶段 8
- [x] T8.1 proactive_candidates/actions 仓储
- [x] T8.2 ProactivePolicy 过滤流水线（时钟注入可测）
- [x] T8.3 主动程度/通知设置 UI + 能力说明页
- [x] T8.4 反馈闭环（feedback_records + 行为调整）

### 阶段 9
- [x] T9.1 shared_experiences 仓储 + 双视角 UI + review_log 只追加
- [x] T9.2 经历自动提名流

### 阶段 10
- [x] T10.1 posts 仓储 + 说说时间流 UI + 独立入口
- [x] T10.2 生成器（自主/指定主题）+ 去重
- [x] T10.3 心情/话题/图片/详情/编辑删除

### 阶段 11
- [x] T11.1 diaries（月历+列表+版本+导出）
- [x] T11.2 letters（草稿/已发送/双向/归档）

### 阶段 12
- [x] T12.1 AttachmentStore（sha256/相对路径/缺失检查）
- [x] T12.2 图片消息 UI + 全屏预览 + 多图
- [x] T12.3 视觉能力检测 + 降级提示
- [x] T12.4 OCR 与图片文字搜索（接口/索引/搜索完成；真实识别引擎按 D-5 待接入，UI 明确标注未接入）

### 阶段 13
- [x] T13.1 Swift BGTask 桥接（按 IOS_BACKGROUND §2.2 骨架展开）+ Channel 协议（`bubble/background_task`、`bubble/system`）
- [x] T13.2 Info.plist（UIBackgroundModes/BGTaskSchedulerPermittedIdentifiers）+ Android 通知权限 + CI 侧 plist 校验
- [x] T13.3 scheduled_messages 全状态机 + 通知预排/取消/深链（chat/post/diary/letter + focus 高亮）
- [x] T13.4 防重复/勿扰/上限/时区重排（同消息去重、跨午夜勿扰顺延、每日上限按本地日窗、时区变化重排）
- [x] T13.5 通知隐私三档（完整显示/只提示有新消息/隐藏内容）
- [x] T13.6 调试日志导出通道（设置 → 后台任务日志，导出文本到文档目录）
- [ ] T13.7 真机四场景验收（TEST_PLAN §5 真机列）——**待用户真机执行**（强退/重启/系统终止/通知点击）

### 阶段 14
- [ ] T14.1 全局搜索（六域+高亮+锚点）
- [ ] T14.2 数据中心（状态/统计/完整性/孤立附件/日志）
- [ ] T14.3 备份/恢复（manifest+对账+恢复前自动备份）
- [ ] T14.4 导出（JSON/Markdown 双格式）
- [ ] T14.5 AstrBot 导入向导（dry-run/正式/回滚/对账）
- [ ] T14.6 删除范围确认流（含备份独立确认）

### 阶段 15
- [ ] T15.1 TEST_PLAN §7 真机全清单执行
- [ ] T15.2 性能与电池基线
- [ ] T15.3 「待真机验证」标注清零
- [ ] T15.4 文档/风险表收尾复核 + UAT
