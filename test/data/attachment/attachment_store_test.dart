// 附件文件存储单测（T12.1）：相对路径、sha256、缺失检查、孤儿文件列举。
import 'dart:io';
import 'dart:typed_data';

import 'package:bubble/data/attachment/attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late AttachmentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bubble_attachment_');
    store = AttachmentStore(root: root, clock: () => DateTime(2026, 5, 20, 21));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  test('保存字节：落盘路径符合 Attachments/yyyy/mm/uuid.ext 且 sha256 正确', () async {
    final saved = await store.saveBytes(
      bytes([1, 2, 3, 4]),
      extension: 'png',
      mime: 'image/png',
    );

    expect(
      RegExp(r'^Attachments/2026/05/[0-9a-f-]{36}\.png$')
          .hasMatch(saved.relPath),
      isTrue,
      reason: saved.relPath,
    );
    expect(saved.sizeBytes, 4);
    expect(saved.sha256, AttachmentStore.sha256Of([1, 2, 3, 4]));
    expect(store.exists(saved.relPath), isTrue);
    expect(await store.fileOf(saved.relPath).readAsBytes(), [1, 2, 3, 4]);
  });

  test('未初始化时 exists 返回 false，fileOf 抛 StateError', () {
    final cold = AttachmentStore(root: root);
    expect(cold.exists('Attachments/2026/05/a.png'), isFalse);
    expect(() => cold.fileOf('Attachments/2026/05/a.png'), throwsStateError);
  });

  test('完全相同字节的 sha256 稳定（去重依据）', () async {
    final a = await store.saveBytes(
      bytes([9, 9]),
      extension: 'jpg',
      mime: 'image/jpeg',
    );
    final b = await store.saveBytes(
      bytes([9, 9]),
      extension: 'jpg',
      mime: 'image/jpeg',
    );
    expect(a.sha256, b.sha256);
    expect(a.relPath, isNot(b.relPath)); // 存储层不做去重，由仓储决定复用
  });

  test('删除文件与列出已落盘文件（相对路径 / 分隔）', () async {
    final a = await store.saveBytes(
      bytes([1]),
      extension: 'png',
      mime: 'image/png',
    );
    final b = await store.saveBytes(
      bytes([2]),
      extension: 'png',
      mime: 'image/png',
    );

    final list = await store.listStoredRelPaths();
    expect(list.toSet(), {a.relPath, b.relPath});

    await store.deleteFile(a.relPath);
    expect(store.exists(a.relPath), isFalse);
    expect(await store.listStoredRelPaths(), [b.relPath]);
    // 删除不存在的文件不抛错
    await store.deleteFile('Attachments/2026/05/none.png');
  });

  test('空的 Attachments 目录返回空列表', () async {
    await store.ensureReady();
    expect(await store.listStoredRelPaths(), isEmpty);
  });
}
