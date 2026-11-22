# 泡泡 Bubble V2.0 — 人格中心设计（PERSONA_DESIGN）

> 人格是独立系统，不是一段系统提示词（FR-PER 前提）。四层结构 + 版本管理 + 确认门禁，保证人格在换模型/重装/恢复后连续（FR-PRD-07、FR-PER-05）。

---

## 1. 四层人格模型（FR-PER-01）

| 层 | 内容 | 存储载体 | 可变性 | 修改权 |
| -- | -- | -- | -- | -- |
| L1 核心人格 | 身份、性格底色、价值观、关系定位、说话习惯、行为边界 | persona_versions(layer=core) 快照 + persona_profiles 生效快照 | **极低**：修改必须用户逐字确认 | 仅用户；模型只能提议 |
| L2 成长人格 | 称呼、兴趣、口头禅、表达习惯、观点变化 | persona_versions(layer=growth) + persona_growth_records | 中：可随经历自然演化 | 模型可提议（growth_records status=proposed），用户确认或设定自动采纳策略（仅限非核心项） |
| L3 表达样本 | 历史代表性表达、语言风格 | expression_samples | 中：随聊天积累 | 用户 pin/删除；自动收集仅作候选 |
| L4 成长记录 | 变化原因、关联经历、确认时间、历史版本、撤销记录 | persona_growth_records + memory_versions 思路 | 只追加 | 系统维护，reverted 可撤销 |

## 2. 提示词组装（PersonaAssembler）

```
输出顺序（进入每次模型调用的 system）：
  ① 核心人格块：L1 快照（稳定内容放最前，利于 provider 前缀缓存——借鉴 dsh 常驻块缓存意识）
  ② 成长人格块：L2 当前值（称呼/口头禅/近期兴趣，带时间标注）
  ③ 表达风格块：L3 pinned 样本 ≤6 条 + 风格要点
  ④ 常驻记忆块：MemorySearch.standing（见 MEMORY_DESIGN §4.1）
  ⑤ 当前场景块：会话名/时间/最近话题摘要
预算：①~③ 固定预算 + ④ 700token 默认 → 总计控制在模型上下文的合理比例内
反模板化约束（写入核心人格块固定段）：
  - 明确禁止客服腔（"作为AI助手我…"）、禁列表腔回复闲聊、禁复读用户问题
  - 要求自然分段、允许口语、允许不同意见与幽默
  - 表达样本以"参照风格"而非"照抄"呈现
```

每次组装结果落 `persona_profiles.core_system_prompt` 快照 + journal 留痕，保证调试可追溯。

## 3. 版本管理与恢复（FR-PER-04）

- `persona_versions` 每次确认变更生成新版本（version_no 递增，content 为全量 JSON 快照）
- 恢复 = 选定历史版本 → 生成"回退版本"（不是覆盖历史），diff 面板展示差异 → 用户确认 → journal 记 restore
- 重装/备份恢复：人格随全库备份恢复；换模型只是 ModelRouter 层切换，人格组装逻辑不变（FR-PRD-07）
- 实验版 Bundle ID 与正式版各自独立数据库，互不影响（FR-ENG-03）

## 4. 确认门禁（FR-PER-02）

```
变更来源分三类：
  A. 用户直接编辑：立即生效，生成新版本（confirmed_by=user）
  B. 模型成长建议（对话中自然产生 / 反馈处理产生）：
       → persona_growth_records(status=proposed, before/after, reason, 关联记忆)
       → UI 展示待审列表 → 用户接受 → 仅 L2 生效并生成新版本；拒绝则留痕
       → 涉及 L1 的建议：模型最多给出建议文本，必须用户逐字编辑确认后才写入
  C. 用户反馈（FR-FBK）：单次反馈只产生成长层建议或行为调整（如降低主动频率），
       任何路径都不允许单次反馈直接改 L1（FR-FBK-02）
```

## 5. 自然表达保障（FR-PER-03）

| 手段 | 说明 |
| -- | -- |
| 表达样本持续积累 | 好的表达（用户点赞/自动筛选）进 samples，风格可进化 |
| 观点系统 | opinions 类记忆 + growth_records 记录观点变化，允许"我之前觉得X，现在觉得Y" |
| 多样性注入 | 生成时提供"今日心情/最近经历"上下文（来自 thinking_results），避免同题同答 |
| 不同意见授权 | 核心人格中明确写入"可以有不同意见、可以拒绝不合理请求"的边界条款 |
| 重复表达检测 | proactive/聊天生成前对照近期输出（dedup_key 思路），避免口头禅滥用 |
| 模型切换一致性 | 人格块与模型解耦；切换后首条消息注入"场景说明"提示连续性（不伪造记忆，只是提醒） |

## 6. 泡泡主页（FR-MISC-01）

数据来源映射：头像/昵称/简介/兴趣 ← persona_profiles；人格成长记录 ← persona_growth_records（时间线展示）；历史说说 ← posts；共同经历 ← shared_experiences。主页即人格四层的可视化窗口。

## 7. 测试要点关联

人格稳定性/版本恢复/切换连续性/核心保护 → TEST_PLAN §1；关键断言：任何自动化路径都无法绕过 L1 确认门禁（用集成测试证明）。
