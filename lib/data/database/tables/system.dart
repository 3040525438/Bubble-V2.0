// 系统域：notification_settings / app_settings / background_task_logs /
// migration_records / backup_records / journal_logs
// 依据 DATABASE_DESIGN §2.25~§2.29。
import 'package:drift/drift.dart';

// 通知设置（§2.25）：固定单行；D-3 默认 minimal
@DataClassName('NotificationSetting')
class NotificationSettings extends Table {
  TextColumn get id => text()();
  TextColumn get privacyMode => text().withDefault(const Constant('minimal')).check(
      const CustomExpression<bool>(
          "privacy_mode IN ('full', 'minimal', 'hidden')"))();
  IntColumn get allowPostNotify => integer().withDefault(const Constant(1))();
  IntColumn get allowDiaryLetterNotify => integer().withDefault(const Constant(1))();
  IntColumn get dailyNotifyCap => integer().withDefault(const Constant(10))();
  TextColumn get quietStart => text().nullable()(); // HH:mm
  TextColumn get quietEnd => text().nullable()(); // 跨午夜允许
  TextColumn get quietTimezone => text().nullable()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 应用 KV 配置（§2.26）：键空间以 AppSettingKeys 常量类冻结（见 application 层）
@DataClassName('AppSetting')
class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()(); // JSON
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {key};
}

// 后台任务日志（§2.24）：保留 90 天滚动清理
@DataClassName('BackgroundTaskLog')
class BackgroundTaskLogs extends Table {
  TextColumn get id => text()();
  TextColumn get taskType => text().nullable()(); // apprefresh/processing
  TextColumn get event => text().nullable()(); // submit/start/finish/fail/expired
  TextColumn get payload => text().nullable()(); // JSON
  IntColumn get startedAt => integer().nullable()();
  IntColumn get finishedAt => integer().nullable()();
  IntColumn get nextSubmitAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// 迁移索引（§2.27）：对账源/目标计数（FR-MIG-01）
@TableIndex(name: 'idx_migration_source_ref', columns: {#sourceRef})
@TableIndex(name: 'idx_migration_category_status', columns: {#category, #status})
@DataClassName('MigrationRecord')
class MigrationRecords extends Table {
  TextColumn get id => text()();
  TextColumn get source => text().withDefault(const Constant('astrbot'))();
  TextColumn get sourceRef => text().nullable()();
  TextColumn get targetTable => text().nullable()();
  TextColumn get targetId => text().nullable()();
  TextColumn get category => text().nullable()(); // chat/persona/relation/...
  TextColumn get status => text().withDefault(const Constant('migrated')).check(
      const CustomExpression<bool>(
          "status IN ('migrated', 'skipped', 'failed', 'verified')"))();
  TextColumn get notes => text().nullable()();
  TextColumn get migratedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 备份记录（§2.28）：恢复前校验 sha256 + 对账 table_counts
@DataClassName('BackupRecord')
class BackupRecords extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text().withDefault(const Constant('manual'))(); // manual/auto/pre_migration
  TextColumn get path => text()();
  IntColumn get sizeBytes => integer().nullable()();
  TextColumn get sha256 => text().nullable()();
  TextColumn get tableCounts => text().nullable()(); // JSON 对账快照
  IntColumn get dbSchemaVersion => integer().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get verifiedAt => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('ok')).check(
      const CustomExpression<bool>("status IN ('ok', 'corrupt')"))();

  @override
  Set<Column> get primaryKey => {id};
}

// 变更日志（§2.29）：追加式；有界摘要 ≤160 字；坏行跳过
// id 为 autoIncrement，drift 自动作主键，不显式 override primaryKey
@TableIndex(name: 'idx_journal_entity', columns: {#entityTable, #entityId})
@TableIndex(name: 'idx_journal_at', columns: {#at})
@DataClassName('JournalLog')
class JournalLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get op => text()(); // create/update/delete/archive/supersede/...
  TextColumn get entityTable => text()();
  TextColumn get entityId => text()();
  TextColumn get beforeDigest => text().nullable()(); // ≤160 字
  TextColumn get afterDigest => text().nullable()();
  TextColumn get reason => text().nullable()();
  TextColumn get source => text().nullable()(); // user/rule/llm/thinking/migration
  TextColumn get at => text()();
}
