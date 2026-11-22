// 导出服务（T14.3）：JSON 全量导出与 Markdown 分域导出。
// 导出目录 Exports/（应用文档目录）；只导出未软删的内容，不改变任何数据。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/backup/backup_models.dart';
import '../database/app_database.dart';
import 'database_snapshot.dart';

class ExportService {
  ExportService(this._db, {Directory? root, DateTime Function()? clock})
    : _rootOverride = root,
      _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final Directory? _rootOverride;
  final DateTime Function() _clock;

  static const exportFolder = 'Exports';

  Directory? _resolvedRoot;

  Future<Directory> _root() async {
    final existing = _resolvedRoot;
    if (existing != null) return existing;
    final root = _rootOverride ?? await getApplicationDocumentsDirectory();
    if (!await root.exists()) await root.create(recursive: true);
    _resolvedRoot = root;
    return root;
  }

  static String _stamp(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}${two(l.month)}${two(l.day)}_'
        '${two(l.hour)}${two(l.minute)}${two(l.second)}';
  }

  static String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    return dt == null ? iso : _fmtDateTime(dt);
  }

  static String _fmtMs(int? ms) {
    if (ms == null) return '';
    return _fmtDateTime(DateTime.fromMillisecondsSinceEpoch(ms).toLocal());
  }

  static String _fmtDateTime(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  Future<Directory> _exportDir() async {
    final root = await _root();
    final dir = Directory('${root.path}${Platform.pathSeparator}$exportFolder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 按格式导出。
  Future<ExportResult> export(ExportFormat format) {
    return switch (format) {
      ExportFormat.json => exportJson(),
      ExportFormat.markdown => exportMarkdown(),
    };
  }

  /// JSON 全量导出（结构同备份 data.json，另加 exportedAt/tableCounts）。
  Future<ExportResult> exportJson() async {
    final dir = await _exportDir();
    final tables = await DatabaseSnapshot(_db).dump();
    final payload = <String, Object?>{
      'format': 'bubble-export',
      'formatVersion': 1,
      'schemaVersion': _db.schemaVersion,
      'exportedAt': _clock().toUtc().toIso8601String(),
      'tableCounts': {for (final e in tables.entries) e.key: e.value.length},
      'tables': tables,
    };
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      'bubble_export_${_stamp(_clock())}.json',
    );
    await file.writeAsBytes(bytes, flush: true);
    return ExportResult(
      format: ExportFormat.json,
      paths: [file.path],
      byteSize: bytes.length,
    );
  }

  /// Markdown 分域导出：聊天/记忆/说说/日记/信件/经历 各一份。
  Future<ExportResult> exportMarkdown() async {
    final dir = await _exportDir();
    final tables = await DatabaseSnapshot(_db).dump();
    final writers = <String, String Function()>{
      'chat': () => _chatMarkdown(tables),
      'memory': () => _memoryMarkdown(tables),
      'posts': () => _postMarkdown(tables),
      'diary': () => _diaryMarkdown(tables),
      'letters': () => _letterMarkdown(tables),
      'experience': () => _experienceMarkdown(tables),
    };

    final paths = <String>[];
    var total = 0;
    final stamp = _stamp(_clock());
    for (final entry in writers.entries) {
      final content = entry.value();
      if (content.trim().isEmpty) continue;
      final bytes = utf8.encode(content);
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        'bubble_${entry.key}_$stamp.md',
      );
      await file.writeAsBytes(bytes, flush: true);
      paths.add(file.path);
      total += bytes.length;
    }
    return ExportResult(
      format: ExportFormat.markdown,
      paths: paths,
      byteSize: total,
    );
  }

  // ------------------------------------------------------------ Markdown 生成

  static List<Map<String, Object?>> _rows(
    Map<String, List<Map<String, Object?>>> tables,
    String table,
  ) {
    return tables[table] ?? const [];
  }

  static bool _alive(Map<String, Object?> row) => row['deleted_at'] == null;

  static String _str(Map<String, Object?> row, String key) {
    final value = row[key];
    return value == null ? '' : value.toString();
  }

  static int? _int(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  String _chatMarkdown(Map<String, List<Map<String, Object?>>> tables) {
    final conversations = _rows(tables, 'conversations').where(_alive).toList()
      ..sort(
        (a, b) => (_int(b, 'last_message_at') ?? 0).compareTo(
          _int(a, 'last_message_at') ?? 0,
        ),
      );
    final messages = _rows(tables, 'messages').where(_alive).toList();
    final buffer = StringBuffer()
      ..writeln('# 聊天记录')
      ..writeln()
      ..writeln('导出时间：${_fmtDateTime(_clock().toLocal())}')
      ..writeln();
    for (final c in conversations) {
      final cid = _str(c, 'id');
      final list =
          messages.where((m) => _str(m, 'conversation_id') == cid).toList()
            ..sort(
              (a, b) => (_int(a, 'seq') ?? 0).compareTo(_int(b, 'seq') ?? 0),
            );
      if (list.isEmpty) continue;
      buffer
        ..writeln('## ${_str(c, 'title').isEmpty ? '未命名会话' : _str(c, 'title')}')
        ..writeln()
        ..writeln('开始时间：${_fmtDate(_str(c, 'created_at'))}')
        ..writeln();
      for (final m in list) {
        final role = _str(m, 'role');
        final who = switch (role) {
          'user' => '你',
          'assistant' => '泡泡',
          _ => '系统',
        };
        buffer
          ..writeln('**$who**（${_fmtDate(_str(m, 'created_at'))}）：')
          ..writeln()
          ..writeln(_str(m, 'content'))
          ..writeln();
      }
    }
    return buffer.toString();
  }

  String _memoryMarkdown(Map<String, List<Map<String, Object?>>> tables) {
    final rows = _rows(tables, 'memories').where(_alive).toList()
      ..sort((a, b) => _str(b, 'created_at').compareTo(_str(a, 'created_at')));
    final buffer = StringBuffer()
      ..writeln('# 长期记忆')
      ..writeln()
      ..writeln('共 ${rows.length} 条')
      ..writeln();
    for (final m in rows) {
      final title = _str(m, 'title');
      buffer
        ..writeln('## ${title.isEmpty ? _str(m, 'summary') : title}')
        ..writeln()
        ..writeln(
          '- 类型：${_str(m, 'type')} · 状态：${_str(m, 'status')} · '
          '置信度：${_str(m, 'confidence')} · 重要度：${_int(m, 'importance') ?? 0}',
        )
        ..writeln('- 创建：${_fmtDate(_str(m, 'created_at'))}')
        ..writeln()
        ..writeln(_str(m, 'summary'))
        ..writeln();
      final body = _str(m, 'body');
      if (body.isNotEmpty) {
        buffer
          ..writeln(body)
          ..writeln();
      }
    }
    return buffer.toString();
  }

  String _postMarkdown(Map<String, List<Map<String, Object?>>> tables) {
    final rows = _rows(tables, 'posts').where(_alive).toList()
      ..sort(
        (a, b) => (_int(b, 'published_at') ?? 0).compareTo(
          _int(a, 'published_at') ?? 0,
        ),
      );
    final buffer = StringBuffer()
      ..writeln('# 说说')
      ..writeln()
      ..writeln('共 ${rows.length} 篇')
      ..writeln();
    for (final p in rows) {
      buffer
        ..writeln('## ${_fmtMs(_int(p, 'published_at'))}')
        ..writeln()
        ..writeln(
          '- 心情：${_str(p, 'mood')} · 主题：${_str(p, 'topic')} · '
          '来源：${_str(p, 'origin')}',
        )
        ..writeln()
        ..writeln(_str(p, 'content'))
        ..writeln();
    }
    return buffer.toString();
  }

  String _diaryMarkdown(Map<String, List<Map<String, Object?>>> tables) {
    final rows = _rows(tables, 'diaries').where(_alive).toList()
      ..sort((a, b) => _str(b, 'entry_date').compareTo(_str(a, 'entry_date')));
    final buffer = StringBuffer()
      ..writeln('# 日记')
      ..writeln()
      ..writeln('共 ${rows.length} 篇')
      ..writeln();
    for (final d in rows) {
      buffer
        ..writeln('## ${_str(d, 'entry_date')}')
        ..writeln()
        ..writeln('- 来源：${_str(d, 'origin')}')
        ..writeln()
        ..writeln(_str(d, 'content'))
        ..writeln();
    }
    return buffer.toString();
  }

  String _letterMarkdown(Map<String, List<Map<String, Object?>>> tables) {
    final rows = _rows(tables, 'letters').where(_alive).toList()
      ..sort(
        (a, b) => (_int(b, 'sent_at') ?? 0).compareTo(_int(a, 'sent_at') ?? 0),
      );
    final buffer = StringBuffer()
      ..writeln('# 信件')
      ..writeln()
      ..writeln('共 ${rows.length} 封')
      ..writeln();
    for (final l in rows) {
      final direction = _str(l, 'direction') == 'bubble_to_user'
          ? '泡泡 → 你'
          : '你 → 泡泡';
      buffer
        ..writeln('## ${_str(l, 'title').isEmpty ? '无题' : _str(l, 'title')}')
        ..writeln()
        ..writeln(
          '- $direction · 状态：${_str(l, 'state')} · '
          '寄出：${_fmtMs(_int(l, 'sent_at'))}',
        )
        ..writeln()
        ..writeln(_str(l, 'content'))
        ..writeln();
    }
    return buffer.toString();
  }

  String _experienceMarkdown(Map<String, List<Map<String, Object?>>> tables) {
    final rows = _rows(tables, 'shared_experiences').where(_alive).toList()
      ..sort(
        (a, b) => (_int(b, 'occurred_at') ?? 0).compareTo(
          _int(a, 'occurred_at') ?? 0,
        ),
      );
    final buffer = StringBuffer()
      ..writeln('# 共同经历')
      ..writeln()
      ..writeln('共 ${rows.length} 段')
      ..writeln();
    for (final e in rows) {
      buffer
        ..writeln('## ${_str(e, 'name')}')
        ..writeln()
        ..writeln(
          '- 发生时间：${_fmtMs(_int(e, 'occurred_at'))} · '
          '重要度：${_int(e, 'importance') ?? 0}',
        )
        ..writeln()
        ..writeln(_str(e, 'event_content'))
        ..writeln();
      final userView = _str(e, 'user_perspective');
      final bubbleView = _str(e, 'bubble_perspective');
      if (userView.isNotEmpty) {
        buffer
          ..writeln('> 你的视角：$userView')
          ..writeln();
      }
      if (bubbleView.isNotEmpty) {
        buffer
          ..writeln('> 泡泡的视角：$bubbleView')
          ..writeln();
      }
    }
    return buffer.toString();
  }
}
