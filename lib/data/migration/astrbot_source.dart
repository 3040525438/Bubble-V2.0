// AstrBot 只读数据源（T14.5）：SQLite 只读打开 + 文件/JSON 读取。
// 严格只读：不写入、不迁移 API Key、源目录永不修改（FR-MIG-02）。
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// 只读 SQL 查询抽象（测试可注入，避免依赖真实 SQLite 文件）。
abstract class ReadOnlySql {
  List<Map<String, Object?>> query(String dbPath, String sql);

  /// 是否具备执行条件（实现可返回 false 表示驱动不可用）
  bool get supported;

  void close();
}

/// sqlite3 只读实现（OpenMode.readOnly）。
class Sqlite3ReadOnlySql implements ReadOnlySql {
  final Map<String, Database> _opened = {};

  @override
  bool get supported => true;

  @override
  List<Map<String, Object?>> query(String dbPath, String sql) {
    final db = _opened.putIfAbsent(
      dbPath,
      () => sqlite3.open(dbPath, mode: OpenMode.readOnly),
    );
    final result = db.select(sql);
    return [
      for (final row in result) {for (final key in row.keys) key: row[key]},
    ];
  }

  @override
  void close() {
    for (final db in _opened.values) {
      db.close();
    }
    _opened.clear();
  }
}

/// 聊天消息（一条）。
class AstrChatMessage {
  const AstrChatMessage({
    required this.sourceId,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAtMs,
    this.senderNickname,
    this.deleted = false,
  });

  final int sourceId;
  final String conversationId;
  final String role;
  final String content;
  final int createdAtMs;
  final String? senderNickname;
  final bool deleted;
}

/// 长期记忆条目（diary/memory.db）。
class AstrMemoryRow {
  const AstrMemoryRow({
    required this.id,
    required this.kind,
    required this.day,
    required this.text,
  });

  final int id;
  final String kind;
  final String day;
  final String text;
}

/// 人格提示词（data_v4.db personas）。
class AstrPersonaRow {
  const AstrPersonaRow({required this.personaId, required this.systemPrompt});

  final String personaId;
  final String systemPrompt;
}

/// 文本文件（日记/信件）。
class AstrTextDoc {
  const AstrTextDoc({
    required this.name,
    required this.content,
    required this.sha256,
    this.date,
  });

  final String name;
  final String content;
  final String sha256;

  /// 文件名中的日期（yyyy-MM-dd），非日期文件名时为 null
  final String? date;
}

/// 伴侣记忆条目（companions.json）。
class AstrCompanionMemoryItem {
  const AstrCompanionMemoryItem({
    required this.text,
    required this.kind,
    this.createdAt,
  });

  final String text;
  final String kind;
  final String? createdAt;
}

/// 伴侣关系（companions.json 单个用户）。
class AstrCompanion {
  const AstrCompanion({
    required this.userId,
    required this.role,
    required this.score,
    required this.items,
    this.nickname,
  });

  final String userId;
  final String? nickname;
  final String role;
  final num score;
  final List<AstrCompanionMemoryItem> items;
}

class AstrBotSource {
  AstrBotSource({required this.rootPath, ReadOnlySql? sql})
    : _sql = sql ?? Sqlite3ReadOnlySql();

  final String rootPath;
  final ReadOnlySql _sql;

  static final _dateFilePattern = RegExp(r'^(\d{4}-\d{2}-\d{2})\.md$');

  String get _sep => Platform.pathSeparator;

  String get chatDbPath =>
      '$rootPath${_sep}data${_sep}plugin_data${_sep}chat_memory${_sep}chat_memory.db';
  String get memoryDbPath => '$rootPath${_sep}diary${_sep}memory.db';
  String get personaDbPath => '$rootPath${_sep}data${_sep}data_v4.db';
  String get companionsJsonPath =>
      '$rootPath${_sep}data${_sep}plugin_data'
      '${_sep}astrbot_plugin_private_companion${_sep}companions.json';
  String get diaryDirPath => '$rootPath${_sep}diary';
  String get lettersDirPath => '$rootPath${_sep}letters';
  String get booksDirPath => '$rootPath${_sep}books${_sep}notes';

  /// 源根目录是否存在（不存在时向导明确提示「源不可读」，不假装有数据）。
  Future<bool> get available async => Directory(rootPath).exists();

  /// 聊天消息（按时间升序；含已删除标记，由导入侧跳过）。
  Future<List<AstrChatMessage>> chatMessages() async {
    if (!await File(chatDbPath).exists()) return const [];
    final rows = _sql.query(
      chatDbPath,
      'SELECT id, conversation_id, role, content, sender_nickname, '
      'raw_timestamp, created_at, deleted_at FROM chat_memory_records '
      'ORDER BY raw_timestamp, id',
    );
    return [
      for (final row in rows)
        AstrChatMessage(
          sourceId: _asInt(row['id']) ?? 0,
          conversationId: row['conversation_id']?.toString() ?? '',
          role: row['role']?.toString() ?? 'user',
          content: row['content']?.toString() ?? '',
          createdAtMs: _timestampMs(row),
          senderNickname: row['sender_nickname']?.toString(),
          deleted: row['deleted_at'] != null,
        ),
    ];
  }

  /// 图片归档条数（源文件默认不随库保存，导入侧需逐个校验存在性）。
  Future<int> mediaArchiveCount() async {
    if (!await File(chatDbPath).exists()) return 0;
    final rows = _sql.query(
      chatDbPath,
      'SELECT COUNT(*) AS c FROM chat_memory_media_archive',
    );
    return _asInt(rows.isEmpty ? null : rows.first['c']) ?? 0;
  }

  /// 长期记忆条目。
  Future<List<AstrMemoryRow>> memories() async {
    if (!await File(memoryDbPath).exists()) return const [];
    final rows = _sql.query(
      memoryDbPath,
      'SELECT id, kind, day, text FROM mem ORDER BY id',
    );
    return [
      for (final row in rows)
        AstrMemoryRow(
          id: _asInt(row['id']) ?? 0,
          kind: row['kind']?.toString() ?? 'chat',
          day: row['day']?.toString() ?? '',
          text: row['text']?.toString() ?? '',
        ),
    ];
  }

  /// 人格提示词（通常是单个 whale）。
  Future<List<AstrPersonaRow>> personas() async {
    if (!await File(personaDbPath).exists()) return const [];
    final rows = _sql.query(
      personaDbPath,
      'SELECT persona_id, system_prompt FROM personas ORDER BY id',
    );
    return [
      for (final row in rows)
        if ((row['system_prompt']?.toString() ?? '').trim().isNotEmpty)
          AstrPersonaRow(
            personaId: row['persona_id']?.toString() ?? 'unknown',
            systemPrompt: row['system_prompt']!.toString(),
          ),
    ];
  }

  /// 日记文件（yyyy-MM-dd.md；排除 FACTS.md/INDEX.md 与 txt 子目录）。
  Future<List<AstrTextDoc>> diaries() => _readDateFiles(diaryDirPath);

  /// 信件文件（letters/*.md；排除 INDEX）。去重由导入侧按内容 sha256 处理。
  Future<List<AstrTextDoc>> letters() => _readPlainMarkdown(lettersDirPath);

  /// 读书笔记（books/notes/*.md）。
  Future<List<AstrTextDoc>> bookNotes() => _readPlainMarkdown(booksDirPath);

  Future<List<AstrTextDoc>> _readDateFiles(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final docs = <AstrTextDoc>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _baseName(entity.path);
      final match = _dateFilePattern.firstMatch(name);
      if (match == null) continue;
      final content = await entity.readAsString();
      docs.add(
        AstrTextDoc(
          name: name,
          content: content,
          sha256: _sha256Text(content),
          date: match.group(1),
        ),
      );
    }
    docs.sort((a, b) => (a.date ?? '').compareTo(b.date ?? ''));
    return docs;
  }

  Future<List<AstrTextDoc>> _readPlainMarkdown(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final docs = <AstrTextDoc>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _baseName(entity.path);
      final lower = name.toLowerCase();
      if (!lower.endsWith('.md')) continue;
      if (lower == 'index.md' || lower == 'facts.md') continue;
      final content = await entity.readAsString();
      docs.add(
        AstrTextDoc(
          name: name,
          content: content,
          sha256: _sha256Text(content),
          date: _dateFilePattern.firstMatch(name)?.group(1),
        ),
      );
    }
    docs.sort((a, b) => (a.date ?? a.name).compareTo(b.date ?? b.name));
    return docs;
  }

  /// 伴侣关系与伴侣记忆条目（companions.json）。
  Future<List<AstrCompanion>> companions() async {
    final file = File(companionsJsonPath);
    if (!await file.exists()) return const [];
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return const [];
    final users = decoded['users'];
    if (users is! Map) return const [];
    final result = <AstrCompanion>[];
    for (final entry in users.entries) {
      final userId = entry.key.toString();
      final value = entry.value;
      if (value is! Map) continue;
      final items = <AstrCompanionMemoryItem>[];
      final memory = value['companion_memory'];
      if (memory is Map) {
        final rawItems = memory['items'];
        if (rawItems is List) {
          for (final item in rawItems) {
            if (item is! Map) continue;
            final text = item['text']?.toString() ?? '';
            if (text.trim().isEmpty) continue;
            items.add(
              AstrCompanionMemoryItem(
                text: text,
                kind: item['kind']?.toString() ?? 'important',
                createdAt: item['created_at']?.toString(),
              ),
            );
          }
        }
      }
      result.add(
        AstrCompanion(
          userId: userId,
          nickname: value['nickname']?.toString(),
          role: value['relationship_role']?.toString() ?? 'friend',
          score: value['relationship_score'] is num
              ? value['relationship_score'] as num
              : 0,
          items: items,
        ),
      );
    }
    return result;
  }

  void dispose() => _sql.close();

  // ------------------------------------------------------------ 工具

  static String _baseName(String path) {
    final index = path.lastIndexOf(RegExp(r'[\\/]'));
    return index < 0 ? path : path.substring(index + 1);
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// raw_timestamp 为秒；缺失时回退 created_at（本地时间）。
  static int _timestampMs(Map<String, Object?> row) {
    final raw = _asInt(row['raw_timestamp']);
    if (raw != null && raw > 0) return raw * 1000;
    final created = row['created_at']?.toString();
    if (created == null || created.isEmpty) return 0;
    final parsed = DateTime.tryParse(created.replaceFirst(' ', 'T'));
    return parsed?.millisecondsSinceEpoch ?? 0;
  }

  static String _sha256Text(String text) =>
      sha256.convert(utf8.encode(text)).toString();
}
