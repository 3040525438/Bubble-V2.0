// 记忆域：memories / memory_relations / memory_versions / memory_candidates
// 依据 DATABASE_DESIGN §2.8~§2.11。SQLite 是唯一事实来源，索引表为可重建派生数据（FR-MEM-06）。
import 'package:drift/drift.dart';

// 长期记忆（§2.8）：10 类 × 6 态生命周期
@TableIndex(name: 'idx_memories_status_type', columns: {#status, #type})
@TableIndex(name: 'idx_memories_pinned', columns: {#pinned})
@TableIndex(name: 'idx_memories_updated', columns: {#updatedAt})
@DataClassName('Memory')
class Memories extends Table {
  TextColumn get id => text()(); // mem_<时间紧凑>_<8hex>
  TextColumn get type => text()(); // profile/preference/experience_joint/event/...
  TextColumn get status => text().withDefault(const Constant('active')).check(
      const CustomExpression<bool>(
          "status IN ('pending', 'active', 'stale', 'superseded', 'conflict', 'archived')"))();
  TextColumn get title => text().nullable()(); // ≤300
  TextColumn get summary => text()();
  TextColumn get body => text().nullable()();
  TextColumn get confidence => text().withDefault(const Constant('medium')).check(
      const CustomExpression<bool>(
          "confidence IN ('low', 'medium', 'high')"))(); // low 不参与注入
  IntColumn get importance => integer().withDefault(const Constant(50))(); // 0-100
  IntColumn get pinned => integer().withDefault(const Constant(0))();
  TextColumn get aliases => text().nullable()(); // JSON
  TextColumn get tags => text().nullable()(); // JSON
  TextColumn get evidence => text().nullable()(); // 来源追踪说明
  TextColumn get sourceSessionId => text().nullable()();
  TextColumn get sourceMessageIds => text().nullable()(); // JSON
  TextColumn get supersedes => text().nullable()(); // JSON：被本条替代的旧记忆
  TextColumn get supersededBy => text().nullable()();
  TextColumn get conflictsWith => text().nullable()(); // JSON：冲突双方证据保留
  IntColumn get isResident => integer().withDefault(const Constant(0))(); // 常驻注入开关
  TextColumn get sensitivity => text().nullable()(); // JSON 敏感类别（默认不自动保存）
  IntColumn get recallCount => integer().withDefault(const Constant(0))();
  IntColumn get lastRecalledAt => integer().nullable()(); // 毫秒
  IntColumn get schemaVersion => integer().withDefault(const Constant(1))();
  TextColumn get createdAt => text()(); // 永不因编辑改变
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// 记忆关联（§2.9）：自主思考发现的关联来源（FR-ATH-02）
@TableIndex(name: 'idx_memory_relations_from', columns: {#fromMemoryId})
@TableIndex(name: 'idx_memory_relations_to', columns: {#toMemoryId})
@TableIndex(
    name: 'uq_memory_relations_triple',
    columns: {#fromMemoryId, #toMemoryId, #relationType},
    unique: true)
@DataClassName('MemoryRelation')
class MemoryRelations extends Table {
  TextColumn get id => text()();
  @ReferenceName('outgoingRelations')
  TextColumn get fromMemoryId => text().references(Memories, #id)();
  @ReferenceName('incomingRelations')
  TextColumn get toMemoryId => text().references(Memories, #id)();
  TextColumn get relationType => text().check(const CustomExpression<bool>(
      "relation_type IN ('related', 'supports', 'contradicts', 'caused_by')"))();
  IntColumn get strength => integer().withDefault(const Constant(50))(); // 0-100
  TextColumn get discoveredBy => text().withDefault(const Constant('rule')).check(
      const CustomExpression<bool>(
          "discovered_by IN ('rule', 'thinking', 'user')"))();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 记忆版本（§2.10）：撤销恢复 = 回放快照
@TableIndex(name: 'idx_memory_versions_mem', columns: {#memoryId, #versionNo})
@DataClassName('MemoryVersion')
class MemoryVersions extends Table {
  TextColumn get id => text()();
  TextColumn get memoryId => text().references(Memories, #id)();
  IntColumn get versionNo => integer()();
  TextColumn get beforeSnapshot => text().nullable()(); // JSON
  TextColumn get afterSnapshot => text().nullable()(); // JSON
  TextColumn get changeKind => text().check(const CustomExpression<bool>(
      "change_kind IN ('create', 'update', 'merge', 'status', 'supersede')"))();
  TextColumn get reason => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 记忆候选/收件箱（§2.11）：模型只提候选，写入由业务层控制（ADR-7）
@TableIndex(name: 'idx_memory_candidates_status', columns: {#status, #createdAt})
@DataClassName('MemoryCandidate')
class MemoryCandidates extends Table {
  TextColumn get id => text()();
  TextColumn get proposedTitle => text().nullable()();
  TextColumn get proposedSummary => text()();
  TextColumn get proposedType => text()();
  TextColumn get confidence => text().nullable()();
  IntColumn get importance => integer().nullable()();
  TextColumn get origin => text().withDefault(const Constant('rule')).check(
      const CustomExpression<bool>(
          "origin IN ('rule', 'llm', 'thinking', 'import')"))();
  TextColumn get groundingNote => text().nullable()(); // 佐证原文定位（grounded 要求）
  TextColumn get scanFlags => text().nullable()(); // JSON 机密/敏感扫描结果
  TextColumn get compareResult => text().nullable()(); // create/update/merge/conflict
  TextColumn get targetMemoryId => text().nullable().references(Memories, #id)();
  TextColumn get status => text().withDefault(const Constant('pending')).check(
      const CustomExpression<bool>(
          "status IN ('pending', 'confirmed', 'rejected', 'applied')"))();
  IntColumn get refusable => integer().withDefault(const Constant(1))();
  IntColumn get expiresAt => integer().nullable()(); // 毫秒，30 天过期

  @override
  Set<Column> get primaryKey => {id};
}
