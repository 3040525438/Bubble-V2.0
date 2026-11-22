# 泡泡 Bubble V2.0 — 数据迁移规划（MIGRATION_PLAN）

> 原则（FR-MIG）：**AstrBot 是迁移资料来源，不是运行依赖**；完整迁移、保留原始、可回滚、可对账。基于旧工程已实现的 AstrBot 导入器（DaFeiYuFlutter `core/import/astrbot_importer.dart`）验证过的真实源结构设计，V2 重写为全新实现。

---

## 1. 迁移源清单（真实路径，来自旧导入器）

| 源 | AstrBot 路径 | 内容 | V2 目标表 |
| -- | -- | -- | -- |
| 聊天库 | `data/plugin_data/chat_memory/chat_memory.db` | 历史会话与消息（含时间戳） | conversations, messages |
| 长期记忆库 | `diary/memory.db` | 旧长期记忆条目 | memories, memory_versions |
| 人格库 | `data/data_v4.db` | 人格提示词与条目 | persona_profiles, persona_versions, expression_samples |
| 日记目录 | `diary/`（`yyyy-MM-dd.md`，`txt/` 为镜像） | 每日日记 | diaries（txt 镜像去重） |
| 信件目录 | `letters/` | 历史信件 | letters |
| 读书笔记 | `books/notes/` | 文档型记忆 | memories(type=knowledge, source=import) |
| 关系账本 | `data/plugin_data/astrbot_plugin_private_companion/companions.json` | 关系设定/里程碑/经历 | shared_experiences, relationship 类记忆 |
| 图片/语音附件 | 各源内嵌/目录 | 附件 | attachments（语音按 FR-NEG 归档保留不提供播放） |
| 主配置 | AstrBot config JSON | 可复用配置（模型地址等） | models（API Key 不迁移，重新录入） |
| 插件行为资料 | `data/plugin_data/*` 其他 | 原样归档留档 | migration_records 记录 + 备份区存档 |

## 2. 15 步完整迁移流程（FR-MIG-01 逐条落实）

```
准备（外部，Windows/文件交换阶段）：
  ① 完整备份原始资料（整目录 zip，双副本，校验 sha256）
  ② 保留原始文件和版本（备份永不改动；工作副本才被读取）
  ③ 分类整理（按上表 10 类源归类，清单化）
  ④ 建立迁移索引（migration_records 预登记：source_ref → 目标占位）

App 内导入（V2 App「数据中心 → 迁移」向导）：
  ⑤ 迁移聊天及时间（chat_memory.db → conversations+messages，保留原时间戳/序号，
     conversation 标 source=import；幂等：source_ref+sha256 去重）
  ⑥ 迁移人格提示词（data_v4.db → persona_versions(layer=core, confirmed_by=migration)，
     导入人格不覆盖既有核心人格——冲突时进入人工选择界面）
  ⑦ 迁移关系设定（companions.json → relationship 类记忆 + 用户视角字段）
  ⑧ 迁移长期记忆（memory.db → memories，全部 status=active 但 source=import、
     confidence=medium 起步，逐条可纠错；重复与现有记忆经重叠系数比对进待确认）
  ⑨ 迁移重要经历（账本里程碑/长记忆中的经历 → shared_experiences，保留原文）
  ⑩ 迁移图片语音附件（抽取→Attachments/<yyyy>/<mm>/，sha256 登记；语音归档不提供播放）
  ⑪ 迁移可复用配置（模型地址/参数 → models；**API Key 一律不迁移**，用户重录）
  ⑫ 迁移插件行为资料（无法映射的资料 JSON 原样入「存档区」文件，只读可导出）
  ⑬ 保存来源和迁移记录（每行写入 migration_records：source_ref/target_table/target_id/
     status/source sha256；batchId 串整批）
  ⑭ 检查迁移完整性（对账：源行数 vs 目标行数 vs 记录数三向核对；失败项清单展示，
     允许重跑——幂等设计保证重跑不重复插入）
  ⑮ 验证备份恢复（迁移完成后强制做一次全库备份 backup_records(kind=pre_migration/post_migration)，
     并在沙盒中验证可恢复，完成后标记 verified）
```

## 3. 安全与回滚

| 机制 | 说明 |
| -- | -- |
| 预演（dry-run） | 先跑一遍生成报告（各实体数量/冲突/待处理），用户审阅后再正式导入 |
| 批次回滚 | 每批 batchId；按 migration_records 反查目标 ID 整批软删回滚（旧导入器已验证该模式） |
| 不覆盖原始数据 | 源文件只读；App 内无任何写回 AstrBot 目录的路径（FR-MIG-02） |
| 不删除覆盖原始数据 | ①② 的双副本备份独立于 App 存储 |
| 冲突处理 | 人格冲突/日记日期冲突/重复记忆等进入「待处理区」列表（reason 标注），不静默合并 |
| 时间完整性 | 聊天保留原 UTC 时间戳；跨时区显示按用户当前时区渲染 |

## 4. 迁移后状态

- 导入数据打 `source=import` 标记，UI 中可按来源过滤
- AstrBot 此后与 App 无任何依赖关系（不读取其目录、不需其存在）
- 完整性检查入口：数据中心 → 迁移对账页（随时重跑对账，不重导数据）
- 迁移的人格/记忆纳入版本管理与纠错流程（memory_candidates 纠错通道）
