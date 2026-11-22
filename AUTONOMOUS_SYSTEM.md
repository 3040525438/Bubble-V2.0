# 泡泡 Bubble V2.0 — 自主思考与主动行为系统（AUTONOMOUS_SYSTEM）

> 覆盖 FR-ATH（自主思考）、FR-DEC（决策中心）、FR-PRO（无新消息主动联系）三大 P0.5 模块。核心承诺：**真实业务流程 + 状态持久化 + 中断恢复**，不是定时生成一段文字（FR-ATH-04）。

---

## 1. 自主思考系统（ThinkingModule）

### 1.1 八步业务流程（FR-ATH-03 → 状态机）

```
① loading    读 thinking_tasks 上次状态（checkpoint/reviewed_until），无则初始化
② reviewing  取回顾数据（游标分批，防超时）：
             新聊天记录(reviewed_until 之后) + 抽样老历史(随机游标) + 记忆变更
             + 共同经历 + 未完成话题 + 重要约定 + 过去想法(thinking_results)
③ analyzing  本地关联分析（零成本）：检索关联记忆、比对观点变化、发现未处理关联
④ analyzing  模型分析（一次调用，结构化输出）：新联系/重理解/值得继续的话题
             ——输入有界（≤8KiB 摘要包），输出 ≤8 条（借鉴 dsh 提取边界）
⑤ saving     新发现落 thinking_results；记忆候选入 memory_candidates；
             关联入 memory_relations(discovered_by=thinking)
⑥ deciding   产出 proactive_candidates（含 action_kind/priority/来源/dedup_key）
⑦ checkpoint 每步落 checkpoint（中断恢复的原子单位）
⑧ done       保存进度：reviewed_until 前移、清理临时态、background_task_logs 留痕
```

中断恢复：任一步崩溃/BGTask 过期 → state+checkpoint 可续跑；app_resume 扫描非终态任务恢复（FR-IOS-07）。

### 1.2 十项自主能力映射（FR-ATH-02）

| 能力 | 实现点 |
| -- | -- |
| 回顾过去经历 | ② 老历史抽样游标 |
| 发现聊天间联系 | ③④ 关联检索+模型分析 |
| 重新理解过去问题 | ④ 输出 kind=reunderstanding |
| 识别观点变化 | ③ opinion 类记忆 diff |
| 发现值得继续的话题 | ④ kind=topic_worth_continuing |
| 形成记忆候选 | ⑤ |
| 发现值得分享内容 | ④ kind=share_worthy |
| 产生主动联系想法 | ⑥ |
| 发现日记素材 | ④ kind=diary_material |
| 决定保持安静 | ⑥ 不产候选 / 产出 kind=quiet 决策记录（安静也是正式决策） |

### 1.3 触发时机

| 触发源 | 条件 |
| -- | -- |
| 前台定时器 | App 运行中按"主动程度"档位间隔（如 30~120min）触发 |
| BGTask | 后台获得执行机会时（IOS_BACKGROUND §2.2 限时模式） |
| app_resume | 启动/回前台：先恢复中断任务，再评估新一轮 |
| 手动 | 用户在主页点"让泡泡想想" |

## 2. 主动行为决策中心（ProactiveDecisionCenter，唯一入口，ADR-4）

### 2.1 统一决策（FR-DEC-01，禁止四模块各自定时 FR-DEC-03）

聊天/说说/日记/信件/回顾经历/整理记忆/安静 全部只在这里出队执行。其他模块只生产候选，**无权自行调度执行**。

### 2.2 决策过滤流水线（FR-DEC-02 全项）

```
proactive_candidates(pending) 按优先级排序
  → 过期检查（expires_at → expired）
  → 重复检测：dedup_key 查重（同话题近期已表达→reject）+
             近期输出内容相似度检查（与最近说说/消息比对）
  → 冷却时间：同类行为冷却未到 → 顺延
  → 勿扰规则：当前处于 quiet_hours → 顺延（不丢弃）
  → 每日上限：当日该类执行数达 cap → 拒绝留痕
  → 最短间隔：全局最近主动时间 + min_interval 未到 → 顺延
  → 用户硬限制优先级最高（FR-SET-02）：设置不满足时任何候选不得执行
  → 出队执行 → proactive_actions 落执行记录 → 用户反馈回写
```

参数全部存 app_settings：**主动程度默认「积极」档**（D-4 最终决策，符合泡泡高度自主的产品定位），同时硬限制机制全部保留——勿扰时段、冷却时间、重复检测、每日上限、最短间隔、自然保持安静决策（安静也是正式决策），任何档位下硬限制优先级最高（FR-SET-02）。

### 2.3 用户反馈闭环（FR-FBK）

对每次主动行为可反馈（太多/正好/别再这类话题/内容不好）→ feedback_records → 影响：调整该类优先级权重与冷却参数（行为调整）；不直接改人格（PERSONA §4C）；支持撤销与历史查看。

## 3. 无新消息主动联系（FR-PRO 全项）

### 3.1 来源与"想聊聊"的合法性

11 类允许来源（FR-PRO-02）全部映射到候选的 source_kind 字段；**允许 source_kind=self_theme 的"没有外部触发，就是想聊聊"**，内容必须由人格+真实记忆/经历驱动（PersonaAssembler + standing/recall 提供素材）。**禁止**编造未发生经历：候选内容校验步骤要求引用的记忆/消息 ID 必须真实存在（引用校验失败的候选直接拒绝）。

### 3.2 主动消息的落库与投递（FR-PRO-03）

```
候选(chat 类)出队执行 → 生成内容（一次模型调用，人格+召回素材+不重复约束）
  → 引用校验（关联记忆/会话真实存在）→ messages 落库(message_kind=proactive, 唯一ID)
  → scheduled_messages(scheduled, scheduled_at=现在或稍后, reason=来源说明)
  → 通知预排（IOS_BACKGROUND §3.1，受 privacy_mode/daily cap/勿扰约束）
  → 交付后：用户可取消（撤销机制）、到期未投递 expired、执行留痕
```

多日未打开场景：泡泡每次获得执行机会（前台/后台）都会走 §1 流程；连日无机会时**不承诺主动产生**（诚实边界：iOS 不会为强退的 App 唤醒后台），但一旦打开 App 即恢复评估并补上"想念的表达"（基于 reviewed_until 积累的新发现）。此边界已写入 RISK_REGISTER 并在 UI 首次引导中告知用户。

### 3.3 防伪原则

- 候选与消息必须携带 related_* 外键，指向真实存在的记忆/消息/经历（FK + 应用层校验）
- "回顾记录"只追加不改历史（shared_experiences.review_log）
- thinking_results 的重理解不回写历史消息

## 4. 说说/日记/信件与决策中心的联动

| 行为 | 生成素材 | 去重约束 |
| -- | -- | -- |
| 说说（FR-POST） | 人格+share_worthy/心情/兴趣记忆+可选图片 | 与最近 N 条说说相似度检查；用户指定主题生成走独立入口 |
| 日记（FR-DIA） | diary_material 素材+当日聊天 → AI 整理稿 → 用户可编辑 | 当日已有 AI 日记 → 追加版本而非新条目（版本保留） |
| 信件（FR-LET） | 重要约定/纪念日/观点变化 → 长文 | 冷却更长（默认 ≥7 天）；草稿/已发送状态机 |

## 5. 与 iOS 能力的诚实对齐（FR-IOS-02）

| 场景 | 泡泡能做到 | 不能承诺 |
| -- | -- | -- |
| App 前台 | 完整思考+立即执行+通知 | — |
| App 退后台 | BGTask 机会时思考（限时+checkpoint） | 每 30 分钟执行一次、固定时间执行 |
| App 强退/手机重启 | 已预排通知由系统执行投递（展示受权限/专注模式影响）、数据完整 | 任何情况下绝对送达；任何后台生成；重启后立即运行 |
| 长期未打开 | 打开后恢复+补评估 | 未打开期间凭空主动联系 |

所有"尽力而为"项在 RISK_REGISTER 编号登记，并在 App 内设置页提供能力说明文案（不夸大）。
