// 经历与内容域：shared_experiences / posts / diaries / letters / feedback_records
// 依据 DATABASE_DESIGN §2.17~§2.21。
import 'package:drift/drift.dart';

// 共同经历（§2.17）：历史事实字段不可被 AI 修改，review_log 只追加（FR-EXP-03）
@TableIndex(name: 'idx_experiences_occurred', columns: {#occurredAt})
@DataClassName('SharedExperience')
class SharedExperiences extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get occurredAt => integer()(); // 发生时间（毫秒）
  TextColumn get eventContent => text()(); // 历史事实
  TextColumn get relatedConversationIds => text().nullable()(); // JSON
  TextColumn get relatedMemoryIds => text().nullable()(); // JSON
  IntColumn get importance => integer().withDefault(const Constant(50))();
  TextColumn get userPerspective => text().nullable()();
  TextColumn get bubblePerspective => text().nullable()();
  TextColumn get reviewLog => text().nullable()(); // JSON 数组（回顾时间+内容），只追加
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// 说说（§2.18）
@TableIndex(name: 'idx_posts_published', columns: {#publishedAt})
@DataClassName('Post')
class Posts extends Table {
  TextColumn get id => text()();
  TextColumn get content => text()();
  TextColumn get mood => text().nullable()();
  TextColumn get topic => text().nullable()();
  TextColumn get imageIds => text().nullable()(); // JSON
  TextColumn get origin => text().withDefault(const Constant('autonomous')).check(
      const CustomExpression<bool>(
          "origin IN ('autonomous', 'user_topic')"))();
  TextColumn get relatedMemoryIds => text().nullable()(); // JSON
  TextColumn get relatedConversationId => text().nullable()();
  IntColumn get publishedAt => integer()(); // 毫秒
  IntColumn get editedAt => integer().nullable()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// 日记（§2.19）：版本保留（FR-DIA-01），可导出 Markdown
@TableIndex(name: 'idx_diaries_entry_date', columns: {#entryDate})
@DataClassName('Diary')
class Diaries extends Table {
  TextColumn get id => text()();
  TextColumn get entryDate => text()(); // 日期归档 yyyy-MM-dd
  TextColumn get content => text()();
  TextColumn get origin => text().withDefault(const Constant('ai_organized')).check(
      const CustomExpression<bool>(
          "origin IN ('ai_organized', 'manual')"))();
  TextColumn get relatedMessageIds => text().nullable()(); // JSON
  TextColumn get relatedMemoryIds => text().nullable()(); // JSON
  TextColumn get versions => text().nullable()(); // JSON 版本保留
  TextColumn get deletedAt => text().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 信件（§2.20）
@TableIndex(name: 'idx_letters_direction_state', columns: {#direction, #state, #sentAt})
@DataClassName('Letter')
class Letters extends Table {
  TextColumn get id => text()();
  TextColumn get direction => text().check(const CustomExpression<bool>(
      "direction IN ('bubble_to_user', 'user_to_bubble')"))();
  TextColumn get state => text().withDefault(const Constant('draft')).check(
      const CustomExpression<bool>("state IN ('draft', 'sent')"))();
  TextColumn get title => text().nullable()();
  TextColumn get content => text()();
  TextColumn get relatedMemoryIds => text().nullable()(); // JSON
  TextColumn get relatedExperienceIds => text().nullable()(); // JSON
  IntColumn get sentAt => integer().nullable()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// 反馈记录（§2.21）：单次反馈不直改核心人格（FR-FBK-02）
@TableIndex(name: 'idx_feedback_target', columns: {#targetKind, #targetId})
@DataClassName('FeedbackRecord')
class FeedbackRecords extends Table {
  TextColumn get id => text()();
  TextColumn get targetKind => text()(); // expression_style/proactive_frequency/...
  TextColumn get targetId => text()();
  TextColumn get verdict => text().check(const CustomExpression<bool>(
      "verdict IN ('like', 'dislike', 'adjust', 'correct')"))();
  TextColumn get note => text().nullable()();
  TextColumn get actionTaken => text().nullable()(); // JSON：实际调整动作（仅成长层）
  TextColumn get revertedAt => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}
