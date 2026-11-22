// 附件仓储（T12.1/T12.4）：图片落盘 + attachments 绑定 + 图片库查询 +
// 完整性检查 + OCR 文本索引（content_index_terms 的 attachment 分区）。
// 依据 DATABASE_DESIGN §2.3 与 FR-IMG-01/FR-MISC-03。
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/image/image_models.dart';
import '../../domain/search/tokenizer.dart';
import '../attachment/attachment_store.dart';
import '../database/app_database.dart';

/// 允许的附件归属类型（与 attachments.owner_kind CHECK 约束一致）
const kAttachmentOwnerKinds = <String>{
  'message',
  'post',
  'diary',
  'letter',
  'import',
};

/// 附件完整性检查结果
class AttachmentIntegrity {
  const AttachmentIntegrity({
    required this.missingRecords,
    required this.orphanFiles,
  });

  /// 数据库有记录但文件缺失
  final List<Attachment> missingRecords;

  /// 磁盘有文件但无有效数据库记录
  final List<String> orphanFiles;

  bool get isHealthy => missingRecords.isEmpty && orphanFiles.isEmpty;
}

class AttachmentRepository {
  AttachmentRepository(this._db, {AttachmentStore? store})
    : store = store ?? AttachmentStore();

  final AppDatabase _db;
  final AttachmentStore store;
  static const _uuid = Uuid();

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  /// 保存一张图片并绑定到归属记录（先写文件后写 DB）。
  ///
  /// [ownerKind] 见 [kAttachmentOwnerKinds]；[messageId] 仅在聊天消息图片时传。
  Future<Attachment> addImage({
    required String ownerKind,
    required String ownerId,
    String? messageId,
    required Uint8List bytes,
    required String fileName,
    String? ocrText,
    String? aiCaption,
    int? width,
    int? height,
  }) async {
    if (!kAttachmentOwnerKinds.contains(ownerKind)) {
      throw ArgumentError.value(ownerKind, 'ownerKind', '不支持的附件归属类型');
    }
    if (ownerId.trim().isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', '附件归属 id 不能为空');
    }
    final mime = requireImageMime(fileName);
    requireImageSize(bytes.length);
    final sha = AttachmentStore.sha256Of(bytes);

    // 相同内容已存在且文件完好 → 复用同一文件，不重复占用存储
    final reused = await _findReusableBySha(sha);
    StoredAttachmentFile stored;
    var wroteNewFile = false;
    if (reused != null) {
      stored = StoredAttachmentFile(
        relPath: reused.relPath,
        sha256: sha,
        sizeBytes: reused.sizeBytes ?? bytes.length,
        mime: reused.mime ?? mime,
      );
    } else {
      stored = await store.saveBytes(
        bytes,
        extension: extensionOf(fileName),
        mime: mime,
      );
      wroteNewFile = true;
    }

    final id = _uuid.v4();
    try {
      await _db
          .into(_db.attachments)
          .insert(
            AttachmentsCompanion.insert(
              id: id,
              ownerKind: ownerKind,
              ownerId: ownerId,
              relPath: stored.relPath,
              messageId: Value(messageId),
              mime: Value(stored.mime),
              sizeBytes: Value(stored.sizeBytes),
              width: Value(width),
              height: Value(height),
              ocrText: Value(ocrText),
              aiCaption: Value(aiCaption),
              sha256: Value(stored.sha256),
              createdAt: _nowIso(),
            ),
          );
    } catch (_) {
      // DB 失败时清理本次新写的文件（复用文件不能删）
      if (wroteNewFile) await store.deleteFile(stored.relPath);
      rethrow;
    }
    if ((ocrText ?? '').trim().isNotEmpty) {
      await _reindexOcr(id, ocrText!);
    }
    return (await _db.select(_db.attachments)
          ..where((t) => t.id.equals(id)))
        .getSingle();
  }

  Future<Attachment?> _findReusableBySha(String sha) async {
    if (!store.isReady) await store.ensureReady();
    final rows =
        await (_db.select(_db.attachments)
              ..where((t) => t.sha256.equals(sha) & t.deletedAt.isNull())
              ..limit(1))
            .get();
    if (rows.isEmpty) return null;
    final row = rows.first;
    return store.exists(row.relPath) ? row : null;
  }

  Future<List<Attachment>> attachmentsOf(
    String ownerKind,
    String ownerId, {
    bool includeDeleted = false,
  }) {
    final query = _db.select(_db.attachments)
      ..where((t) => t.ownerKind.equals(ownerKind) & t.ownerId.equals(ownerId))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    if (!includeDeleted) {
      query.where((t) => t.deletedAt.isNull());
    }
    return query.get();
  }

  /// 监听会话内所有消息图片（聊天页气泡渲染）
  Stream<List<Attachment>> watchMessageAttachments(String conversationId) {
    return _db
        .customSelect(
          '''
SELECT a.* FROM attachments a
JOIN messages m ON m.id = a.owner_id
WHERE a.owner_kind = 'message' AND a.deleted_at IS NULL
  AND m.conversation_id = ? AND m.deleted_at IS NULL
ORDER BY a.created_at ASC
''',
          variables: [Variable(conversationId)],
          readsFrom: {_db.attachments, _db.messages},
        )
        .watch()
        .map((rows) => [for (final row in rows) _mapAttachment(row)]);
  }

  /// 图片库列表（可按来源过滤）
  Future<List<GalleryImage>> galleryImages({String? ownerKind}) async {
    final where = StringBuffer('WHERE a.deleted_at IS NULL');
    final variables = <Variable>[];
    if (ownerKind != null && ownerKind.isNotEmpty) {
      where.write(' AND a.owner_kind = ?');
      variables.add(Variable(ownerKind));
    }
    final rows = await _db
        .customSelect(
          '''
SELECT a.id, a.rel_path, a.owner_kind, a.owner_id, a.created_at, a.mime,
       a.width, a.height, a.ocr_text, a.ai_caption,
       CASE a.owner_kind
         WHEN 'message' THEN (SELECT COUNT(*) FROM messages m
            WHERE m.id = a.owner_id AND m.deleted_at IS NULL)
         WHEN 'post' THEN (SELECT COUNT(*) FROM posts p
            WHERE p.id = a.owner_id AND p.deleted_at IS NULL)
         WHEN 'diary' THEN (SELECT COUNT(*) FROM diaries d
            WHERE d.id = a.owner_id AND d.deleted_at IS NULL)
         WHEN 'letter' THEN (SELECT COUNT(*) FROM letters l
            WHERE l.id = a.owner_id AND l.deleted_at IS NULL)
         ELSE 1
       END AS owner_exists
FROM attachments a
$where
ORDER BY a.created_at DESC
''',
          variables: variables,
          readsFrom: {
            _db.attachments,
            _db.messages,
            _db.posts,
            _db.diaries,
            _db.letters,
          },
        )
        .get();
    return [for (final row in rows) _mapGalleryImage(row)];
  }

  /// 图片文字搜索（OCR 文本或 AI 描述命中；ocr_text 为空时自然无结果）
  Future<List<GalleryImage>> searchByText(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final like = '%${q.toLowerCase()}%';
    final rows = await _db
        .customSelect(
          '''
SELECT a.id, a.rel_path, a.owner_kind, a.owner_id, a.created_at, a.mime,
       a.width, a.height, a.ocr_text, a.ai_caption,
       1 AS owner_exists
FROM attachments a
WHERE a.deleted_at IS NULL
  AND (LOWER(COALESCE(a.ocr_text, '')) LIKE ?
       OR LOWER(COALESCE(a.ai_caption, '')) LIKE ?)
ORDER BY a.created_at DESC
''',
          variables: [Variable(like), Variable(like)],
          readsFrom: {_db.attachments},
        )
        .get();
    return [for (final row in rows) _mapGalleryImage(row)];
  }

  /// 读取附件（含已软删时抛错）
  Future<Attachment?> getAttachment(String id) => (_db.select(
    _db.attachments,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// 消息图片所属会话 id（图片库长按「查看来源」跳转用）
  Future<String?> conversationIdOfMessage(String messageId) async {
    final row = await (_db.select(
      _db.messages,
    )..where((t) => t.id.equals(messageId))).getSingleOrNull();
    return row?.conversationId;
  }

  /// 软删附件记录；[deleteFile] 为真且无其他记录引用时同时删除磁盘文件。
  Future<void> softDelete(String id, {bool deleteFile = false}) async {
    final record = await getAttachment(id);
    if (record == null || record.deletedAt != null) return;
    await _db.transaction(() async {
      await (_db.update(_db.attachments)..where((t) => t.id.equals(id))).write(
        AttachmentsCompanion(deletedAt: Value(_nowIso())),
      );
      await (_db.delete(_db.contentIndexTerms)
            ..where((t) => t.docKind.equals('attachment') & t.docId.equals(id)))
          .go();
    });
    if (deleteFile && await _isPathUnreferenced(record.relPath)) {
      await store.deleteFile(record.relPath);
    }
  }

  Future<bool> _isPathUnreferenced(String relPath) async {
    final rows =
        await (_db.select(_db.attachments)
              ..where((t) => t.relPath.equals(relPath) & t.deletedAt.isNull())
              ..limit(1))
            .get();
    return rows.isEmpty;
  }

  /// 写入 OCR 文本并重建该附件的搜索索引
  Future<void> setOcrText(String id, String text) async {
    await (_db.update(_db.attachments)..where((t) => t.id.equals(id))).write(
      AttachmentsCompanion(ocrText: Value(text)),
    );
    await _reindexOcr(id, text);
  }

  Future<void> setCaption(String id, String caption) async {
    await (_db.update(_db.attachments)..where((t) => t.id.equals(id))).write(
      AttachmentsCompanion(aiCaption: Value(caption)),
    );
  }

  /// OCR 文本 → 全局搜索倒排（docKind=attachment），供阶段 14 全局搜索使用。
  Future<void> _reindexOcr(String attachmentId, String text) async {
    final tokens = <String>{};
    for (final token in tokenize(text)) {
      if (token.trim().isEmpty) continue;
      tokens.add(token);
    }
    await _db.transaction(() async {
      await (_db.delete(_db.contentIndexTerms)..where(
            (t) =>
                t.docKind.equals('attachment') & t.docId.equals(attachmentId),
          ))
          .go();
      for (final token in tokens) {
        await _db
            .into(_db.contentIndexTerms)
            .insert(
              ContentIndexTermsCompanion.insert(
                token: token,
                docKind: 'attachment',
                docId: attachmentId,
                fieldWeight: 1,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  /// 完整性检查：库记录缺文件 / 磁盘文件无记录
  Future<AttachmentIntegrity> checkIntegrity() async {
    await store.ensureReady();
    final records = await (_db.select(
      _db.attachments,
    )..where((t) => t.deletedAt.isNull())).get();
    final referenced = <String>{};
    final missing = <Attachment>[];
    for (final record in records) {
      referenced.add(record.relPath);
      if (!store.exists(record.relPath)) missing.add(record);
    }
    final stored = await store.listStoredRelPaths();
    final orphans = [
      for (final path in stored)
        if (path.startsWith('$kAttachmentFolder/') &&
            !referenced.contains(path))
          path,
    ];
    return AttachmentIntegrity(missingRecords: missing, orphanFiles: orphans);
  }

  Attachment _mapAttachment(QueryRow row) {
    return Attachment(
      id: row.read<String>('id'),
      messageId: row.read<String?>('message_id'),
      ownerKind: row.read<String>('owner_kind'),
      ownerId: row.read<String>('owner_id'),
      relPath: row.read<String>('rel_path'),
      mime: row.read<String?>('mime'),
      sizeBytes: row.read<int?>('size_bytes'),
      width: row.read<int?>('width'),
      height: row.read<int?>('height'),
      ocrText: row.read<String?>('ocr_text'),
      aiCaption: row.read<String?>('ai_caption'),
      sha256: row.read<String?>('sha256'),
      createdAt: row.read<String>('created_at'),
      deletedAt: row.read<String?>('deleted_at'),
    );
  }

  GalleryImage _mapGalleryImage(QueryRow row) {
    final createdAtRaw = row.read<String>('created_at');
    final createdAt = (DateTime.tryParse(createdAtRaw) ?? DateTime.now())
        .toLocal();
    return GalleryImage(
      id: row.read<String>('id'),
      relPath: row.read<String>('rel_path'),
      ownerKind: row.read<String>('owner_kind'),
      ownerId: row.read<String>('owner_id'),
      createdAt: createdAt,
      mime: row.read<String?>('mime'),
      width: row.read<int?>('width'),
      height: row.read<int?>('height'),
      ocrText: row.read<String?>('ocr_text'),
      aiCaption: row.read<String?>('ai_caption'),
      ownerExists: row.read<int>('owner_exists') > 0,
    );
  }
}
