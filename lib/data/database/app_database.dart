// Drift 数据库聚合（T1.1）：32 张表，schemaVersion 1。
// 依据 DATABASE_DESIGN §1 表总览 + §3.1 数据库级约定。
import 'package:drift/drift.dart';

import 'tables/conversations.dart';
import 'tables/persona.dart';
import 'tables/memories.dart';
import 'tables/thinking.dart';
import 'tables/experience_content.dart';
import 'tables/models.dart';
import 'tables/system.dart';
import 'tables/index_tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    // 会话聊天
    Conversations,
    Messages,
    Attachments,
    // 人格
    PersonaProfiles,
    PersonaVersions,
    PersonaGrowthRecords,
    ExpressionSamples,
    // 记忆
    Memories,
    MemoryRelations,
    MemoryVersions,
    MemoryCandidates,
    // 思考与主动
    ThinkingTasks,
    ThinkingResults,
    ProactiveCandidates,
    ProactiveActions,
    ScheduledMessages,
    // 经历与内容
    SharedExperiences,
    Posts,
    Diaries,
    Letters,
    FeedbackRecords,
    // 模型
    Models,
    ModelUsages,
    // 系统
    NotificationSettings,
    AppSettings,
    BackgroundTaskLogs,
    MigrationRecords,
    BackupRecords,
    JournalLogs,
    // 派生索引（可重建）
    MemoryIndexTerms,
    MemoryIndexDocs,
    ContentIndexTerms,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        beforeOpen: (details) async {
          // 每个连接必须开启外键（DATABASE_DESIGN §3.1）
          await customStatement('PRAGMA foreign_keys = ON');
          await customStatement('PRAGMA synchronous = NORMAL');
          await customStatement('PRAGMA busy_timeout = 5000');
        },
      );

  /// 打库完整性快检（§5：轻量 quick_check），失败返回 false 由上层告警。
  Future<bool> quickCheck() async {
    final row = await customSelect('PRAGMA quick_check').getSingle();
    return (row.data.values.first as String) == 'ok';
  }
}
