// 附件文件存储（T12.1）：沙盒 Attachments/<yyyy>/<mm>/<uuid>.<ext> 相对路径。
// 约定：先写文件后写数据库（崩溃最多产生 orphan 文件，可被完整性检查清理）。
// 依据 DATABASE_DESIGN §2.3 与 REQUIREMENTS FR-IMG-01。
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

const kAttachmentFolder = 'Attachments';

/// 落盘结果
class StoredAttachmentFile {
  const StoredAttachmentFile({
    required this.relPath,
    required this.sha256,
    required this.sizeBytes,
    required this.mime,
  });

  /// 沙盒相对路径（/ 分隔，入库字段 relPath）
  final String relPath;
  final String sha256;
  final int sizeBytes;
  final String mime;
}

class AttachmentStore {
  AttachmentStore({Directory? root, DateTime Function()? clock})
    : _rootOverride = root,
      _clock = clock ?? DateTime.now;

  final Directory? _rootOverride;
  final DateTime Function() _clock;
  static const _uuid = Uuid();

  Directory? _resolvedRoot;

  /// 解析根目录（应用文档目录；测试可注入临时目录）。
  Future<Directory> ensureReady() async {
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    final root = _rootOverride ?? await getApplicationDocumentsDirectory();
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _resolvedRoot = root;
    return root;
  }

  /// 是否已解析根目录（同步渲染前需先 ensureReady）
  bool get isReady => _resolvedRoot != null;

  /// 相对路径 → 绝对文件（同步；未初始化时抛 StateError）
  File fileOf(String relPath) {
    final root = _resolvedRoot;
    if (root == null) {
      throw StateError('AttachmentStore 未初始化，请先 await ensureReady()');
    }
    final segments = relPath.split('/').where((s) => s.isNotEmpty);
    return File(
      '${root.path}${Platform.pathSeparator}${segments.join(Platform.pathSeparator)}',
    );
  }

  /// 图片是否真实存在（UI 占位判断）
  bool exists(String relPath) {
    if (!isReady) return false;
    return fileOf(relPath).existsSync();
  }

  /// 生成相对路径（不落盘）
  String relativePathFor(String extension) {
    final now = _clock().toLocal();
    final year = now.year.toString().padLeft(4, '0');
    final month = now.month.toString().padLeft(2, '0');
    final ext = extension.toLowerCase().replaceAll('.', '');
    return '$kAttachmentFolder/$year/$month/${_uuid.v4()}.$ext';
  }

  /// 写入字节（先创建目录，再写文件并 flush）
  Future<StoredAttachmentFile> saveBytes(
    Uint8List bytes, {
    required String extension,
    required String mime,
  }) async {
    await ensureReady();
    final relPath = relativePathFor(extension);
    final file = fileOf(relPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return StoredAttachmentFile(
      relPath: relPath,
      sha256: sha256Of(bytes),
      sizeBytes: bytes.length,
      mime: mime,
    );
  }

  /// 删除文件（不存在时忽略）
  Future<void> deleteFile(String relPath) async {
    if (relPath.trim().isEmpty || !isReady) return;
    final file = fileOf(relPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 递归列出已落盘文件（相对路径，仅 Attachments 目录）
  Future<List<String>> listStoredRelPaths() async {
    final root = await ensureReady();
    final dir = Directory(
      '${root.path}${Platform.pathSeparator}$kAttachmentFolder',
    );
    if (!await dir.exists()) return const [];
    final result = <String>[];
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(root.path.length)
          .replaceAll('\\', '/')
          .replaceAll(RegExp('^/+'), '');
      result.add(relative);
    }
    return result;
  }

  /// 内容摘要（完整性校验/去重）
  static String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
}
