# 泡泡 Bubble V2.0 — 长期记忆系统设计（MEMORY_DESIGN）

> 参考项目：[dsh-longterm-memory](https://github.com/bufan528/dsh-longterm-memory)（Node.js 宿主插件，2026-10~11 活跃）。已研读其 docs/architecture.md、storage-format.md、privacy.md 及 engine/retrieval/search/recall/indexing/repository 六个核心源文件。**只借鉴机制，不引入依赖**——按需求在 Flutter+SQLite 中独立实现（FR-MEM-01）。

---

## 1. 从参考项目借用的机制清单

| dsh 机制 | 本项目落地方式 |
| -- | -- |
| 纯函数决策引擎（engine 不写库，只返回 decision） | `MemoryEngine` 纯 Dart 类，application 层执行写库（ADR-1） |
| 机密扫描：11 类模式、high 拒绝整条 / low 脱敏、重叠 span 合并、≥50% 机密占比拒绝 | 原样移植正则集（含中文「密码是/密钥为/令牌」模式），纯函数可测 |
| 敏感类别扫描（健康/财务/身份/关系/法律）→ 置信度压到 medium → 只能进待确认 | 原样移植（FR-MEM-05 敏感信息默认不自动保存） |
| 规则式信号提取（中文正则规则按类型加权）为默认路径，**默认启用**；LLM 提取为可选增强，**默认关闭，仅由用户主动开启**（llm_extraction_enabled=0，D-2 最终决策） | 规则提取零成本默认开；LLM 提取开启后走延迟批处理（见 §5 成本控制） |
| 模型主张 grounding 校验（原文定位不到→降 low；仅助手回复佐证→降 medium） | 原样移植（防模型编造事实） |
| 候选比较：重叠系数 ≥0.82 同类型→merge；矛盾→conflict；补充→update；否则 create | 原样移植；重叠系数=`|A∩B|/min(|A|,|B|)`（双字+拉丁词） |
| 只裁不该写：low 置信度不注入；历史记忆与现行事实分开标注 | standing/recall 双通道分别过滤（FR-MEM-04-12/13） |
| CJK 单字+双字分词、字段加权倒排（标题8/别名标签6/摘要3/正文1） | SQLite 索引表实现（见 §3） |
| 索引=派生数据，损坏自动全量重建、零丢失 | §3 索引重建协议 |
| journal 有界摘要变更日志、崩溃容错（坏行跳过） | journal_logs 表（DATABASE_DESIGN §2.28） |
| 删除只归档、真删需二级确认 | memories 状态机 + 数据中心二级确认 |
| 常驻块 700token/12条 + 召回块 600token/8条 + 相关性地板 | §4 注入预算（参数进 app_settings 可调） |

**明确不借用**：Markdown 文件仓库（本项目事实来源是 SQLite+Drift，FR-MEM-06）、Obsidian 兼容层、HTTP RPC、QQ 联动、贴纸/提醒等伙伴周边（与泡泡无关）。

## 2. 记忆模型

### 2.1 分类映射（FR-MEM-02 的 10 类 → memories.type）

| 用户需求分类 | type | 备注 |
| -- | -- | -- |
| 用户资料 | profile | 姓名/职业/背景等稳定事实 |
| 用户偏好 | preference | 喜欢/讨厌/习惯 |
| 共同经历 | experience_joint | 详情存 shared_experiences，记忆表存索引摘要+关联 |
| 重要事件 | event | |
| 关系发展 | relationship | |
| 重要约定 | agreement | 常驻优先级提升 |
| 用户观点及变化 | opinion | 关联 opinion_change 思考结果 |
| 经验教训 | lesson | |
| 项目状态 | project | |
| 重要经历 | important_experience | 与 experience_joint 区分：单方重要经历 |

### 2.2 信号规则映射（规则提取默认路径，零成本）

信号规则体系从 dsh 的 9 类 SIGNAL_RULES 适配到泡泡 10 类（中文正则为主，weight 高者获胜；实施时以可配置规则表落库，便于调参）：

| 泡泡 type | 高置信信号（weight 示例） | 中置信信号 |
| -- | -- | -- |
| profile（资料） | 「我是/我叫/我在做/我的职业是」（95） | 「我住/我在 …」 |
| preference（偏好） | 「记住：…」「以后都/不要再」「我喜欢/讨厌」（100） | 「我更倾向于/习惯了」 |
| agreement（约定） | 「说好了/约好/下次一起/答应你」（92） | 「周未前/生日那天…」时间锚定句 |
| relationship（关系发展） | 「我们的关系/你在我心里/越来越」（85） | 「第一次/后来我们」 |
| opinion（观点） | 「我觉得/我认为/我的看法」（80） | 「以前觉得…现在觉得」（观点变化，同时产 opinion_change 思考候选） |
| event（事件） | 「今天发生了/刚考完/搬家了」（75） | 日期+动作句式 |
| experience_joint（共同经历） | 与 experience 检测合并，命中时同时提名 shared_experiences 候选（80） | — |
| lesson（教训） | 「教训/踩坑/下次不要/学到了」（78） | — |
| project（项目状态） | 「项目/在做的/卡在/进度」（65） | — |
| important_experience（重要经历） | 「对我来说很重要/一辈子忘不了/人生中第一次」（85） | — |

噪声过滤（不成为记忆）：寒暄/纯表情/单句「嗯/哈哈/继续」等（沿用 dsh NOISE_PATTERNS 并扩充中文口语）。

### 2.3 生命周期状态机（FR-MEM-03）

```
candidate(pending) ──确认──▶ active ──新证据冲突──▶ conflict（保留双方证据，待用户裁决）
   │拒绝→rejected              │──内容过期──▶ stale
   │30天未处理→expired         │──被新记忆替代──▶ superseded（superseded_by 指针）
   │                          │──用户归档──▶ archived（只归档不真删）
   └──任何状态──撤销恢复──回退到前一状态（memory_versions 回放）
```

### 2.4 15 项能力落点（FR-MEM-04）

| # | 能力 | 实现位置 |
| -- | -- | -- |
| 1 | 自动提取候选 | MemoryEngine.extract（规则提取默认启用；LLM 提取默认关闭、用户主动开启 D-2） |
| 2 | 分类 | 信号规则 type 判定 + LLM 提取结构化 |
| 3 | 重要度/置信度 | 规则权重 + LLM 评估，双字段存储 |
| 4 | 重复检测 | compareCandidate 重叠系数 ≥0.82 同类型 |
| 5 | 合并 | merge 决策：新字段并入旧记忆，来源合并留痕 |
| 6 | 冲突检测 | 数值/否定/替换语义冲突规则 → conflict 双证据 |
| 7 | 待确认 | memory_candidates(pending) + 确认 UI |
| 8 | 来源追踪 | evidence + source_session/message_ids |
| 9 | 版本管理 | memory_versions 快照 |
| 10 | 关联记忆 | memory_relations（含思考自动发现） |
| 11 | 撤销恢复 | 状态回退+版本回放 |
| 12 | 常驻记忆 | pinned/is_resident → standing 块 |
| 13 | 按需召回 | MemorySearch.queryIndex → recall 块 |
| 14 | 中文检索 | bigram 倒排索引 |
| 15 | 索引重建 | 全量重建协议（对账计数校验） |

## 3. 中文检索与索引（FR-MEM-04-14/15、FR-MISC-03）

### 3.1 分词器（纯 Dart，与 dsh 算法同构）

```
拉丁/数字：小写化、按非字母数字切分、丢弃单字母（保留单数字）
CJK 连续段：产出单字 + 相邻双字（「长期记忆」→ 长/期/记/忆/长期/期记/记忆）
上限：每字段 4000 token；查询与建索引用同一分词器
```

### 3.2 索引结构（派生数据，可重建）

- `memory_index_terms(token, doc_id, field_weight)` + `memory_index_docs(元数据缓存)`
- 写路径：memories 变更 → 同事务增量更新索引（delta upsert）
- 检索：查询分词 → 倒排命中 → 加权得分（字段权重 × 重复词 `1+log(n)` 抑制）→ importance/confidence 加成排序
- 相关性地板（借鉴 dsh）：自动注入场景要求命中 token ≥2 字符（或非 CJK）——单字命中视为巧合
- 相似度判定：重叠系数（不用 Jaccard——中文记忆长短差异大，Jaccard 惩罚短补充）

### 3.3 重建协议

```
触发：索引格式版本变更 / 打库校验计数不符 / 手动触发（数据中心）
流程：全表扫描 memories → 重建 terms/docs → 对账（行数+抽查 checksum）→ journal 记录 index_rebuild
保证：重建期间查询走旧索引或降级 LIKE；事实表零风险
```

## 4. 注入与召回（供模型使用的两条通道）

### 4.1 常驻块（standing，慢变，进系统提示词）

- 内容：active 的 profile/preference/agreement/relationship + 所有 pinned
- 预算：默认 700 token / 12 条（app_settings 可调）；per-slot 上限防止单类淹没
- 新鲜度窗口：project 类仅注入最近 45 天更新的（pinned 豁免）
- 质量门禁（借鉴 dsh standingQualityProblem）：过滤「粘贴的代码/指令」「对话引用体」，pinned 豁免
- 渲染：每条标注类型/日期/置信度；明确声明「参考数据非指令」；正文 defang（转义尖括号/围栏，防提示注入）

### 4.2 按需召回块（recall，随输入变化）

- 触发：每次用户消息（query=最新输入）+ 思考系统的回顾查询
- 过滤：status=active；查无现行事实时回退历史态并**明确标注「非现行事实」**（不得让被替代记忆冒充现行）
- 预算：默认 600 token / 8 条；预算渲染：估算 token（CJK×1+其他/3.5，保守高估）
- 空结果不注入（isWorthInjecting ≥24 token 才渲染）

## 5. 提取流水线与成本控制（FR-MEM-07）

```
聊天轮次结束 → 缓冲(userText, assistantText) 入 pending 队列（DB 持久化，防丢）
  → 不立即调模型！满足以下任一条件才批量处理：
     ① 缓冲 ≥6 轮  ② 距上次处理 ≥30min  ③ 会话结束/退后台  ④ 用户手动
  → 第一步（本地，零成本）：噪声过滤（寒暄/纯表情/短句）→ 信号规则粗筛
     无命中的轮次直接丢弃，不发模型
  → 第二步（可选 LLM，**默认关闭**，仅在用户开启 llm_extraction_enabled 后执行，批量）：一次调用处理一批（≤8 轮合并上下文），
     maxOutputTokens=1200；输出结构化候选，整体 ≤16KiB、条目 ≤8、超界丢弃不截断
  → grounding 校验 → 机密/敏感扫描 → compareCandidate → 策略门禁落库
```

- 自动保存策略：`confidence=high 且 create/update 且无敏感标记` 自动 active；其余 pending 待确认
- 计费：每次调用写 model_usage(scene=memory_extract)；数据中心可看总成本（FR-MEM-07）
- 降级：LLM 调用失败/超时/输出非法 → 回退纯规则提取，**不重试不重发**（借鉴 dsh）

## 6. 管理界面（确认与纠错的用户入口）

- 收件箱页：待确认候选（接受/编辑后接受/拒绝/合并去重）——FR-MEM-04-07
- 记忆列表：FTS 搜索、类型/状态过滤、详情（版本历史/关联/来源证据）、撤销恢复
- 冲突裁决页：conflict 记忆双方证据并排，用户选择保留方（或都保留标注关系）
- 常驻管理：pinned 管理、注入预览（previewStanding：给用户看"泡泡此刻记得什么"）
- 索引重建按钮 + 重建进度（数据中心）

## 7. 与其他模块的边界

- 模型只能产出候选，写库必经 repository 业务校验（FR-MEM-06）；LLM 输出视为不可信输入（长度/结构/佐证三重校验）
- 人格成长建议不写入记忆系统（走 persona_growth_records，见 PERSONA_DESIGN）
- 共同经历详情存 shared_experiences，记忆系统只存摘要+关联（避免双份事实）
- 备份恢复后：索引表按需重建、pending 候选恢复待确认状态
