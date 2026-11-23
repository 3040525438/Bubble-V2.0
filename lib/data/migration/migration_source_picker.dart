// 迁移来源选择器（T14.5 补充）：系统文件选择 + .zip 解压为可读目录。
// 平台差异：桌面可直接选文件夹；iOS 不支持选目录、Android 目录为 content:// 不可直读，
// 因此移动端统一使用 .zip 压缩包，解压到应用临时目录（源文件仍只读，不修改）。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 选择结果：可读的源根目录。
class PickedMigrationSource {
  const PickedMigrationSource({
    required this.rootPath,
    required this.label,
    this.fromArchive = false,
  });

  final String rootPath;
  final String label;

  /// 是否来自压缩包解压副本
  final bool fromArchive;
}

/// 迁移来源选择抽象（测试可注入假实现）。
abstract class MigrationSourcePicker {
  /// 当前平台是否支持直接选择文件夹（桌面）。
  bool get supportsDirectory;

  /// 选择文件夹；不支持或用户取消时返回 null。
  Future<PickedMigrationSource?> pickDirectory();

  /// 选择 .zip 压缩包并解压；用户取消时返回 null。
  Future<PickedMigrationSource?> pickArchive();
}

class FilePickerMigrationSourcePicker implements MigrationSourcePicker {
  @override
  bool get supportsDirectory =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  Future<PickedMigrationSource?> pickDirectory() async {
    if (!supportsDirectory) return null;
    final uri = await FilePicker.pickDirectory(dialogTitle: '选择 AstrBot 数据目录');
    if (uri == null) return null;
    final path = uri.toFilePath();
    return PickedMigrationSource(
      rootPath: path,
      label: path.split(Platform.pathSeparator).last,
    );
  }

  @override
  Future<PickedMigrationSource?> pickArchive() async {
    final selected = await FilePicker.pickFile(
      dialogTitle: '选择 AstrBot 数据压缩包（.zip）',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (selected == null) return null;

    final bytes = await selected.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('所选压缩包为空');
    }

    final temp = await getTemporaryDirectory();
    final target = Directory(
      '${temp.path}${Platform.pathSeparator}'
      'bubble_migration_${DateTime.now().millisecondsSinceEpoch}',
    );
    await target.create(recursive: true);
    final rootPath = await extractAstrBotArchive(bytes, target);
    return PickedMigrationSource(
      rootPath: rootPath,
      label: selected.name,
      fromArchive: true,
    );
  }
}

/// 解压 AstrBot 数据包到目标目录，并返回识别出的源根目录。
/// 安全：忽略绝对路径与包含「..」的条目，防止 zip-slip 越权写入。
Future<String> extractAstrBotArchive(
  List<int> bytes,
  Directory targetDir,
) async {
  final archive = ZipDecoder().decodeBytes(bytes);
  final base = targetDir.absolute.path;
  for (final entry in archive) {
    if (!entry.isFile) continue;
    final normalized = entry.name.replaceAll('\\', '/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.split('/').contains('..')) {
      continue;
    }
    final file = File(
      '$base${Platform.pathSeparator}'
      '${normalized.split('/').join(Platform.pathSeparator)}',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(entry.readBytes() ?? Uint8List(0));
  }
  return resolveAstrBotRoot(targetDir);
}

/// 识别 AstrBot 源根：优先当前目录，其次唯一（或首个）包含 data/diary/letters 的子目录。
String resolveAstrBotRoot(Directory dir) {
  bool looksLikeRoot(Directory candidate) {
    return Directory('${candidate.path}${Platform.pathSeparator}data')
            .existsSync() ||
        Directory('${candidate.path}${Platform.pathSeparator}diary')
            .existsSync() ||
        Directory('${candidate.path}${Platform.pathSeparator}letters')
            .existsSync();
  }

  if (looksLikeRoot(dir)) return dir.path;
  for (final entity in dir.listSync()) {
    if (entity is Directory && looksLikeRoot(entity)) return entity.path;
  }
  return dir.path;
}
