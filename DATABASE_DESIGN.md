# 泡泡 Bubble V2.0 — 数据库设计（DATABASE_DESIGN）

> 引擎：SQLite + Drift（加密见 SECURITY_AND_PRIVACY）。**SQLite 是唯一事实来源，一切索引/缓存为可重建派生数据**（FR-MEM-06）。
> 通用约定：未注明则 `id TEXT PRIMARY KEY`（UUID v4）；时间戳 `created_at/updated_at`（UTC ISO-8601 TEXT）；软删 `deleted_at`（NULL=未删）；来源 `source`；版本 `schema_version`。

---

## 1. 表总览（29 张需求表 + 3 张派生索引表）

| 域 | 表 |
| -- | -- |
| 会话聊天 | conversations, messages, attachments |
| 人格 | persona_profiles, persona_versions, persona_growth_records, expression_samples |
| 记忆 | memories, memory_relations, memory_versions, memory_candidates |
| 思考与主动 | thinking_tasks, thinking_results, proactive_candidates, proactive_actions, scheduled_messages |
| 经历 | shared_experiences |
| 内容 | posts, diaries, letters |
| 反馈 | feedback_records |
| 模型 | models, model_usage |
| 系统 | notification_settings, app_settings, background_task_logs, migration_records, backup_records, journal_logs |
| 派生索引（可重建） | memory_index_terms, memory_index_docs, content_index_terms |

## 2. 表结构详设

### 2.1 conversations（会话）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | UUID |
| title | TEXT NOT NULL | 会话名，可重命名 |
| sort_weight | INTEGER | 手动置顶排序 |
| last_message_at | INTEGER(INDEX) | 列表排序用（毫秒时间戳） |
| last_read_at | INTEGER | 未读标记 |
| message_count | INTEGER | 冗余计数（维护于事务内） |
| created_at / updated_at / deleted_at | | 软删 |

- 索引：`(deleted_at, last_message_at DESC)`
- 生命周期：永久保留；软删后 30 天可在数据中心彻底清除
- 删除策略：软删 → 级联询问：仅删会话索引、保留消息归档 or 连带删除消息及其附件（用户选择，FR-SEC-04）；硬删在事务内级联
- 关联：messages.conversation_id、attachments.message_id

### 2.2 messages（消息）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | UUID（通知深链引用此 ID） |
| conversation_id | TEXT NOT NULL FK→conversations | |
| role | TEXT CHECK(user|assistant|system) | |
| seq | INTEGER NOT NULL | 会话内递增序号（事务内取 max+1） |
| content | TEXT NOT NULL | Markdown 文本 |
| status | TEXT CHECK(sending|streaming|sent|failed|interrupted|deleted) | 消息状态机 |
| error_code / error_detail | TEXT NULL | 网络错误分类落库（FR-NET-02） |
| message_kind | TEXT CHECK(normal|continuation|proactive|system_note) | proactive=主动消息（FR-PRO-03） |
| proactive_meta | TEXT(JSON) | 来源类别/关联记忆 id 列表/决策动作 id（仅 proactive） |
| request_id | TEXT(INDEX) | 幂等键（重试不重复计费落库） |
| model_id | TEXT FK→models | 生成所用模型 |
| token_prompt / token_completion / token_reasoning / cost_est | INTEGER/REAL | 计费：DeepSeek 返回的 `completion_tokens_details.reasoning_tokens` 单列记录（FR-MDL-03） |
| reasoning_content | TEXT | DeepSeek 思考链（可选保存） |
| created_at / updated_at / deleted_at | | |

- 索引：`(conversation_id, seq)`、`(status)`、`(message_kind, created_at)`
- 生命周期：永久；删除走软删（支持回收站），数据中心可彻底清除
- 删除策略：单条删除询问是否连删附件（FR-SEC-04）；删除时联动取消其未投递通知（FR-IOS-06）
- 关联：attachments.message_id、scheduled_messages.message_id

### 2.3 attachments（附件）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | |
| message_id | TEXT NULL FK→messages | NULL=说说图片等非聊天附件 |
| owner_kind | TEXT CHECK(message|post|diary|letter|import) | |
| owner_id | TEXT | 冗余便于检索 |
| rel_path | TEXT NOT NULL | 沙盒内相对路径 `Attachments/2026/11/<uuid>.jpg`（ADR-6） |
| mime / size_bytes / width / height | | |
| ocr_text | TEXT | OCR 结果，参与 content_index_terms |
| ai_caption | TEXT | 视觉模型描述（能力允许时） |
| sha256 | TEXT | 完整性校验/去重 |
| created_at / deleted_at | | |

- 索引：`(owner_kind, owner_id)`、`(sha256)`
- 生命周期：跟随 owner；孤立附件（无 owner 记录）由数据中心"孤立附件清理"处理（FR-SEC-03）
- 删除策略：删除消息→询问连删文件；清理前先做缺失检查（DB 有记录文件缺失=broken，文件存在无记录=orphan）
- 一致性：写入顺序=先文件后 DB 记录（崩溃产生 orphan，可清理，不产生断链）

### 2.4 persona_profiles（人格主档案，单行）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | 固定单行 |
| name / avatar_path / intro | | 昵称/头像/简介（FR-MISC-01） |
| core_system_prompt | TEXT | 组装后的核心人格提示词（生效版本快照） |
| active_version_id | TEXT FK→persona_versions | |
| interests | TEXT(JSON) | 兴趣标签 |
| updated_at | | |

- 删除策略：**不允许删除**（人格是产品根基）；仅版本流转
- 关联：persona_versions

### 2.5 persona_versions（人格版本）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | |
| version_no | INTEGER 递增 | |
| layer | TEXT CHECK(core|growth|samples) | 四层中前三层的快照粒度 |
| content | TEXT(JSON) | 该版本完整内容（核心人格字段/成长字段/表达样本） |
| change_reason | TEXT | 变化原因（FR-PER-01） |
| confirmed_by | TEXT CHECK(user|migration|init) | 核心层必须 user（FR-PER-02） |
| is_active | INTEGER | |
| created_at | | |

- 索引：`(is_active)`、`(version_no)`
- 生命周期：永久（历史版本不可清，可恢复=撤销手段）
- 关联：persona_growth_records.version_id

### 2.6 persona_growth_records（成长记录）

字段：id, version_id FK, growth_type（称呼/兴趣/口头禅/表达习惯/观点变化）, before_value, after_value, reason, related_memory_ids(JSON), related_experience_id FK, status(proposed|confirmed|reverted), confirmed_at, created_at。
- 索引：`(status)`、`(version_id)`
- 删除策略：不物理删除；reverted 记录撤销痕迹（FR-FBK-02 撤销历史）

### 2.7 expression_samples（表达样本）

字段：id, content, context_note（代表性表达出处说明）, style_tags(JSON), related_message_id FK NULL, pinned, created_at。
- 索引：`(pinned)`；参与 content_index_terms
- 删除策略：软删

### 2.8 memories（长期记忆，核心表）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | `mem_<时间紧凑>_<8hex>`（沿用 dsh 风格，可读） |
| type | TEXT NOT NULL | 10 类映射：profile/preference/experience_joint(共同经历引用)/event/relationship/agreement/opinion/lesson/project/important_experience（FR-MEM-02） |
| status | TEXT CHECK(pending|active|stale|superseded|conflict|archived) | 6 态生命周期（FR-MEM-03） |
| title | TEXT ≤300 | |
| summary | TEXT | 核心内容 |
| body | TEXT | 附加说明 |
| confidence | TEXT CHECK(low|medium|high) | low 不参与注入（借鉴 dsh） |
| importance | INTEGER 0-100 | 召回排序权重 |
| pinned | INTEGER | 常驻记忆（FR-MEM-04-12） |
| aliases / tags | TEXT(JSON) | 检索辅助 |
| evidence | TEXT | 来源追踪：会话/消息引用+说明 |
| source_session_id / source_message_ids | TEXT/JSON | 来源追踪（FR-MEM-04-08） |
| supersedes | TEXT(JSON) | 被本条替代的旧记忆 |
| superseded_by | TEXT | |
| conflicts_with | TEXT(JSON) | 冲突双方证据保留（FR-MEM-05） |
| is_resident | INTEGER | 常驻注入开关（与 pinned 配合） |
| sensitivity | TEXT JSON | 敏感类别标记（health/finance/...，默认不自动保存 FR-MEM-05） |
| recall_count / last_recalled_at | INTEGER NULL | 召回统计：排序加权（重要度×新鲜度）与 stale 评估依据（长期未召回且低重要度→候选 stale） |
| schema_version | INTEGER | |
| created_at / updated_at / deleted_at | | created_at 永不因编辑改变 |

- 索引：`(status, type)`、`(pinned)`、`(updated_at)`
- 生命周期：active→（新证据）superseded / stale；archived 仅归档不真删（借鉴 dsh「删除只归档」，真删=数据中心两级确认）
- 删除策略：软删+journal 留痕；撤销恢复=状态回退（FR-MEM-04-11）
- 关联：memory_relations、memory_versions、memory_candidates.target_id

### 2.9 memory_relations（记忆关联）

字段：id, from_memory_id FK, to_memory_id FK, relation_type(related|supports|contradicts|caused_by), strength 0-100, discovered_by(rule|thinking|user), created_at。
- 索引：`(from_memory_id)`、`(to_memory_id)`；UNIQUE(from,to,type)
- 生命周期：跟随记忆；双向查询用两个方向索引
- 来源：自主思考发现的关联=「已发现但未处理的记忆关联」（FR-ATH-02）

### 2.10 memory_versions（记忆版本）

字段：id, memory_id FK, version_no, before_snapshot(JSON), after_snapshot(JSON), change_kind(create|update|merge|status|supersede), reason, created_at。
- 用途：版本管理与撤销恢复（FR-MEM-04-09/11）；恢复=回放 after→before 快照
- 索引：`(memory_id, version_no)`

### 2.11 memory_candidates（记忆候选/收件箱）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | |
| proposed_title / proposed_summary / proposed_type | | 模型或规则产出 |
| confidence | TEXT | |
| importance | INTEGER | |
| origin | TEXT CHECK(rule|llm|thinking|import) | |
| grounding_note | TEXT | 佐证原文定位说明（模型主张必须 grounded，借鉴 dsh） |
| scan_flags | TEXT(JSON) | 机密/敏感扫描结果 |
| compare_result | TEXT | 与现有记忆比较：create/update/merge/conflict |
| target_memory_id | TEXT FK NULL | update/merge/conflict 指向 |
| status | TEXT CHECK(pending|confirmed|rejected|applied) | |
| refusable / expires_at | | 过期自动降权（防堆积） |

- 索引：`(status, created_at)`
- 生命周期：pending→确认 applied（转入 memories）/拒绝 rejected；30 天未处理过期（进 archived 状态展示）

### 2.12 thinking_tasks（思考任务，状态机）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | |
| trigger | TEXT CHECK(foreground_timer|background_bgtask|app_resume|manual) | |
| bg_task_id | TEXT NULL | 本次执行对应的 BGTaskScheduler 任务标识（与 background_task_logs 关联，前台/手动触发为 NULL） |
| state | TEXT CHECK(created|loading|reviewing|analyzing|saving|deciding|done|failed|interrupted) | FR-ATH-03 八步映射 |
| checkpoint | TEXT(JSON) | 断点：当前步骤+游标（上次回顾位置 FR-IOS-07） |
| reviewed_until | INTEGER | 历史回顾推进位置（消息时间游标） |
| scope_note | TEXT | 本轮回顾范围说明 |
| started_at / finished_at / interrupted_at | | |
| result_count | INTEGER | |

- 索引：`(state)`、`(trigger, started_at)`
- 生命周期：done 后保留最近 N=200 条（可配置）；interrupted 是恢复入口（app_resume 扫描）
- 删除策略：滚动手动清理；数据中心可见状态

### 2.13 thinking_results（思考产出）

字段：id, task_id FK, result_kind(new_connection|reunderstanding|opinion_change|topic_worth_continuing|share_worthy|diary_material|memory_candidate_ref|proactive_candidate_ref|quiet_decision), content, related_memory_ids JSON, related_message_ids JSON, confidence, created_at。
- 索引：`(task_id)`、`(result_kind)`
- 生命周期：永久保留（泡泡的"想法史"，供后续回顾）

### 2.14 proactive_candidates（主动行为候选池）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | |
| action_kind | TEXT CHECK(chat|post|diary|letter|review_experience|memory_housekeeping|quiet) | FR-DEC-01 |
| title / content_draft | TEXT | 内容草稿（chat 类为消息草稿） |
| source_kind | TEXT | 11 类来源（FR-PRO-02）：history/memory/experience/topic/agreement/interest/opinion_change/growth/thinking/memory_link/self_theme |
| related_memory_ids / related_experience_id / related_task_id | FK JSON | |
| priority | INTEGER 0-100 | |
| status | TEXT CHECK(pending|queued|executing|executed|cancelled|expired|rejected) | |
| dedup_key | TEXT UNIQUE 风格哈希 | 重复检测（同话题重复表达，FR-DEC-02） |
| cooldown_until | INTEGER | 冷却 |
| expires_at | INTEGER | 过期（FR-DEC-02） |
| created_at / updated_at | | |

- 索引：`(status, priority DESC)`、`(dedup_key)`、`(expires_at)`
- 生命周期：executed→proactive_actions 留痕；expired/rejected 保留 30 天供回顾
- 关联：scheduled_messages.candidate_id

### 2.15 proactive_actions（执行记录）

字段：id, candidate_id FK, action_kind, executed_at, deliverable_type(message|post|diary|letter), deliverable_id, decision_note（为何执行/为何放弃）, user_feedback_id FK NULL, created_at。
- 索引：`(executed_at)`；执行记录+用户反馈闭环（FR-DEC-02）

### 2.16 scheduled_messages（主动消息队列，需求指定字段）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | |
| content | TEXT NOT NULL | |
| scheduled_at | INTEGER NOT NULL | 计划投递时间（时区感知，存 UTC+渲染时区） |
| status | TEXT CHECK(pending|scheduled|delivered|cancelled|expired) | 需求 5 态 |
| conversation_id | TEXT FK | |
| message_id | TEXT FK NULL | 落库后的真实消息 ID（delivered 时回填） |
| candidate_id | TEXT FK NULL | 溯源 |
| reason | TEXT | 生成原因/关联记忆（FR-PRO-03） |
| notification_id | TEXT | iOS 通知标识（取消用） |
| scheduled_timezone | TEXT | 计划时刻所用时区（如 Asia/Shanghai）——时区变化重排的判定依据（FR-IOS-06） |
| created_at / expires_at | | |

- 索引：`(status, scheduled_at)`、`(expires_at)`、`(scheduled_timezone)`
- 生命周期：pending→scheduled→delivered；cancelled（用户取消/消息删除/话题失效/会话删除级联）/expired（超期未投递）
- 级联：conversation 硬删 → 该会话 scheduled_messages 全部 cancel（含 cancel iOS 通知），事务内完成；软删会话不级联（恢复后队列仍有效）
- 防堆积：队列上限 20 条，超限拒绝新计划并提示；每日投递上限由 ProactivePolicy 控制（FR-IOS-06）

### 2.17 shared_experiences（共同经历）

字段：id, name, occurred_at（时间）, event_content, related_conversation_ids JSON, related_memory_ids JSON, importance 0-100, user_perspective, bubble_perspective, review_log(JSON 数组：回顾时间+回顾内容), created_at / updated_at / deleted_at。
- 索引：`(occurred_at)`；参与全局索引
- 删除策略：软删；**历史事实字段不可被 AI 修改**，review_log 只追加（FR-EXP-03）

### 2.18 posts（说说）

字段：id, content, mood(心情), topic(话题), image_ids JSON, origin(autonomous|user_topic), related_memory_ids JSON, related_conversation_id FK NULL, published_at, edited_at, deleted_at。
- 索引：`(published_at DESC)`；content 参与索引
- 删除策略：软删（用户编辑/删除 FR-POST-02）

### 2.19 diaries（日记）

字段：id, entry_date（日期归档）, content, origin(ai_organized|manual), related_message_ids JSON, related_memory_ids JSON, versions(JSON 版本保留 FR-DIA-01), deleted_at, created_at/updated_at。
- 索引：`(entry_date)`；导出 Markdown（FR-DIA-01）

### 2.20 letters（信件）

字段：id, direction(bubble_to_user|user_to_bubble), state(draft|sent), title, content, related_memory_ids JSON, related_experience_ids JSON, sent_at, deleted_at。
- 索引：`(direction, state, sent_at)`

### 2.21 feedback_records（反馈）

字段：id, target_kind(expression_style|proactive_frequency|post_content|memory_correction|persona_suggestion|proactive_action), target_id, verdict(like|dislike|adjust|correct), note, action_taken(JSON：实际调整动作，仅成长层), reverted_at, created_at。
- 索引：`(target_kind, target_id)`；单次反馈不直改核心人格（FR-FBK-02），action_taken 仅允许成长层变更建议

### 2.22 models（模型注册表）

字段：id, provider(deepseek|openai_compatible|local_reserved), display_name, api_base_url, api_key_secure_key（Keychain 键名，不存明文）, model_tag, params(JSON: temperature 等), capabilities(JSON: vision/context_length/streaming 检测结果), enabled, is_default, last_checked_at。
- 生命周期：用户管理；删除前检查引用（messages.model_id 置空化处理）

### 2.23 model_usage（用量统计）

字段：id, model_id FK, scene(chat|memory_extract|thinking|proactive|persona|image_ocr), token_prompt, token_completion, cost_est, request_count, day（按天聚合，INDEX UNIQUE(model_id,scene,day)）。
- 用途：Token/费用记录（FR-MDL-03、FR-MEM-07 成本控制）

### 2.24 background_task_logs（后台任务日志）

字段：id, task_type(apprefresh|processing), event(submit|start|finish|fail|expired), payload(JSON), started_at, finished_at, next_submit_at。
- 用途：FR-IOS-07 上次执行结果；数据中心可见
- 生命周期：保留 90 天滚动清理

### 2.25 notification_settings（通知设置，单行）

| 字段 | 类型 | 说明 |
| -- | -- | -- |
| id | TEXT PK | 固定单行 |
| privacy_mode | TEXT CHECK(full|minimal|hidden)，**默认 minimal** | 三档：完整显示/仅「泡泡有新消息」/隐藏正文（FR-IOS-08；D-3 最终决策：默认 minimal，用户可改） |
| allow_post_notify | INTEGER | 允许说说通知（FR-SET-01） |
| allow_diary_letter_notify | INTEGER | 允许日记与信件提醒（FR-SET-01） |
| daily_notify_cap | INTEGER | 每日通知上限（按本地日历日计数） |
| quiet_start / quiet_end | TEXT HH:mm | 勿扰时段（跨午夜允许，如 23:00–08:00） |
| quiet_timezone | TEXT | 勿扰时段绑定时区（时区变化时提示重校准） |
| updated_at | | |

- 生命周期：单行 upsert，随全库备份；无历史版本
- 关联：无外键；由 NotificationScheduler 与 ProactivePolicy 读取执行

### 2.26 app_settings（应用 KV 配置）

主键/结构：`key TEXT PRIMARY KEY`，`value TEXT(JSON)`，`updated_at`。键空间枚举（实施时以常量类冻结，新增键必须登记）：

| 键 | 值类型 | 默认 | 用途 |
| -- | -- | -- | -- |
| proactivity_level | TEXT(conservative\|balanced\|active) | active | 主动程度档位（FR-SET-01；D-4 最终决策：默认积极档，符合高度自主定位） |
| daily_proactive_cap | INTEGER | 2 | 每日主动联系上限 |
| min_proactive_interval_min | INTEGER | 240 | 最短主动间隔（分钟） |
| standing_budget_tokens / standing_max_items | INTEGER | 700/12 | 常驻记忆块预算（MEMORY §4.1） |
| recall_budget_tokens / recall_max_items | INTEGER | 600/8 | 按需召回预算 |
| memory_auto_save_policy | TEXT | high_only | 自动保存策略（FR-MEM-05） |
| memory_extract_trigger | TEXT(JSON) | {bufferRounds:6, intervalMin:30} | 记忆提取批处理触发条件 |
| llm_extraction_enabled | INTEGER | 0 | LLM 提取开关（D-2 待确认） |
| thinking_interval_min | INTEGER | 90 | 前台思考间隔 |
| token_budget_daily | INTEGER NULL | NULL=不限 | 每日 Token 预算上限（R-07） |
| lock_method / lock_after_bg_min / lock_fail_policy | TEXT/INTEGER/TEXT | faceid/5/delay_lock | 应用锁（FR-SEC-01） |
| last_proactive_at / last_thinking_at | INTEGER | — | 最近主动/思考时间戳（FR-IOS-07） |
| app_first_run_done / capability_notice_ack | INTEGER | 0 | 首启引导与能力说明确认（R-02 预期管理） |

- 生命周期：KV upsert；重要键（proactivity_level 等）变更写 journal_logs
- 删除策略：随"删除全部数据"清除；单键不提供 UI 删除

### 2.27 migration_records（迁移索引）

字段：id, source(astrbot), source_ref（原文件路径/消息 ID）, target_table, target_id, category(chat|persona|relation|memory|experience|attachment|config|plugin), status(migrated|skipped|failed|verified), notes, migrated_at。
- 索引：`(source_ref)`、`(category,status)`；完整性检查=对账源/目标计数（FR-MIG-01）

### 2.28 backup_records（备份记录）

字段：id, kind(manual|auto|pre_migration), path, size_bytes, sha256, table_counts(JSON 对账快照), db_schema_version, created_at, verified_at, status(ok|corrupt)。
- 完整性检查（FR-DB-02）：恢复前校验 sha256+对账计数

### 2.29 journal_logs（变更日志，追加式）

字段：id INTEGER AUTOINCREMENT PK, op(create|update|delete|archive|supersede|merge|confirm|reject|status_change|index_rebuild|restore|notify_schedule|notify_cancel), entity_table, entity_id, before_digest（有界摘要≤160字）, after_digest, reason, source(user|rule|llm|thinking|migration), at。
- 索引：`(entity_table, entity_id)`、`(at)`
- 生命周期：追加式；按月分卷归档可选；借鉴 dsh journal（有界摘要、崩溃容错：坏行跳过）

### 2.30 派生索引表（可重建，绝非事实来源）

```
memory_index_terms(token TEXT, doc_id TEXT, field_weight INTEGER, PRIMARY KEY(token,doc_id))
  -- bigram/单词倒排：CJK 单字+双字、拉丁词；字段权重 标题8/别名标签6/摘要3/正文1
memory_index_docs(doc_id TEXT PK, type, status, title, preview, importance, pinned,
                  updated_at, checksum)     -- 文档元数据缓存
content_index_terms(token TEXT, doc_kind TEXT, doc_id TEXT, field_weight INTEGER,
                  PRIMARY KEY(token,doc_kind,doc_id))
  -- 聊天/说说/日记/信件/经历/附件OCR 的全局搜索倒排（FR-MISC-03）
```
- 重建：索引失效判定（版本不匹配/校验失败/手动触发）→ 全量重建，零数据丢失（借鉴 dsh「索引丢失=自动重建」）
- 相似度：重叠系数 `|A∩B|/min(|A|,|B|)`（用 ≥2 字 token + 拉丁词）

## 3. 事务与一致性

| 场景 | 事务边界 |
| -- | -- |
| 发消息 | messages+conversations.last_message_at+model_usage 同事务；`seq` 在同一事务内取 `MAX(seq)+1`（单用户单设备，无并发分配问题；批量插入多气泡在单事务内依次递增） |
| 记忆确认 | memory_candidates.status + memories 插入/更新 + memory_versions + journal_logs 同事务 |
| 状态迁移记忆 | memories.status + memory_versions + journal_logs 同事务 |
| 主动消息投递 | scheduled_messages.status + messages 插入 + proactive_actions 同事务 |
| 会话硬删 | conversations+messages+attachments 记录+文件删除（文件删除在事务提交后，失败转 orphan 清理） |

## 3.1 数据库级约定（PRAGMA 与性能）

```sql
PRAGMA journal_mode = WAL;          -- 崩溃安全 + 读写并行
PRAGMA foreign_keys = ON;           -- 每个连接必须开启（drift beforeOpen 统一执行）
PRAGMA synchronous  = NORMAL;       -- WAL 下安全与性能平衡
PRAGMA page_size    = 4096;         -- 建库前设定
PRAGMA busy_timeout = 5000;         -- 后台任务与前台并发访问兜底
PRAGMA optimize;                    -- 每次退后台/思考结束时执行
```
- 单连接策略：Drift 全 App 共享一个 QueryExecutor，避免多连接锁竞争；BGTask 回调经同一 isolates 通道访问
- 大表（messages）定期 `ANALYZE`；索引表重建时使用事务包裹批量插入

## 4. Schema 迁移策略

- drift `schemaVersion` 单调递增；每版生成 `schema_vN.json` 快照与验证测试（drift_dev 工具链）
- 破坏性变更走"新增列+回填"两步；migration_records 记录数据级迁移
- 版本兼容：老备份（低 schema）可被新版本恢复（升级路径=回放迁移步骤）；新备份不向后兼容（明确告知）

## 5. 损坏隔离与恢复

1. 打库时 `PRAGMA integrity_check`（轻量 quick_check）；失败 → 数据中心告警
2. WAL 模式；坏页尝试 `.recover` 导出重建；无法恢复 → 最近 backup_records 恢复流程（需用户确认）
3. 单表逻辑损坏（如索引表错乱）：派生表直接重建；事实表坏行隔离到 `*_quarantine` JSON 文件供导出分析（借鉴 dsh quarantine 思路）

## 6. 导出与备份

- 导出：JSON 全量（机器可回灌）+ Markdown 按域导出（人格/记忆/说说/日记/信件/经历，人类可读，FR-DIA-01 导出）
- 备份：DB 文件+附件目录+sha256 清单打包；备份完整性=恢复前对账 table_counts（backup_records）
- 删除全部数据：明确展示范围清单，备份文件需独立确认保留/删除（FR-SEC-04）
