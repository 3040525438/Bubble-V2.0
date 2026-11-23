// 迁移来源选择器测试（T14.5 补充）：zip 解压、根目录识别与路径穿越防护。
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:bubble/data/migration/migration_source_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('bubble_zip_test_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('解压压缩包并识别嵌套的 AstrBot 根目录', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('astrbot/diary/2026-10-24.md', '# 日记'))
      ..addFile(ArchiveFile.string('astrbot/data/data_v4.db', ''));
    final bytes = ZipEncoder().encodeBytes(archive);

    final target = Directory('${temp.path}${Platform.pathSeparator}out');
    await target.create(recursive: true);
    final root = await extractAstrBotArchive(bytes, target);

    expect(root, '${target.path}${Platform.pathSeparator}astrbot');
    final diary = File(
      '$root${Platform.pathSeparator}diary'
      '${Platform.pathSeparator}2026-10-24.md',
    );
    expect(await diary.exists(), isTrue);
    expect(await diary.readAsString(), '# 日记');
  });

  test('忽略包含 .. 的路径穿越条目', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('../evil.txt', 'bad'))
      ..addFile(ArchiveFile.string('diary/2026-10-24.md', '# ok'));
    final bytes = ZipEncoder().encodeBytes(archive);

    final target = Directory('${temp.path}${Platform.pathSeparator}out2');
    await target.create(recursive: true);
    await extractAstrBotArchive(bytes, target);

    expect(
      await File('${temp.path}${Platform.pathSeparator}evil.txt').exists(),
      isFalse,
    );
    expect(
      await File(
        '${target.path}${Platform.pathSeparator}diary'
        '${Platform.pathSeparator}2026-10-24.md',
      ).exists(),
      isTrue,
    );
  });

  test('当前目录已是源根时直接返回', () async {
    final dir = Directory('${temp.path}${Platform.pathSeparator}root');
    await Directory('${dir.path}${Platform.pathSeparator}data')
        .create(recursive: true);
    expect(resolveAstrBotRoot(dir), dir.path);
  });
}
