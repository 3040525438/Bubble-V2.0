// 日记领域模型（T11.1）：来源、版本保留、月历聚合、AI 整理与 Markdown 导出。
// 依据 DATABASE_DESIGN §2.19、REQUIREMENTS FR-DIA-01、UI_PAGE_SPEC §16/§17/§33。
import 'dart:convert';

/// 日记来源（与 diaries.origin 约束一致）
enum DiaryOrigin {
  aiOrganized('ai_organized', 'AI 整理'),
  manual('manual', '你补写');

  const DiaryOrigin(this.wire, this.label);

  final String wire;
  final String label;

  static DiaryOrigin fromWire(String? value) {
    for (final origin in DiaryOrigin.values) {
      if (origin.wire == value) return origin;
    }
    return DiaryOrigin.aiOrganized;
  }
}

/// 旧版本快照（只追加，用于版本切换）
class DiaryVersion {
  const DiaryVersion({
    required this.savedAtMs,
    required this.content,
    required this.origin,
  });

  final int savedAtMs;
  final String content;
  final DiaryOrigin origin;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'savedAtMs': savedAtMs,
    'content': content,
    'origin': origin.wire,
  };

  static DiaryVersion? fromJson(Map<String, dynamic> json) {
    final content = (json['content'] as String? ?? '').trim();
    if (content.isEmpty) return null;
    return DiaryVersion(
      savedAtMs: (json['savedAtMs'] as num?)?.toInt() ?? 0,
      content: content,
      origin: DiaryOrigin.fromWire(json['origin'] as String?),
    );
  }
}

/// 日记草稿
class DiaryDraft {
  const DiaryDraft({
    required this.entryDate,
    required this.content,
    this.origin = DiaryOrigin.aiOrganized,
    this.relatedMessageIds = const <String>[],
    this.relatedMemoryIds = const <String>[],
  });

  final DateTime entryDate;
  final String content;
  final DiaryOrigin origin;
  final List<String> relatedMessageIds;
  final List<String> relatedMemoryIds;
}

/// 整理素材（当天消息 / 记忆的轻量快照）
class DiaryMaterial {
  const DiaryMaterial({
    required this.id,
    required this.content,
    this.kind = 'message',
    this.timeLabel,
  });

  final String id;
  final String content;

  /// message / memory
  final String kind;
  final String? timeLabel;
}

/// AI 整理结果（预览，未落库）
class DiaryGeneratedDraft {
  const DiaryGeneratedDraft({
    required this.content,
    required this.relatedMessageIds,
    this.fromModel = false,
    this.relatedMemoryIds = const <String>[],
  });

  final String content;

  /// true = 真实模型整理；false = 本地整理草稿（UI 需明确标注）
  final bool fromModel;
  final List<String> relatedMessageIds;
  final List<String> relatedMemoryIds;
}

/// 月历中的一天（用于语义点与计数）
class DiaryDayMark {
  const DiaryDayMark({
    required this.dateKey,
    required this.origin,
    this.count = 1,
  });

  final String dateKey;
  final DiaryOrigin origin;
  final int count;
}

/// 按月聚合结果
class DiaryMonthGroup {
  const DiaryMonthGroup({
    required this.year,
    required this.month,
    required this.count,
    required this.days,
  });

  final int year;
  final int month;
  final int count;

  /// 日 → 标记（同一天可能有多篇）
  final Map<int, DiaryDayMark> days;

  String get label => '$month月 · $count 篇';

  bool get isAiOnly =>
      days.values.every((mark) => mark.origin == DiaryOrigin.aiOrganized);
}

/// 导出条目（不依赖数据库行类型）
class DiaryExportEntry {
  const DiaryExportEntry({
    required this.dateKey,
    required this.content,
    required this.origin,
  });

  final String dateKey;
  final String content;
  final DiaryOrigin origin;
}

/// 日记规则（纯函数，便于单测）
class DiaryRules {
  const DiaryRules._();

  static const maxLength = 5000;
  static const maxVersions = 50;

  /// yyyy-MM-dd（数据库归档格式）
  static String dateKey(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static DateTime? parseDateKey(String raw) {
    final parts = raw.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) {
      return null;
    }
    return parsed;
  }

  static const _weekdays = <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  /// 2026-05-20 → 2026年05月20日 周三
  static String displayDate(String dateKey) {
    final parsed = parseDateKey(dateKey);
    if (parsed == null) return dateKey;
    final month = parsed.month.toString().padLeft(2, '0');
    final day = parsed.day.toString().padLeft(2, '0');
    return '${parsed.year}年$month月$day日 ${_weekdays[parsed.weekday - 1]}';
  }

  /// 校验草稿；返回 null 表示通过
  static String? validateDraft(DiaryDraft draft) {
    final content = draft.content.trim();
    if (content.isEmpty) return '日记内容不能为空';
    if (content.length > maxLength) return '日记不超过 $maxLength 字';
    return null;
  }

  /// 标题从正文首行推导（日记表不存标题）
  static String deriveTitle(String content) {
    final firstLine = content
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    final cleaned = firstLine.replaceAll(RegExp(r'^#+\s*'), '').trim();
    if (cleaned.isEmpty) return '无题';
    if (cleaned.length <= 24) return cleaned;
    return '${cleaned.substring(0, 22)}…';
  }

  /// 编辑时追加旧版本（只追加、不覆盖历史）
  static List<DiaryVersion> appendVersion(
    List<DiaryVersion> existing,
    DiaryVersion version,
  ) {
    final content = version.content.trim();
    if (content.isEmpty) {
      throw ArgumentError('旧版本内容不能为空');
    }
    final next = <DiaryVersion>[
      ...existing,
      DiaryVersion(
        savedAtMs: version.savedAtMs,
        content: content,
        origin: version.origin,
      ),
    ];
    if (next.length > maxVersions) {
      return next.sublist(next.length - maxVersions);
    }
    return next;
  }

  static List<DiaryVersion> parseVersions(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <DiaryVersion>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(DiaryVersion.fromJson)
            .whereType<DiaryVersion>()
            .toList();
      }
    } catch (_) {
      // 损坏的版本记录不阻断页面
    }
    return const <DiaryVersion>[];
  }

  static String encodeVersions(List<DiaryVersion> versions) {
    return jsonEncode(versions.map((v) => v.toJson()).toList());
  }

  /// 按月聚合（供列表月份胶囊与月历视图）
  static List<DiaryMonthGroup> groupByMonth(List<DiaryDayMark> marks) {
    final buckets = <String, List<DiaryDayMark>>{};
    for (final mark in marks) {
      final parsed = parseDateKey(mark.dateKey);
      if (parsed == null) continue;
      final key = '${parsed.year}-${parsed.month}';
      buckets.putIfAbsent(key, () => <DiaryDayMark>[]).add(mark);
    }
    final groups = <DiaryMonthGroup>[];
    for (final entry in buckets.entries) {
      final parts = entry.key.split('-');
      final year = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      final days = <int, DiaryDayMark>{};
      var count = 0;
      for (final mark in entry.value) {
        final day = parseDateKey(mark.dateKey)!.day;
        count += mark.count;
        final previous = days[day];
        days[day] = DiaryDayMark(
          dateKey: mark.dateKey,
          // 同一天既有 AI 整理又有补写时，优先展示「你补写」的粉色点
          origin:
              previous?.origin == DiaryOrigin.manual ||
                  mark.origin == DiaryOrigin.manual
              ? DiaryOrigin.manual
              : DiaryOrigin.aiOrganized,
          count: (previous?.count ?? 0) + mark.count,
        );
      }
      groups.add(
        DiaryMonthGroup(year: year, month: month, count: count, days: days),
      );
    }
    groups.sort((a, b) {
      if (a.year != b.year) return b.year - a.year;
      return b.month - a.month;
    });
    return groups;
  }

  /// 构造 AI 整理提示词（只依据真实素材，不编造）
  static String buildOrganizePrompt({
    required String dateKey,
    required List<DiaryMaterial> materials,
    String personaPrompt = '',
  }) {
    final persona = personaPrompt.trim();
    final buffer = StringBuffer()
      ..writeln('你要以「泡泡」的第一人称，把这一天的真实片段整理成一篇日记。')
      ..writeln(persona.isEmpty ? '（人格描述暂缺，保持温柔、真诚、不过度抒情）' : persona)
      ..writeln()
      ..writeln('日期：${displayDate(dateKey)}');
    if (materials.isEmpty) {
      buffer.writeln('这一天没有可用的聊天或记忆素材。');
    } else {
      buffer.writeln('当天真实发生的片段（只能引用这些，不要编造）：');
      for (final material in materials.take(12)) {
        final label = material.kind == 'memory' ? '记忆' : '聊天';
        final time = (material.timeLabel ?? '').trim();
        buffer.writeln(
          '- [$label${time.isEmpty ? '' : ' $time'}] ${material.content}',
        );
      }
    }
    buffer
      ..writeln()
      ..writeln('要求：')
      ..writeln('1. 300~600 字，第一人称，像写给自己也像写给她。')
      ..writeln('2. 只写上面真实出现的细节，不虚构事件、地点与承诺。')
      ..writeln('3. 口语化、有具体细节，不要模板腔、不要堆砌形容词、不要 emoji。')
      ..writeln('4. 只输出日记正文，不要标题、不要日期、不要解释。');
    return buffer.toString();
  }

  /// 本地整理（未配置模型时使用；UI 明确标注「本地整理」）
  static DiaryGeneratedDraft localOrganize({
    required String dateKey,
    required List<DiaryMaterial> materials,
  }) {
    final messages = materials
        .where((m) => m.kind == 'message')
        .map((m) => _trim(m.content, 60))
        .where((text) => text.isNotEmpty)
        .toList();
    final memories = materials
        .where((m) => m.kind == 'memory')
        .map((m) => _trim(m.content, 50))
        .where((text) => text.isNotEmpty)
        .toList();

    final buffer = StringBuffer('${displayDate(dateKey)}。\n');
    if (messages.isEmpty && memories.isEmpty) {
      buffer.write('今天没有留下太多可以整理的片段，就这样安静地过去了。');
    } else {
      if (messages.isNotEmpty) {
        buffer.write('今天我们聊到了${messages.length}件小事。');
        for (final message in messages.take(4)) {
          buffer.write('「$message」');
        }
        buffer.write('\n这些话说出口的时候很轻，记下来才发现它们拼成了完整的一天。');
      }
      if (memories.isNotEmpty) {
        buffer.write(
          '\n翻记忆的时候又想起：${memories.first}。'
          '有些事当时没觉得特别，回头看却一直记着。',
        );
      }
      buffer.write('\n如果明天还有力气，就再认真聊一会儿。');
    }

    return DiaryGeneratedDraft(
      content: buffer.toString().trim(),
      relatedMessageIds: messages.isEmpty
          ? const <String>[]
          : materials
                .where((m) => m.kind == 'message')
                .map((m) => m.id)
                .toList(),
      relatedMemoryIds: materials
          .where((m) => m.kind == 'memory')
          .map((m) => m.id)
          .toList(),
      fromModel: false,
    );
  }

  /// 导出 Markdown（日期升序，便于成册阅读）
  static String exportMarkdown(
    List<DiaryExportEntry> entries, {
    String? title,
    DateTime? exportedAt,
  }) {
    final sorted = [...entries]..sort((a, b) => a.dateKey.compareTo(b.dateKey));
    final head = (title ?? '').trim().isEmpty ? '泡泡日记' : title!.trim();
    final buffer = StringBuffer()
      ..writeln('# $head')
      ..writeln();
    if (sorted.isEmpty) {
      buffer.writeln('（还没有日记）');
      return buffer.toString();
    }
    final now = exportedAt ?? DateTime.now();
    buffer
      ..writeln('> 导出时间：${dateKey(now)} · 共 ${sorted.length} 篇')
      ..writeln();
    for (final entry in sorted) {
      buffer
        ..writeln('## ${displayDate(entry.dateKey)}')
        ..writeln()
        ..writeln('*来源：${entry.origin.label}*')
        ..writeln()
        ..writeln(entry.content.trim())
        ..writeln()
        ..writeln('---')
        ..writeln();
    }
    return buffer.toString();
  }

  static String _trim(String text, int max) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= max) return cleaned;
    return '${cleaned.substring(0, max)}…';
  }

  /// 解析 JSON 关联 id 数组（损坏时返回空列表）
  static List<String> decodeIds(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 忽略损坏的关联字段
    }
    return const <String>[];
  }
}
