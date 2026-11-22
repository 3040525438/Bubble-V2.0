// 附件仓储单测（T12.1/T12.4）：绑定、sha 复用、软删、来源筛选、OCR 搜索与完整性。
import 'dart:io';
import 'dart:typed_data';

import 'package:bubble/data/attachment/attachment_store.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/attachment_repository.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/data/repositories/post_repository.dart';
import 'package:bubble/domain/image/image_models.dart';
import 'package:bubble/domain/post/post_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late Directory root;
  late AttachmentStore store;
  late AttachmentRepository attachments;
  late ConversationRepository conversations;
  late PostRepository posts;
  late Conversation conv;
  late Message message;

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_attach_repo_');
    store = AttachmentStore(root: root);
    attachments = AttachmentRepository(db, store: store);
    conversations = ConversationRepository(db);
    posts = PostRepository(db);
    conv = await conversations.createConversation(title: '图片测试');
    message = await conversations.appendUserMessage(conv.id, '[图片]');
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('绑定图片到消息并记录元数据', () async {
    final saved = await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      messageId: message.id,
      bytes: bytes([1, 2, 3]),
      fileName: 'a.png',
      width: 10,
      height: 20,
    );

    expect(saved.relPath, startsWith('Attachments/'));
    expect(saved.mime, 'image/png');
    expect(saved.sha256, AttachmentStore.sha256Of([1, 2, 3]));
    expect(saved.width, 10);
    expect(saved.height, 20);
    expect(store.exists(saved.relPath), isTrue);

    final list = await attachments.attachmentsOf('message', message.id);
    expect(list.length, 1);
    expect(list.single.id, saved.id);
  });

  test('相同内容复用文件路径（不重复占存储），仍有引用时不删文件', () async {
    final a = await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([7, 7, 7]),
      fileName: 'a.png',
    );
    final b = await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([7, 7, 7]),
      fileName: 'b.jpg',
    );

    expect(a.relPath, b.relPath);
    expect(await store.listStoredRelPaths(), hasLength(1));

    await attachments.softDelete(a.id, deleteFile: true);
    expect(store.exists(b.relPath), isTrue, reason: '仍有记录引用该文件');

    await attachments.softDelete(b.id, deleteFile: true);
    expect(store.exists(b.relPath), isFalse);
  });

  test('不支持的格式抛错且不写记录', () async {
    await expectLater(
      attachments.addImage(
        ownerKind: 'message',
        ownerId: message.id,
        bytes: bytes([1]),
        fileName: 'clip.mp4',
      ),
      throwsA(isA<UnsupportedImageException>()),
    );
    expect(await attachments.attachmentsOf('message', message.id), isEmpty);
    expect(await store.listStoredRelPaths(), isEmpty);
  });

  test('非法归属类型抛 ArgumentError', () async {
    await expectLater(
      attachments.addImage(
        ownerKind: 'unknown',
        ownerId: 'x',
        bytes: bytes([1]),
        fileName: 'a.png',
      ),
      throwsArgumentError,
    );
  });

  test('图片库按来源筛选，来源软删后 ownerExists=false', () async {
    final post = await posts.createPost(const PostDraft(content: '今天的云很好看'));
    await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([1]),
      fileName: 'm.png',
    );
    await attachments.addImage(
      ownerKind: 'post',
      ownerId: post.id,
      bytes: bytes([2]),
      fileName: 'p.png',
    );

    expect((await attachments.galleryImages()).length, 2);
    final onlyPost = await attachments.galleryImages(ownerKind: 'post');
    expect(onlyPost.single.ownerId, post.id);
    expect(onlyPost.single.ownerExists, isTrue);

    await posts.softDelete(post.id);
    final afterDelete = await attachments.galleryImages(ownerKind: 'post');
    expect(afterDelete.single.ownerExists, isFalse);
  });

  test('软删后不出现在画廊与归属查询中', () async {
    final saved = await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([5]),
      fileName: 'a.png',
    );
    await attachments.softDelete(saved.id);
    expect(await attachments.galleryImages(), isEmpty);
    expect(await attachments.attachmentsOf('message', message.id), isEmpty);
    expect(store.exists(saved.relPath), isTrue, reason: '未要求删文件时保留');
  });

  test('OCR 文本可搜索，并写入 content_index_terms', () async {
    final saved = await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([3, 1, 4]),
      fileName: 'receipt.png',
      ocrText: '奶茶店收据 12 元',
      aiCaption: '一张收据',
    );

    expect((await attachments.searchByText('奶茶')).single.id, saved.id);
    expect((await attachments.searchByText('收据')).single.id, saved.id);

    final terms = await (db.select(
      db.contentIndexTerms,
    )..where((t) => t.docId.equals(saved.id))).get();
    expect(terms, isNotEmpty);
    expect(terms.every((t) => t.docKind == 'attachment'), isTrue);

    await attachments.setOcrText(saved.id, '');
    expect(await attachments.searchByText('奶茶'), isEmpty);
    final cleared = await (db.select(
      db.contentIndexTerms,
    )..where((t) => t.docId.equals(saved.id))).get();
    expect(cleared, isEmpty);
  });

  test('完整性检查：缺失文件与孤儿文件', () async {
    final kept = await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([8]),
      fileName: 'kept.png',
    );
    final missing = await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([9]),
      fileName: 'lost.png',
    );
    await store.deleteFile(missing.relPath);
    final orphan = await store.saveBytes(
      bytes([6, 6]),
      extension: 'png',
      mime: 'image/png',
    );

    final integrity = await attachments.checkIntegrity();
    expect(integrity.isHealthy, isFalse);
    expect(integrity.missingRecords.map((r) => r.id), [missing.id]);
    expect(integrity.orphanFiles, contains(orphan.relPath));
    expect(integrity.orphanFiles, isNot(contains(kept.relPath)));
  });

  test('监听会话消息图片（join messages）', () async {
    await attachments.addImage(
      ownerKind: 'message',
      ownerId: message.id,
      bytes: bytes([4, 2]),
      fileName: 'a.png',
    );
    final list = await attachments.watchMessageAttachments(conv.id).first;
    expect(list.length, 1);
    expect(list.single.ownerId, message.id);

    final conversationId = await attachments.conversationIdOfMessage(
      message.id,
    );
    expect(conversationId, conv.id);
  });
}
