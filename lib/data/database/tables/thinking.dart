// 思考与主动行为域：thinking_tasks / thinking_results / proactive_candidates /
// proactive_actions / scheduled_messages
// 依据 DATABASE_DESIGN §2.12~§2.16。
import 'package:drift/drift.dart';

// 思考任务（§2.12）：八步状态机，interrupted 是恢复入口
@TableIndex(name: 'idx_thinking_state', columns: {#state})
@TableIndex(name: 'idx_thinking_trigger_started', columns: {#trigger, #startedAt})
@DataClassName('ThinkingTask')
class ThinkingTasks extends Table {
  TextColumn get id => text()();
  TextColumn get trigger => text().withDefault(const Constant('manual')).check(
      const CustomExpression<bool>(
          "trigger IN ('foreground_timer', 'background_bgtask', 'app_resume', 'manual')"))();
  TextColumn get bgTaskId => text().nullable()(); // BGTaskScheduler 任务标识
  TextColumn get state => text().withDefault(const Constant('created')).check(
      const CustomExpression<bool>(
          "state IN ('created', 'loading', 'reviewing', 'analyzing', 'saving', 'deciding', 'done', 'failed', 'interrupted')"))();
  TextColumn get checkpoint => text().nullable()(); // JSON：当前步骤+游标
  IntColumn get reviewedUntil => integer().nullable()(); // 回顾推进位置（毫秒）
  TextColumn get scopeNote => text().nullable()();
  IntColumn get startedAt => integer().nullable()();
  IntColumn get finishedAt => integer().nullable()();
  IntColumn get interruptedAt => integer().nullable()();
  IntColumn get resultCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

// 思考产出（§2.13）：永久保留（"想法史"）
@TableIndex(name: 'idx_thinking_results_task', columns: {#taskId})
@TableIndex(name: 'idx_thinking_results_kind', columns: {#resultKind})
@DataClassName('ThinkingResult')
class ThinkingResults extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text().references(ThinkingTasks, #id)();
  TextColumn get resultKind => text()(); // new_connection/reunderstanding/...
  TextColumn get content => text()();
  TextColumn get relatedMemoryIds => text().nullable()(); // JSON
  TextColumn get relatedMessageIds => text().nullable()(); // JSON
  TextColumn get confidence => text().nullable()();
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 主动行为候选池（§2.14）：dedup_key 唯一防重复
@TableIndex(name: 'idx_proactive_candidates_status', columns: {#status, #priority})
@TableIndex(name: 'idx_proactive_candidates_dedup', columns: {#dedupKey})
@TableIndex(name: 'idx_proactive_candidates_expires', columns: {#expiresAt})
@DataClassName('ProactiveCandidate')
class ProactiveCandidates extends Table {
  TextColumn get id => text()();
  TextColumn get actionKind => text().withDefault(const Constant('chat')).check(
      const CustomExpression<bool>(
          "action_kind IN ('chat', 'post', 'diary', 'letter', 'review_experience', 'memory_housekeeping', 'quiet')"))();
  TextColumn get title => text().nullable()();
  TextColumn get contentDraft => text().nullable()();
  TextColumn get sourceKind => text().nullable()(); // 11 类来源（FR-PRO-02）
  TextColumn get relatedMemoryIds => text().nullable()(); // JSON
  TextColumn get relatedExperienceId => text().nullable()();
  TextColumn get relatedTaskId => text().nullable()();
  IntColumn get priority => integer().withDefault(const Constant(50))(); // 0-100
  TextColumn get status => text().withDefault(const Constant('pending')).check(
      const CustomExpression<bool>(
          "status IN ('pending', 'queued', 'executing', 'executed', 'cancelled', 'expired', 'rejected')"))();
  TextColumn get dedupKey => text().nullable()(); // UNIQUE 风格哈希
  IntColumn get cooldownUntil => integer().nullable()();
  IntColumn get expiresAt => integer().nullable()();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 执行记录（§2.15）
@TableIndex(name: 'idx_proactive_actions_executed', columns: {#executedAt})
@DataClassName('ProactiveAction')
class ProactiveActions extends Table {
  TextColumn get id => text()();
  TextColumn get candidateId => text().references(ProactiveCandidates, #id)();
  TextColumn get actionKind => text()();
  IntColumn get executedAt => integer()(); // 毫秒
  TextColumn get deliverableType => text().nullable()(); // message/post/diary/letter
  TextColumn get deliverableId => text().nullable()();
  TextColumn get decisionNote => text().nullable()(); // 为何执行/为何放弃
  TextColumn get userFeedbackId => text().nullable()(); // FK→feedback_records
  TextColumn get createdAt => text()();

  @override
  Set<Column> get primaryKey => {id};
}

// 主动消息队列（§2.16）：5 态；队列上限 20（FR-IOS-06）
@TableIndex(name: 'idx_scheduled_status_at', columns: {#status, #scheduledAt})
@TableIndex(name: 'idx_scheduled_expires', columns: {#expiresAt})
@TableIndex(name: 'idx_scheduled_tz', columns: {#scheduledTimezone})
@DataClassName('ScheduledMessage')
class ScheduledMessages extends Table {
  TextColumn get id => text()();
  TextColumn get content => text()();
  IntColumn get scheduledAt => integer()(); // 计划投递时间（毫秒，UTC+渲染时区）
  TextColumn get status => text().withDefault(const Constant('pending')).check(
      const CustomExpression<bool>(
          "status IN ('pending', 'scheduled', 'delivered', 'cancelled', 'expired')"))();
  TextColumn get conversationId => text().nullable()(); // FK→conversations
  TextColumn get messageId => text().nullable()(); // delivered 时回填
  TextColumn get candidateId => text().nullable()(); // 溯源
  TextColumn get reason => text().nullable()();
  TextColumn get notificationId => text().nullable()(); // iOS 通知标识（取消用）
  TextColumn get scheduledTimezone => text().nullable()(); // 时区重排判定依据
  TextColumn get createdAt => text()();
  IntColumn get expiresAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
