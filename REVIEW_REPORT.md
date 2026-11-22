# 泡泡 Bubble V2.0 — 项目规划审查报告（REVIEW_REPORT）

> 交叉审查日期：2026-11-22。审查范围：14 份规划文档相互一致性 + 需求逐项核对。
> 结论先行：**规划完整、自洽，可以进入实施；有 8 项待用户确认事项（§7），确认后即可开工。**

---

## 1. 需求与功能完整性核对

### 1.1 核对方法

需求原文已逐条编号为 `REQUIREMENTS.md` 的 23 组 FR 清单（FR-PRD/ENG/PER/MEM/CHT/MDL/ATH/DEC/PRO/EXP/POST/DIA/LET/IMG/FBK/MISC/SET/IOS/DB/MIG/SEC/NET/TST/NEG，共 100+ 条目），再逐条映射到设计文档与路线图阶段。

### 1.2 核心功能逐项核对表

| 需求项 | 覆盖文档 | 路线图阶段 | 结论 |
| -- | -- | -- | -- |
| 人格中心四层+确认门禁+版本管理 | PERSONA_DESIGN 全文；persona_* 4 表 | 阶段 4 | ✅ 已覆盖 |
| 长期记忆 10 分类/6 生命周期/15 能力/成本控制 | MEMORY_DESIGN §2-§5；memories 等 5 表 | 阶段 5 | ✅ 已覆盖 |
| 聊天 QQ 式/多会话/连续多气泡/流式/长按菜单 | ARCHITECTURE §3.1；conversations/messages | 阶段 2 | ✅ 已覆盖 |
| 模型管理（注册/检测/切换/统计） | TECH_STACK §3.4；models/model_usage | 阶段 3 | ✅ 已覆盖 |
| 自主思考（八步流程/状态机/中断恢复） | AUTONOMOUS_SYSTEM §1；thinking_tasks/results | 阶段 7 | ✅ 已覆盖 |
| 主动行为决策中心（候选池/冷却/勿扰/上限） | AUTONOMOUS_SYSTEM §2；proactive_* 2 表 | 阶段 8 | ✅ 已覆盖 |
| 无新消息主动联系（11 来源/真实消息/取消过期） | AUTONOMOUS_SYSTEM §3；scheduled_messages | 阶段 8+13 | ✅ 已覆盖 |
| 共同经历（字段/双视角/不改历史） | DATABASE §2.17 | 阶段 9 | ✅ 已覆盖 |
| 性格说说（独立入口/人格驱动/去重） | AUTONOMOUS_SYSTEM §4；posts | 阶段 10 | ✅ 已覆盖 |
| 日记（版本保留/导出）与信件（草稿/双向） | DATABASE §2.19/2.20 | 阶段 11 | ✅ 已覆盖 |
| 图片系统（视觉检测/OCR/一致性） | DATABASE §2.3；SECURITY §4 | 阶段 12 | ✅ 已覆盖 |
| 反馈与行为调整（不动核心人格） | PERSONA §4C；feedback_records | 阶段 8/14 | ✅ 已覆盖 |
| 主页/时间线/全局搜索/数据中心 | PERSONA §6；DB §2.29；SECURITY §5-6 | 阶段 14 | ✅ 已覆盖 |
| 主动程度设置 | AUTONOMOUS §2.2；app_settings | 阶段 8 | ✅ 已覆盖 |
| iOS 后台/通知（三能力/强退/队列/隐私三档） | IOS_BACKGROUND 全文 | 阶段 13 | ✅ 已覆盖 |
| 数据库 29 张表 | DATABASE_DESIGN §2（29 张逐一字段级 + 3 张派生） | 阶段 1 | ✅ 已覆盖 |
| 数据迁移 15 步 | MIGRATION_PLAN §2（真实源路径） | 阶段 14 | ✅ 已覆盖 |
| 隐私安全 15 项 | SECURITY_AND_PRIVACY 全文 | 阶段 1/14 | ✅ 已覆盖 |
| 离线与网络异常 | ARCHITECTURE §6；SECURITY | 阶段 3 | ✅ 已覆盖 |
| 测试六大域+真机验收 | TEST_PLAN 全文 | 全程+阶段 15 | ✅ 已覆盖 |
| 明确不开发清单 | PROJECT_OVERVIEW §4；FR-NEG | — | ✅ 已遵守 |

### 1.3 存在疑问/需补充的点

- **无遗漏**：需求第十章 0-15 阶段全部保留，未删任何模块；第十一章不开发清单全部遵守。
- ⚠️ 两处需求内张力已在文档中显式化解：①「记忆自动保存」与「敏感信息默认不自动保存」→ 敏感扫描降级到 pending 解决；②「泡泡可自主决定保持安静」与「不承诺后台执行」→ 安静作为决策值 + 执行机会受 iOS 限制的诚实对齐（AUTONOMOUS §5）。

## 2. 技术方案与总体架构

- **最终推荐栈**（版本均于 2026-11-22 经 pub.dev 核实，见 TECH_STACK §5 矩阵）：Flutter 3.50 / Riverpod 3.5.0 / go_router 18.1.4 / drift 2.35.4 + sqlite3 3.9.1 / dio 5.11.1 / freezed 4.0.3 / flutter_local_notifications 23.0.3 / flutter_secure_storage 10.3.1 / local_auth 3.0.2。
- **关键选型理由**：drift（迁移工具链+Stream 响应式+加密通道）优于 sqflite；自研 BGTask Channel（时序可控）优于 background_fetch（保留为降级备选）；自建 bigram 倒排索引（纯 SQL 可重建）优于 FTS5 中文扩展。
- **依赖兼容性**：唯一 EOL 依赖 sqlcipher_flutter_libs 已避开；最新插件要求 Flutter ≥3.44，故锁定 3.50。CI 与本地统一版本，lock 文件入库。
- **架构**：五层（presentation/application/domain/data/platform），domain 纯函数无 IO 全量单测；五条核心数据流（聊天/记忆/思考/决策/通知）在 ARCHITECTURE §3 有完整调用关系；7 条 ADR 记录关键取舍。
- **模块调用关系**：模型只能产候选 → application 执行写库；主动行为唯一入口=决策中心（ADR-4）；平台能力经 Channel 隔离，插件不可覆盖处有手写兜底。

## 3. 数据库与数据迁移

- **表结构**：需求 29 张表全部给出字段级设计（字段/主键/外键/索引/生命周期/删除策略/关联），另有 3 张派生索引表；事务边界 5 场景、schema 迁移策略（drift 版本链+快照测试）、损坏隔离（quarantine+重建+备份兜底）、JSON/Markdown 双导出、备份完整性对账（DATABASE §3-§6）。
- **AstrBot 迁移**：基于旧工程已验证的真实源路径（chat_memory.db / memory.db / data_v4.db / diary/ / letters/ / companions.json 等）设计 15 步流程；预演-正式-回滚三态导入；源只读+双副本备份；对账三向校验；API Key 不迁移。
- **备份恢复**：manifest（计数+sha256+schema 版本）→ 恢复前强制校验 → 恢复后索引重建与完整性复查。

## 4. 自主思考、主动行为与 iOS 通知方案（能力保证分级）

**无新消息主动联系完整方案**：触发（前台定时/BGTask/启动恢复/手动）→ 八步思考流程（读状态→回顾筛选→关联→分析→保存→决策→checkpoint→进度）→ 候选池统一决策（冷却/勿扰/上限/重复/过期）→ 主动消息落库为真实消息（独立 ID/来源/关联记忆/可取消/可过期）→ 本地通知预排 → 点击深链。允许"就是想聊聊"（self_theme 来源），引用校验杜绝编造经历。

**能力分级（明确哪些保证/尽力/受限）**：

| 级别 | 能力 |
| -- | -- |
| **可保证** | 前台完整思考；消息/状态/候选持久化；强退后已预排通知由系统执行投递调度（展示受权限/专注模式/系统设置影响，不承诺绝对送达，修订 5 措辞）；数据不丢；下次启动恢复思考与重新评估；离线浏览全部本地数据 |
| **尽力而为** | BGAppRefresh/Processing 获得执行机会（iOS 裁量）；后台执行时长内的思考完成度（expirationHandler 中断→checkpoint 续跑） |
| **iOS 限制、不承诺** | 30 分钟一次执行；固定时间执行；强退后调用 DeepSeek；重启后立即运行；用户长期不开 App 期间的主动联系（打开后补评估） |

全部"尽力/不承诺"项已写入 RISK_REGISTER（R-02/R-03）并要求 App 内能力说明文案同步（不夸大）。

## 5. 开发阶段与实施任务

- 阶段 0–15 与需求第十章一一对应，无删减；两处顺序调整理由已说明（DEVELOPMENT_ROADMAP 尾节）。
- 每阶段：前置依赖/任务/交付/测试/验收标准五要素齐全；里程碑 M1-M8（骨架→聊天→灵魂→自主→生活→主动联系→数据→交付）。
- 每阶段自动化测试映射 TEST_PLAN 六大域；验收标准含真机项（阶段 1 加密、阶段 13 通知四场景、阶段 15 全清单）。
- 风险前置：阶段 0 即打通真机出包，阶段 1 即验证加密，阶段 13 集中处理最高风险。

## 6. 风险、成本与时间评估

- **技术风险**：R-01 加密集成（顶部）、R-02 后台不确定性（确定发生，靠预期管理）、R-03 无 Mac 验证闭环弱（流程补偿）。
- **iOS 兼容风险**：R-04 签名过期、R-06 插件维护、R-12 时区。
- **API 成本**：R-07——已设计三重控制（本地筛选/延迟批量/计费可视化+预算上限）。
- **开发难度与时间风险**：R-11 体量（8 里程碑长周期，里程碑制+验收线管控）、R-10 行为质量（分阶段 UAT 观察期）。
- **时间评估立场**：遵照用户规则不给日历工期承诺；以体量（S/M/L）与里程碑排序替代。主要时间风险在阶段 13（真机观察窗口不可压缩）与阶段 14（真实 AstrBot 数据的对账往返）。

## 7. D-1～D-8 最终决策表（2026-11-22 修订后）

| # | 事项 | 最终决策 | 状态 |
| -- | -- | -- | -- |
| D-1 | 数据库加密路线 | 主方案 SQLCipher（sqlite3 3.x），降级方案应用层加密；阶段 1 真机验证后锁定 | ⬜ 待阶段 1 验证定案 |
| D-2 | LLM 记忆提取默认开关 | **已定案：默认关闭**（llm_extraction_enabled=0）；本地规则提取保持默认启用；LLM 提取仅由用户主动开启 | ✅ 用户已定 |
| D-3 | 通知隐私默认档 | **已定案：默认 minimal**（仅显示「泡泡有新消息」）；允许用户改为完整显示或隐藏 | ✅ 用户已定 |
| D-4 | 主动程度默认档 | **已定案：默认积极档（active）**；勿扰/冷却/重复检测/每日上限/自然保持安静等硬限制机制全部保留，硬限制优先级最高 | ✅ 用户已定 |
| D-5 | OCR 方案 | 推荐 iOS 本地 Vision 框架优先（免费+离线+隐私），云端视觉模型作为长图/复杂图降级 | ⬜ 待用户确认 |
| D-6 | 模型接入 | **已定案：当前只开发 DeepSeek 云端 API**；架构预留统一 ModelProvider 接口与设备端本地模型运行时适配位；不实现本地真实推理、不下载模型、不增加推理依赖 | ✅ 用户已定 |
| D-7 | 实验版 Bundle ID | 命名风格 `com.<用户前缀>.bubble.test`，**需用户提供标识前缀** | ⬜ 待用户提供 |
| D-8 | 迁移记忆置信度起点 | 推荐全部 medium 起步可纠错（UI 提供批量确认） | ⬜ 待用户确认 |

### 7.1 iOS 本地通知保证程度（用户修订 5，2026-11-22）

已安排通知的**投递调度不依赖 App 进程存活**（强退/系统终止后系统照常执行）；但**实际展示受 iOS 通知权限、专注模式、系统通知设置影响，本项目不承诺任何情况下绝对送达**。相关表述已在 IOS_BACKGROUND §1/§3.4、PROJECT_OVERVIEW §5、AUTONOMOUS_SYSTEM §5、REVIEW_REPORT §4 同步统一。

## 9. 交叉审查问题清单与修复记录

两轮审查共发现 14 项问题，已全部修复：

| # | 问题 | 修复 |
| -- | -- | -- |
| P-01 | notification_settings/app_settings 过简，不符"每表 7 要素" | DATABASE §2.25/2.26 展开为字段级+键空间枚举 |
| P-02 | messages 缺 DeepSeek reasoning_tokens | 已加 token_reasoning 列 |
| P-03 | scheduled_messages 缺计划时时区 | 已加 scheduled_timezone |
| P-04 | memories 缺召回统计 | 已加 recall_count/last_recalled_at |
| P-05 | 会话删除时通知队列级联未定义 | 已定义硬删级联 cancel、软删不级联 |
| P-06 | thinking_tasks 与 BGTask 无关联 | 已加 bg_task_id |
| P-07 | 缺 PRAGMA/性能约定 | 新增 §3.1（WAL/foreign_keys/busy_timeout/单连接策略） |
| P-08 | app_settings 键空间未枚举 | §2.26 键枚举表 |
| P-09 | 无 UI/交互规范 | 新增 UI_SPEC.md（17 页面布局/交互/三态） |
| P-10 | iOS 方案缺代码级细节 | IOS_BACKGROUND §2 补 Swift 桥接骨架、Info.plist 完整示例、无 Mac 日志取证流程 |
| P-11 | 本报告未记录审查过程 | 本节即修复记录 |
| P-12 | 聊天页缺会话内搜索（需求 FR-CHT-04） | UI_SPEC §3 补会话内搜索交互 |
| P-13 | 路线图任务拆分粒度不足（需求十二章第 8 条） | DEVELOPMENT_ROADMAP 新增附录：阶段 0-15 全部任务拆分为 50+ 项可勾选清单 |
| P-14 | 记忆信号规则未映射泡泡 10 类分类 | MEMORY_DESIGN §2.2 新增信号规则映射表（含中文信号样例与噪声过滤） |

## 10. 修订记录（2026-11-22 最终修订轮，应用户指令 R-1~R-8）

| # | 指令 | 执行情况 | 涉及文档 |
| -- | -- | -- | -- |
| R-1 | 统一 D-2：LLM 提取默认关闭，规则提取默认启用 | 已统一：MEMORY_DESIGN §1/§2.4-1/§5 三处 + app_settings llm_extraction_enabled=0 + D 表；全文 grep 确认无冲突残留 | MEMORY_DESIGN, DATABASE_DESIGN, REVIEW_REPORT |
| R-2 | D-3 改默认 minimal | 已改：notification_settings 默认 minimal；UI_SPEC §11 设置页同步 | DATABASE_DESIGN, UI_SPEC, REVIEW_REPORT |
| R-3 | D-4 改默认积极档 | 已改：proactivity_level 默认 active；AUTONOMOUS §2.2 改写并保留全部硬限制（勿扰/冷却/重复检测/每日上限/安静决策） | DATABASE_DESIGN, AUTONOMOUS_SYSTEM, UI_SPEC, REVIEW_REPORT |
| R-4 | D-6：仅 DeepSeek + 预留统一接口与本地运行时适配位 | 已改：TECH_STACK §3.4 重写（ModelProvider 抽象 + local_reserved 位，不实现推理/不下载/不加依赖）；模型表 provider 枚举已含 local_reserved | TECH_STACK, REVIEW_REPORT |
| R-5 | 通知保证措辞：不承诺绝对送达 | 已统一四处：IOS_BACKGROUND §1/§3.4、PROJECT_OVERVIEW §5、AUTONOMOUS §5、REVIEW_REPORT §4 | 4 份文档 |
| R-6 | 阶段 0 证据区分 | 已改：DEVELOPMENT_ROADMAP 阶段 0 完成度口径（已完成=调研文档；未完成=升级/CI/IPA/安装/真机启动，需五步证据链） | DEVELOPMENT_ROADMAP, REVIEW_REPORT §11 |
| R-7 | 补齐 TECH_STACK/TEST_PLAN 供最终审查 | 已补：TECH_STACK §5.1 iOS 兼容性核对（部署目标/权限/构建链/维护状态汇总）；TEST_PLAN §8 质量门禁与 CI 集成 | TECH_STACK, TEST_PLAN |
| R-8 | 全文交叉复核矛盾 | grep 复核完成：旧默认值（conservative/privacy full/LLM 默认开）零残留；决策表与各文档引用一致；§9 P-01~P-14 前两轮已修复 | 全部 |

## 11. 阶段 0 实际完成证据与未完成事项

| 事项 | 状态 | 证据 |
| -- | -- | -- |
| 需求梳理与技术调研 | ✅ 完成 | 本文档集 16 份；pub.dev 版本核对记录（TECH_STACK §5，2026-11-22 实查）；dsh-longterm-memory 三份文档+六个源码文件研读 |
| AstrBot 源结构确认 | ✅ 完成 | 旧导入器真实路径清单（MIGRATION_PLAN §1，来自已验证的旧工程代码） |
| 本地 Flutter 升级 3.50 | ⬜ 未执行 | 无证据 |
| CI 流水线搭建 | ⬜ 未执行 | 无 workflow 文件/运行记录 |
| CI 构建通过 | ⬜ 未执行 | 无运行记录 |
| IPA 生成 | ⬜ 未执行 | 无产物路径/sha256 |
| 爱思助手安装 | ⬜ 未执行 | 无安装记录/截图 |
| iPhone 17 Pro 真机启动 | ⬜ 未执行 | 无首启截图 |
| D-1/D-5/D-7/D-8 决策确认 | ⬜ 待用户 | D-7 需用户提供 Bundle ID 前缀 |

## 12. 尚未验证的技术风险（全部标注「待真机验证」，汇总自 RISK_REGISTER）

1. **SQLCipher 加密在 iOS 真机构建**（R-01，顶部风险）——sqlite3.dart 3.x 新机制未经本团队验证；降级方案已备
2. **BGTaskScheduler 真实触发与执行时长**（R-02）——调度行为完全由 iOS 裁量；无 Mac 只能日志取证+自然观察
3. **强退/重启/系统终止后通知展示**（修订 5）——调度不依赖进程，但展示受权限/专注模式影响，未验证
4. **Face ID 在 local_auth 3.0.2 的权限文案与降级链路**（R-06 关联）
5. **本地 bigram 检索与记忆语料集提取命中率**（R-10 关联）——语料集尚未构建，指标未实测
6. **爱思助手签名有效期与续签流程**（R-04）——签名类型未定，随 D-7 Bundle ID 确认后验证
7. **中量数据集性能基线**（冷启动/滚动/检索）——无实测数据

## 13. 最终停点声明

本轮仅完成调研、规划、文档与审查，**未开始任何正式功能开发**。文档位于 `BubbleV2/` 目录：14 份规划文档（PROJECT_OVERVIEW / REQUIREMENTS / TECH_STACK / ARCHITECTURE / DATABASE_DESIGN / IOS_BACKGROUND_AND_NOTIFICATION / MEMORY_DESIGN / PERSONA_DESIGN / AUTONOMOUS_SYSTEM / MIGRATION_PLAN / SECURITY_AND_PRIVACY / TEST_PLAN / DEVELOPMENT_ROADMAP / RISK_REGISTER）+ 补充文档 UI_SPEC.md + 本审查报告。

**等待用户审阅本报告与 §7 的 8 项待确认事项，并明确授权后方可进入阶段 0 实施。**
