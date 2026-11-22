// 聊天图片消息单测（T12.2/T12.3）：图片落盘绑定、视觉能力分流、非法格式拦截。
import 'dart:io';
import 'dart:typed_data';

import 'package:bubble/data/attachment/attachment_store.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/attachment_repository.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/domain/image/image_models.dart';
import 'package:bubble/presentation/chat/chat_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_provider.dart';

class VisionFakeProvider extends FakeProvider {
  VisionFakeProvider({required this.vision});

  final bool vision;

  @override
  bool get supportsVision => vision;
}

Future<void> wait([int ms = 350]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late AppDatabase db;
  late Directory root;
  late AttachmentStore store;
  late AttachmentRepository attachments;
  late ConversationRepository repo;
  late Conversation conv;

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_chat_image_');
    store = AttachmentStore(root: root);
    await store.ensureReady();
    attachments = AttachmentRepository(db, store: store);
    repo = ConversationRepository(db);
    conv = await repo.createConversation(title: '图片聊天');
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('不支持视觉的模型：图片仅本地保存，请求体不带图片', () async {
    final provider = VisionFakeProvider(vision: false);
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
      attachmentRepository: attachments,
    );
    addTearDown(session.dispose);

    await session.sendWithImages('', [
      OutgoingImage(bytes: bytes([1, 2, 3]), fileName: 'a.png'),
    ]);
    await wait();

    final messages = await repo.messages(conv.id);
    final user = messages.firstWhere((m) => m.role == 'user');
    expect(user.content, '[图片]');
    expect((await attachments.attachmentsOf('message', user.id)).length, 1);

    final sentUserTurn = provider.lastHistory.lastWhere(
      (turn) => turn.role == 'user',
    );
    expect(sentUserTurn.images, isEmpty, reason: '不支持视觉时不得假装带图');
  });

  test('支持视觉的模型：本轮用户消息携带图片载荷', () async {
    final provider = VisionFakeProvider(vision: true);
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
      attachmentRepository: attachments,
    );
    addTearDown(session.dispose);

    await session.sendWithImages('看看这张', [
      OutgoingImage(bytes: bytes([9, 8]), fileName: 'b.jpg'),
    ]);
    await wait();

    final sentUserTurn = provider.lastHistory.lastWhere(
      (turn) => turn.role == 'user',
    );
    expect(sentUserTurn.content, '看看这张');
    expect(sentUserTurn.images.length, 1);
    expect(sentUserTurn.images.single.mime, 'image/jpeg');
    expect(sentUserTurn.images.single.bytes, [9, 8]);
  });

  test('非法格式：不写消息、不写附件、明确抛错', () async {
    final provider = VisionFakeProvider(vision: true);
    final session = ChatSessionController(
      repository: repo,
      provider: provider,
      conversationId: conv.id,
      attachmentRepository: attachments,
    );
    addTearDown(session.dispose);

    await expectLater(
      session.sendWithImages('', [
        OutgoingImage(bytes: bytes([1]), fileName: 'clip.mp4'),
      ]),
      throwsA(isA<UnsupportedImageException>()),
    );
    expect(await repo.messages(conv.id), isEmpty);
    expect(await attachments.galleryImages(), isEmpty);
    expect(provider.calls, 0);
  });

  test('超过单条消息图片上限抛 ArgumentError', () async {
    final session = ChatSessionController(
      repository: repo,
      provider: VisionFakeProvider(vision: false),
      conversationId: conv.id,
      attachmentRepository: attachments,
    );
    addTearDown(session.dispose);

    await expectLater(
      session.sendWithImages('', [
        for (var i = 0; i <= kMaxImagesPerMessage; i++)
          OutgoingImage(bytes: bytes([i]), fileName: 'a$i.png'),
      ]),
      throwsArgumentError,
    );
  });
}
