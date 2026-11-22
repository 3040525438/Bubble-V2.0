// 会话聊天域：conversations / messages / attachments
// 依据 DATABASE_DESIGN §2.1~§2.3。时间戳约定：TEXT 为 UTC ISO-8601，INTEGER 为毫秒。
import 'package:drift/drift.dart';
import 'models.dart';

// 会话（§2.1）
@TableIndex(name: 'idx_conversations_list', columns: {#deletedAt, #lastMessageAt})
@DataClassName('Conversation')
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get sortWeight => integer().nullable()(); // 手动置顶排序
  IntColumn get lastMessageAt => integer().nullable()(); // 列表排序（毫秒）
  IntColumn get lastReadAt => integer().nullable()(); // 未读标记
  IntColumn get messageCount => integer().withDefault(const Constant(0))();
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()(); // NULL=未删

  @override
  Set<Column> get primaryKey => {id};
}

// 消息（§2.2）：状态机 sending|streaming|sent|failed|interrupted|deleted
@TableIndex(name: 'idx_messages_conversation_seq', columns: {#conversationId, #seq})
@TableIndex(name: 'idx_messages_status', columns: {#status})
@TableIndex(name: 'idx_messages_kind_created', columns: {#messageKind, #createdAt})
@TableIndex(name: 'idx_messages_request_id', columns: {#requestId})
@DataClassName('Message')
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text().references(Conversations, #id)();
  TextColumn get role => text().check(const CustomExpression<bool>(
      "role IN ('user', 'assistant', 'system')"))();
  IntColumn get seq => integer()(); // 会话内递增，事务内 max+1
  TextColumn get content => text()();
  TextColumn get status => text().check(const CustomExpression<bool>(
      "status IN ('sending', 'streaming', 'sent', 'failed', 'interrupted', 'deleted')"))();
  TextColumn get errorCode => text().nullable()();
  TextColumn get errorDetail => text().nullable()();
  TextColumn get messageKind => text().withDefault(const Constant('normal')).check(
      const CustomExpression<bool>(
          "message_kind IN ('normal', 'continuation', 'proactive', 'system_note')"))();
  TextColumn get proactiveMeta => text().nullable()(); // JSON：来源/关联记忆/决策动作
  TextColumn get requestId => text().nullable()(); // 幂等键
  TextColumn get modelId => text().nullable().references(Models, #id)();
  IntColumn get tokenPrompt => integer().nullable()();
  IntColumn get tokenCompletion => integer().nullable()();
  IntColumn get tokenReasoning => integer().nullable()(); // DeepSeek reasoning_tokens
  RealColumn get costEst => real().nullable()();
  TextColumn get reasoningContent => text().nullable()(); // 思考链（可选）
  TextColumn get createdAt => text()();
  TextColumn get updatedAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// 附件（§2.3）：先写文件后写 DB（崩溃只产生 orphan，可清理）
@TableIndex(name: 'idx_attachments_owner', columns: {#ownerKind, #ownerId})
@TableIndex(name: 'idx_attachments_sha', columns: {#sha256})
@DataClassName('Attachment')
class Attachments extends Table {
  TextColumn get id => text()();
  TextColumn get messageId => text().nullable().references(Messages, #id)();
  TextColumn get ownerKind => text().check(const CustomExpression<bool>(
      "owner_kind IN ('message', 'post', 'diary', 'letter', 'import')"))();
  TextColumn get ownerId => text()(); // 冗余便于检索
  TextColumn get relPath => text()(); // 沙盒相对路径 Attachments/<yyyy>/<mm>/<uuid>.<ext>
  TextColumn get mime => text().nullable()();
  IntColumn get sizeBytes => integer().nullable()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  TextColumn get ocrText => text().nullable()(); // 参与 content_index_terms
  TextColumn get aiCaption => text().nullable()();
  TextColumn get sha256 => text().nullable()(); // 完整性校验/去重
  TextColumn get createdAt => text()();
  TextColumn get deletedAt => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
