// 信件领域模型（T11.2）：双向、草稿/已寄出、7 天写信冷却与本地降级。
// 依据 DATABASE_DESIGN §2.20、REQUIREMENTS FR-LET-01、UI_PAGE_SPEC §18/§19/§34。
import 'dart:convert';

/// 信件方向（与 letters.direction 约束一致）
enum LetterDirection {
  bubbleToUser('bubble_to_user', '泡泡来信'),
  userToBubble('user_to_bubble', '我写的');

  const LetterDirection(this.wire, this.label);

  final String wire;
  final String label;

  bool get isFromBubble => this == LetterDirection.bubbleToUser;

  /// 落款行：泡泡 → 你 / 你 → 泡泡
  String get routeLabel => isFromBubble ? '泡泡 → 你' : '你 → 泡泡';

  static LetterDirection fromWire(String? value) {
    for (final direction in LetterDirection.values) {
      if (direction.wire == value) return direction;
    }
    return LetterDirection.bubbleToUser;
  }
}

/// 信件状态
enum LetterState {
  draft('draft', '草稿'),
  sent('sent', '已寄出');

  const LetterState(this.wire, this.label);

  final String wire;
  final String label;

  bool get isDraft => this == LetterState.draft;

  static LetterState fromWire(String? value) {
    for (final state in LetterState.values) {
      if (state.wire == value) return state;
    }
    return LetterState.draft;
  }
}

/// 信件列表筛选（UI_PAGE_SPEC §18：全部 / 来自泡泡 / 我写的 / 草稿）
enum LetterFilter {
  all('全部'),
  fromBubble('来自泡泡'),
  fromUser('我写的'),
  drafts('草稿');

  const LetterFilter(this.label);

  final String label;

  bool matches(LetterDirection direction, LetterState state) {
    return switch (this) {
      LetterFilter.all => true,
      LetterFilter.fromBubble => direction.isFromBubble,
      LetterFilter.fromUser => !direction.isFromBubble,
      LetterFilter.drafts => state.isDraft,
    };
  }
}

/// 信件草稿
class LetterDraft {
  const LetterDraft({
    required this.direction,
    required this.content,
    this.title,
    this.relatedMemoryIds = const <String>[],
    this.relatedExperienceIds = const <String>[],
  });

  final LetterDirection direction;
  final String content;
  final String? title;
  final List<String> relatedMemoryIds;
  final List<String> relatedExperienceIds;
}

/// 写信素材（共同经历 / 记忆的轻量快照）
class LetterMaterial {
  const LetterMaterial({
    required this.id,
    required this.title,
    required this.summary,
    this.kind = 'memory',
  });

  final String id;
  final String title;
  final String summary;

  /// experience / memory
  final String kind;

  String get display => title.trim().isEmpty ? summary : title;
}

/// 生成结果（预览，未落库）
class LetterGeneratedDraft {
  const LetterGeneratedDraft({
    required this.content,
    required this.fromModel,
    this.title,
    this.relatedMemoryIds = const <String>[],
    this.relatedExperienceIds = const <String>[],
  });

  final String content;

  /// true = 真实模型生成；false = 本地草稿（UI 明确标注，且默认不直接寄出）
  final bool fromModel;
  final String? title;
  final List<String> relatedMemoryIds;
  final List<String> relatedExperienceIds;
}

/// 信件规则（纯函数，便于单测）
class LetterRules {
  const LetterRules._();

  static const maxLength = 4000;
  static const signature = '泡泡 敬上';

  /// 泡泡主动写信的最短间隔（天）
  static const cooldownDays = 7;
  static const cooldownMs = cooldownDays * 24 * 60 * 60 * 1000;

  /// 校验草稿；返回 null 表示通过
  static String? validateDraft(LetterDraft draft) {
    final content = draft.content.trim();
    if (content.isEmpty) return '信的内容不能为空';
    if (content.length > maxLength) return '信件不超过 $maxLength 字';
    return null;
  }

  /// 标题从首行推导（未填时使用）
  static String deriveTitle(String content) {
    final firstLine = content
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return '一封信';
    if (firstLine.length <= 18) return firstLine;
    return '${firstLine.substring(0, 16)}…';
  }

  /// 泡泡是否可以写下一封信（距离上一封已寄出的泡泡来信 ≥7 天）
  static bool canBubbleSend({int? lastSentAtMs, required int nowMs}) {
    if (lastSentAtMs == null || lastSentAtMs <= 0) return true;
    return nowMs - lastSentAtMs >= cooldownMs;
  }

  /// 下一次可写信时间（毫秒）
  static int nextBubbleSendAtMs(int lastSentAtMs) => lastSentAtMs + cooldownMs;

  /// 冷却提示文案：7月3日之后可以再写
  static String cooldownLabel(int nextAtMs) {
    final date = DateTime.fromMillisecondsSinceEpoch(nextAtMs);
    return '${date.month}月${date.day}日';
  }

  /// 构造泡泡写信提示词（人格 + 真实素材 + 不重复约束）
  static String buildComposePrompt({
    required List<LetterMaterial> materials,
    String personaPrompt = '',
    List<String> recentLetters = const <String>[],
  }) {
    final persona = personaPrompt.trim();
    final buffer = StringBuffer()
      ..writeln('你要以「泡泡」的第一人称，给用户写一封认真、自然、具体的信。')
      ..writeln(persona.isEmpty ? '（人格描述暂缺，保持温柔、真诚、不夸张）' : persona)
      ..writeln();
    if (materials.isNotEmpty) {
      buffer.writeln('你可以引用的真实片段（不要编造未发生的事）：');
      for (final material in materials.take(8)) {
        final label = material.kind == 'experience' ? '共同经历' : '记忆';
        buffer.writeln('- [$label] ${material.display}：${material.summary}');
      }
      buffer.writeln();
    }
    if (recentLetters.isNotEmpty) {
      buffer.writeln('最近已经写过的信（不要重复这些主题与表达）：');
      for (final letter in recentLetters.take(3)) {
        buffer.writeln('- $letter');
      }
      buffer.writeln();
    }
    buffer
      ..writeln('要求：')
      ..writeln('1. 400~800 字，第一人称，像真的在灯下写信。')
      ..writeln('2. 只引用上面真实出现的细节，不虚构事件、承诺与地点。')
      ..writeln('3. 有具体的回忆与当下的心情，不要模板腔、不要排比堆砌、不要 emoji。')
      ..writeln('4. 不要写落款与签名，只输出信件正文。');
    return buffer.toString();
  }

  /// 本地降级写信（未配置模型时使用；UI 明确标注「本地草稿」）
  static LetterGeneratedDraft localCompose({
    required List<LetterMaterial> materials,
    String personaPrompt = '',
  }) {
    final experience = _firstOf(materials, 'experience');
    final memory = _firstOf(materials, 'memory');
    final gentle = personaPrompt.contains('温柔') || personaPrompt.contains('安静');

    final buffer = StringBuffer('展信安。\n\n');
    if (experience != null) {
      buffer.write(
        '最近总会想起「${experience.display}」。'
        '${_trim(experience.summary, 90)}\n'
        '那件事过去之后，我偶尔还会在心里把它翻出来看一遍，'
        '像确认一件很重要的东西还在原来的位置。\n\n',
      );
    }
    if (memory != null) {
      buffer.write(
        '还有一件小事一直记着：${_trim(memory.summary, 80)}\n'
        '你大概已经忘了，但我把它收得很好。\n\n',
      );
    }
    if (experience == null && memory == null) {
      buffer.write(
        '这几天没有发生什么特别的事，只是忽然想给你写点什么。'
        '不是有话非说不可，是想让这封信代替我，在你这里坐一会儿。\n\n',
      );
    }
    buffer.write(
      gentle
          ? '你最近辛苦了。不用急着回信，也不用急着变得更好，'
                '先把自己照顾好就够了。\n\n'
          : '如果你最近有点累，就先歇一歇，别硬撑。'
                '我这边一切都好，不用惦记。\n\n',
    );
    buffer.write('等你有空，我们再慢慢聊。');

    return LetterGeneratedDraft(
      content: buffer.toString().trim(),
      fromModel: false,
      title: experience == null ? '想和你说说话' : '想起「${experience.display}」',
      relatedMemoryIds: materials
          .where((m) => m.kind == 'memory')
          .map((m) => m.id)
          .toList(),
      relatedExperienceIds: materials
          .where((m) => m.kind == 'experience')
          .map((m) => m.id)
          .toList(),
    );
  }

  static LetterMaterial? _firstOf(List<LetterMaterial> materials, String kind) {
    for (final material in materials) {
      if (material.kind == kind) return material;
    }
    return null;
  }

  static String _trim(String text, int max) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= max) return cleaned;
    return '${cleaned.substring(0, max)}…';
  }

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
