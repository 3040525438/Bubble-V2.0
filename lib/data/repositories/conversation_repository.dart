// 会话与消息仓储（T2.1）：seq 分配、会话冗余计数维护、软删与范围删除、
// 悬挂状态恢复、会话内 bigram 检索。
// 依据 DATABASE_DESIGN §2.1~§2.2 与 TEST_PLAN §3 聊天域用例。
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/chat/chat_provider.dart';
import '../../domain/chat/chat_usage.dart';
import '../../domain/chat/message_status.dart';
import '../../domain/search/tokenizer.dart';
import '../database/app_database.dart';

/// 会话列表项（含最后一条消息摘要与未读数）
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.title,
    required this.lastContent,
    required this.lastRole,
    required this.lastMessageAt,
    required this.messageCount,
    required this.unreadCount,
    this.sortWeight,
  });

  final String id;
  final String title;
  final String? lastContent;
  final String? lastRole;
  final int? lastMessageAt;
  final int messageCount;
  final int unreadCount;
  final int? sortWeight;
}

/// 默认会话名（新建后由首条用户消息自动改名为摘要）
const kDefaultConversationTitle = '新的对话';

class ConversationRepository {
  ConversationRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();
  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  // ---------------------------------------------------------------- 会话

  /// 新建会话（title 为空时用默认名）。
  Future<Conversation> createConversation({String? title}) async {
    final now = _nowIso();
    final id = _uuid.v4();
    await _db.into(_db.conversations).insert(ConversationsCompanion.insert(
          id: id,
          title: (title == null || title.trim().isEmpty)
              ? kDefaultConversationTitle
              : title.trim(),
          createdAt: now,
          updatedAt: now,
        ));
    return (await getConversation(id))!;
  }

  Future<Conversation?> getConversation(String id) {
    return (_db.select(_db.conversations)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 会话列表（按置顶权重 → 最后消息时间倒序）。
  Stream<List<ConversationSummary>> watchConversations() {
    return _conversationListQuery().watch().map(_mapSummaries);
  }

  Future<List<ConversationSummary>> listConversations() async {
    final rows = await _conversationListQuery().get();
    return _mapSummaries(rows);
  }

  /// 左连接最后一条消息 + 子查询未读数（assistant 且晚于 last_read_at）。
  Selectable<QueryRow> _conversationListQuery() {
    return _db.customSelect(
      '''
SELECT c.id, c.title, c.sort_weight, c.last_message_at, c.message_count,
       m.content AS last_content, m.role AS last_role,
       (SELECT COUNT(*) FROM messages u
          WHERE u.conversation_id = c.id AND u.deleted_at IS NULL
            AND u.role = 'assistant'
            AND (CAST(strftime('%s', u.created_at) AS INTEGER) * 1000
                 + CAST(COALESCE(substr(u.created_at, 21, 3), '0') AS INTEGER))
                > COALESCE(c.last_read_at, 0)) AS unread_count
FROM conversations c
LEFT JOIN messages m ON m.id = (
  SELECT id FROM messages
  WHERE conversation_id = c.id AND deleted_at IS NULL
  ORDER BY seq DESC LIMIT 1
)
WHERE c.deleted_at IS NULL
ORDER BY (CASE WHEN c.sort_weight IS NULL THEN 1 ELSE 0 END),
         c.sort_weight DESC, c.last_message_at DESC, c.created_at DESC
''',
      readsFrom: {_db.conversations, _db.messages},
    );
  }

  List<ConversationSummary> _mapSummaries(List<QueryRow> rows) {
    return rows.map((row) {
      return ConversationSummary(
        id: row.read<String>('id'),
        title: row.read<String>('title'),
        lastContent: row.read<String?>('last_content'),
        lastRole: row.read<String?>('last_role'),
        lastMessageAt: row.read<int?>('last_message_at'),
        messageCount: row.read<int>('message_count'),
        unreadCount: row.read<int>('unread_count'),
        sortWeight: row.read<int?>('sort_weight'),
      );
    }).toList();
  }

  Future<void> renameConversation(String id, String title) async {
    await (_db.update(_db.conversations)..where((t) => t.id.equals(id))).write(
      ConversationsCompanion(
        title: Value(title.trim().isEmpty ? kDefaultConversationTitle : title.trim()),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 标记已读（清除未读计数依据）。
  Future<void> markConversationRead(String id) async {
    await (_db.update(_db.conversations)..where((t) => t.id.equals(id))).write(
      ConversationsCompanion(lastReadAt: Value(_nowMs())),
    );
  }

  /// 首条用户消息自动命名会话（仅在仍为默认名时生效）。
  Future<void> ensureTitleFromMessage(String conversationId, String text) async {
    final conv = await getConversation(conversationId);
    if (conv == null) return;
    if (conv.title != kDefaultConversationTitle) return;
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return;
    final runes = cleaned.runes.toList();
    final title =
        runes.length > 20 ? '${String.fromCharCodes(runes.take(20))}…' : cleaned;
    await renameConversation(conversationId, title);
  }

  /// 删除会话（软删）。[deleteMessages] 为真时连带软删其全部消息（范围确认由 UI 负责）。
  Future<void> softDeleteConversation(
    String id, {
    required bool deleteMessages,
  }) async {
    await _db.transaction(() async {
      final now = _nowIso();
      if (deleteMessages) {
        await _db.customUpdate(
          'UPDATE messages SET deleted_at = ?, status = ?, updated_at = ? '
          'WHERE conversation_id = ? AND deleted_at IS NULL',
          variables: [
            Variable(now),
            Variable(MessageStatuses.deleted),
            Variable(now),
            Variable(id),
          ],
          updates: {_db.messages},
        );
      }
      await _db.customUpdate(
        'UPDATE conversations SET deleted_at = ?, updated_at = ?'
        '${deleteMessages ? ', message_count = 0, last_message_at = NULL' : ''} '
        'WHERE id = ?',
        variables: [Variable(now), Variable(now), Variable(id)],
        updates: {_db.conversations},
      );
    });
  }

  // ---------------------------------------------------------------- 消息

  /// 会话消息（未软删，按 seq 升序）。
  Future<List<Message>> messages(String conversationId, {int? limit}) {
    final q = _db.select(_db.messages)
      ..where((t) => t.conversationId.equals(conversationId) & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.asc(t.seq)]);
    if (limit != null) q.limit(limit);
    return q.get();
  }

  /// 监听会话消息（聊天页实时渲染的数据源）。
  Stream<List<Message>> watchMessages(String conversationId) {
    return (_db.select(_db.messages)
          ..where(
              (t) => t.conversationId.equals(conversationId) & t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
        .watch();
  }

  Future<Message?> getMessage(String id) {
    return (_db.select(_db.messages)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  /// 追加用户消息（本地落库即已发送；真实网络发送态在阶段 3 接入）。
  /// 首条消息会自动以内容摘要命名会话。
  Future<Message> appendUserMessage(
    String conversationId,
    String content,
  ) async {
    final id = await _insertMessage(
      conversationId: conversationId,
      role: 'user',
      content: content,
      status: MessageStatuses.sent,
    );
    await ensureTitleFromMessage(conversationId, content);
    return (await getMessage(id))!;
  }

  /// 创建助手占位消息（status=sending，随后进入 streaming）。
  Future<Message> beginAssistantMessage(
    String conversationId, {
    String messageKind = MessageKinds.normal,
  }) async {
    final id = await _insertMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: '',
      status: MessageStatuses.sending,
      messageKind: messageKind,
      requestId: _uuid.v4(),
    );
    return (await getMessage(id))!;
  }

  /// 追加一条「连续多气泡」的后续段（独立落库）。
  Future<Message> appendAssistantSegment(
    String conversationId,
    String content,
  ) async {
    final id = await _insertMessage(
      conversationId: conversationId,
      role: 'assistant',
      content: content,
      status: MessageStatuses.sent,
      messageKind: MessageKinds.continuation,
    );
    return (await getMessage(id))!;
  }

  Future<String> _insertMessage({
    required String conversationId,
    required String role,
    required String content,
    required String status,
    String messageKind = MessageKinds.normal,
    String? requestId,
  }) async {
    return _db.transaction(() async {
      final now = _nowIso();
      final seq = await _nextSeq(conversationId);
      final id = _uuid.v4();
      await _db.into(_db.messages).insert(MessagesCompanion.insert(
            id: id,
            conversationId: conversationId,
            role: role,
            seq: seq,
            content: content,
            status: status,
            messageKind: Value(messageKind),
            requestId: Value(requestId),
            createdAt: now,
            updatedAt: now,
          ));
      await _touchConversation(conversationId, now);
      return id;
    });
  }

  /// 会话内下一个序号（事务内 MAX+1，含软删消息以避免复用）。
  Future<int> _nextSeq(String conversationId) async {
    final row = await _db.customSelect(
      'SELECT COALESCE(MAX(seq), 0) + 1 AS next FROM messages WHERE conversation_id = ?',
      variables: [Variable(conversationId)],
      readsFrom: {_db.messages},
    ).getSingle();
    return row.read<int>('next');
  }

  Future<void> _touchConversation(String conversationId, String nowIso) async {
    await _db.customUpdate(
      'UPDATE conversations SET message_count = message_count + 1, '
      'last_message_at = ?, updated_at = ? WHERE id = ?',
      variables: [Variable(_nowMs()), Variable(nowIso), Variable(conversationId)],
      updates: {_db.conversations},
    );
  }

  /// 流式增量写库（status 可选迁移；非法迁移忽略状态只更新内容）。
  Future<void> updateMessageContent(
    String messageId,
    String content, {
    String? status,
  }) async {
    final current = await getMessage(messageId);
    if (current == null) return;
    final nextStatus = status == null
        ? current.status
        : (canTransitionMessageStatus(current.status, status)
            ? status
            : current.status);
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId))).write(
      MessagesCompanion(
        content: Value(content),
        status: Value(nextStatus),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 落库一次生成的 Token 用量与思考链（T3.2，FR-MDL-03）。
  Future<void> applyMessageUsage(
    String messageId, {
    required ChatUsage usage,
    String? modelId,
    String? reasoning,
  }) async {
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId))).write(
      MessagesCompanion(
        tokenPrompt: Value(usage.promptTokens),
        tokenCompletion: Value(usage.completionTokens),
        tokenReasoning: Value(usage.reasoningTokens),
        costEst: Value(usage.costEst),
        modelId: Value(modelId),
        reasoningContent: Value(reasoning),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 生成完成：写入最终内容并置 sent。
  Future<void> finishMessage(String messageId, {required String content}) {
    return (_db.update(_db.messages)..where((t) => t.id.equals(messageId))).write(
      MessagesCompanion(
        content: Value(content),
        status: const Value(MessageStatuses.sent),
        errorCode: const Value(null),
        errorDetail: const Value(null),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 生成失败：落库错误分类（阶段 3 扩展网络矩阵）。
  Future<void> failMessage(
    String messageId, {
    required String errorCode,
    String? errorDetail,
    String? content,
  }) async {
    final current = await getMessage(messageId);
    if (current == null) return;
    final status = canTransitionMessageStatus(current.status, MessageStatuses.failed)
        ? MessageStatuses.failed
        : current.status;
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId))).write(
      MessagesCompanion(
        status: Value(status),
        errorCode: Value(errorCode),
        errorDetail: Value(errorDetail),
        content: content == null ? const Value.absent() : Value(content),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 用户停止：保留半成品并置 interrupted。
  Future<void> interruptMessage(String messageId, {required String content}) {
    return (_db.update(_db.messages)..where((t) => t.id.equals(messageId))).write(
      MessagesCompanion(
        content: Value(content),
        status: const Value(MessageStatuses.interrupted),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 重试前重置：复用同一消息与 request_id（幂等，不重复落库）。
  Future<void> resetForRetry(String messageId) async {
    final current = await getMessage(messageId);
    if (current == null) return;
    await (_db.update(_db.messages)..where((t) => t.id.equals(messageId))).write(
      MessagesCompanion(
        content: const Value(''),
        status: const Value(MessageStatuses.sending),
        errorCode: const Value(null),
        errorDetail: const Value(null),
        updatedAt: Value(_nowIso()),
      ),
    );
  }

  /// 软删单条消息并重算会话计数。
  Future<void> softDeleteMessage(String messageId) async {
    final msg = await getMessage(messageId);
    if (msg == null) return;
    await _db.transaction(() async {
      final now = _nowIso();
      await (_db.update(_db.messages)..where((t) => t.id.equals(messageId))).write(
        MessagesCompanion(
          status: const Value(MessageStatuses.deleted),
          deletedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      await _recountConversation(msg.conversationId);
    });
  }

  /// 物理删除（仅用于清理无内容的占位气泡）。
  Future<void> hardDeleteMessage(String messageId) async {
    final msg = await getMessage(messageId);
    if (msg == null) return;
    await _db.transaction(() async {
      await (_db.delete(_db.messages)..where((t) => t.id.equals(messageId))).go();
      await _recountConversation(msg.conversationId);
    });
  }

  /// 重算会话冗余计数与最后消息时间。
  Future<void> _recountConversation(String conversationId) async {
    await _db.customUpdate(
      'UPDATE conversations SET '
      'message_count = (SELECT COUNT(*) FROM messages '
      '  WHERE conversation_id = ? AND deleted_at IS NULL), '
      'last_message_at = (SELECT CAST(strftime(\'%s\', created_at) AS INTEGER) * 1000 '
      '  FROM messages WHERE conversation_id = ? AND deleted_at IS NULL '
      '  ORDER BY seq DESC LIMIT 1), '
      'updated_at = ? WHERE id = ?',
      variables: [
        Variable(conversationId),
        Variable(conversationId),
        Variable(_nowIso()),
        Variable(conversationId),
      ],
      updates: {_db.conversations, _db.messages},
    );
  }

  /// 中断恢复：把悬挂的 sending/streaming 消息收敛为终态（不悬挂）。
  /// - 有内容 → interrupted（可继续）
  /// - 无内容 → failed（errorCode=interrupted，可重试）
  Future<int> recoverUnfinishedMessages({String? conversationId}) async {
    final q = _db.select(_db.messages)
      ..where((t) => t.status.isIn(
          [MessageStatuses.sending, MessageStatuses.streaming]) &
          t.deletedAt.isNull());
    if (conversationId != null) {
      q.where((t) => t.conversationId.equals(conversationId));
    }
    final hanging = await q.get();
    if (hanging.isEmpty) return 0;
    await _db.transaction(() async {
      for (final m in hanging) {
        final hasContent = m.content.trim().isNotEmpty;
        await (_db.update(_db.messages)..where((t) => t.id.equals(m.id))).write(
          MessagesCompanion(
            status: Value(hasContent
                ? MessageStatuses.interrupted
                : MessageStatuses.failed),
            errorCode: hasContent ? const Value(null) : const Value('interrupted'),
            updatedAt: Value(_nowIso()),
          ),
        );
      }
    });
    return hanging.length;
  }

  /// 失败消息（即「未发送队列」数据源，按 seq 升序）。
  Future<List<Message>> failedMessages(String conversationId, {int? limit}) {
    final q = _db.select(_db.messages)
      ..where((t) =>
          t.conversationId.equals(conversationId) &
          t.status.equals(MessageStatuses.failed) &
          t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.asc(t.seq)]);
    if (limit != null) q.limit(limit);
    return q.get();
  }

  /// 最近对话历史（供模型上下文；只取 user/assistant 且已落定内容）。
  Future<List<ChatTurn>> history(
    String conversationId, {
    int maxTurns = 40,
  }) async {
    final all = await messages(conversationId);
    final usable = all
        .where((m) =>
            (m.role == 'user' || m.role == 'assistant') &&
            m.status != MessageStatuses.failed &&
            m.status != MessageStatuses.deleted &&
            m.content.trim().isNotEmpty)
        .toList();
    final tail = usable.length > maxTurns
        ? usable.sublist(usable.length - maxTurns)
        : usable;
    return [for (final m in tail) ChatTurn(role: m.role, content: m.content)];
  }

  /// 会话内搜索（T2.6）：子串命中或 bigram 全命中（AND 语义），按 seq 升序。
  Future<List<Message>> searchMessages(
    String conversationId,
    String query, {
    int limit = 50,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final queryTokens = similarityTokens(q);
    final lowerQuery = q.toLowerCase();
    final all = await messages(conversationId);
    final hits = <Message>[];
    for (final m in all) {
      final lower = m.content.toLowerCase();
      var matched = lower.contains(lowerQuery);
      if (!matched && queryTokens.isNotEmpty) {
        final tokens = tokenize(m.content).toSet();
        matched = queryTokens.every(tokens.contains);
      }
      if (matched) {
        hits.add(m);
        if (hits.length >= limit) break;
      }
    }
    return hits;
  }
}
