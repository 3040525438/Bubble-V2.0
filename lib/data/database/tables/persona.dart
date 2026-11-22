// 人格域：persona_profiles / persona_versions / persona_growth_records / expression_samples
// 依据 DATABASE_DESIGN §2.4~§2.7。核心人格不允许删除，只走版本流转（FR-PER-02）。
import 'package:drift/drift.dart';

// 人格主档案（§2.4）：固定单行
@DataClassName('PersonaProfile')
class PersonaProfiles extends Table {
  TextColumn get id => text()();
  TextColumn get name => text().nullable()();
  TextColumn get avatarPath => text().nullable()();
  TextColumn get intro => text().nullable()();
  TextColumn get coreSystemPrompt => text().nullable()(); // 生效版本快照
  TextColumn get activeVersionId => text().nullable()(); // FK→persona_versions
  TextColumn get interests => text().nullable()(); // JSON 兴趣标签
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 人格版本（§2.5）：历史版本永久保留，可恢复
@TableIndex(name: 'idx_persona_versions_active', columns: {#isActive})
@TableIndex(name: 'idx_persona_versions_no', columns: {#versionNo})
@DataClassName('PersonaVersion')
class PersonaVersions extends Table {
  TextColumn get id => text()();
  IntColumn get versionNo => integer()();
  TextColumn get layer => text().check(
      const CustomExpression<bool>("layer IN ('core', 'growth', 'samples')"))();
  TextColumn get content => text()(); // JSON：该版本完整内容
  TextColumn get changeReason => text().nullable()();
  TextColumn get confirmedBy => text().withDefault(const Constant('init')).check(
      const CustomExpression<bool>(
          "confirmed_by IN ('user', 'migration', 'init')"))(); // 核心层必须 user
  IntColumn get isActive => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 成长记录（§2.6）：不物理删除，reverted 留撤销痕迹
@TableIndex(name: 'idx_growth_status', columns: {#status})
@TableIndex(name: 'idx_growth_version', columns: {#versionId})
@DataClassName('PersonaGrowthRecord')
class PersonaGrowthRecords extends Table {
  TextColumn get id => text()();
  TextColumn get versionId => text().references(PersonaVersions, #id)();
  TextColumn get growthType => text()(); // 称呼/兴趣/口头禅/表达习惯/观点变化
  TextColumn get beforeValue => text().nullable()();
  TextColumn get afterValue => text().nullable()();
  TextColumn get reason => text().nullable()();
  TextColumn get relatedMemoryIds => text().nullable()(); // JSON
  TextColumn get relatedExperienceId => text().nullable()(); // FK→shared_experiences
  TextColumn get status => text().withDefault(const Constant('proposed')).check(
      const CustomExpression<bool>(
          "status IN ('proposed', 'confirmed', 'reverted')"))();
  TextColumn get confirmedAt => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 表达样本（§2.7）：软删；参与 content_index_terms
@TableIndex(name: 'idx_expression_pinned', columns: {#pinned})
@DataClassName('ExpressionSample')
class ExpressionSamples extends Table {
  TextColumn get id => text()();
  TextColumn get content => text()();
  TextColumn get contextNote => text().nullable()(); // 代表性表达出处说明
  TextColumn get styleTags => text().nullable()(); // JSON
  TextColumn get relatedMessageId => text().nullable()(); // FK→messages
  IntColumn get pinned => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
