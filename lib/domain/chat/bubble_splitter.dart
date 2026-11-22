// 连续多气泡拆分（T2.4）：把一次完整回复拆成多条独立气泡依次落库。
// 依据 UI_INTERACTION_SPEC §2.1「完成后按分段标记拆分为多条独立气泡，
// 依次落定（每条间隔 150ms）」与 TEST_PLAN §3「一次回复拆 N 条独立落库、seq 连续」。
library;

/// 句末标点（中英文）
const _sentenceEnds = {'。', '！', '？', '；', '!', '?', ';', '…'};

/// 把完整回复文本拆分为气泡段落（纯函数，可单测）。
///
/// 规则（按优先级）：
/// 1. 空行（两个及以上换行）是显式分段标记；
/// 2. 单段过长（超过 [softMaxLength] 字）时按句末标点二次拆分；
/// 3. 过短段落（少于 [minSegmentLength] 字）合并到前一段；
/// 4. 最终条数不超过 [maxSegments]，超出部分合并到最后一条。
List<String> splitReplySegments(
  String full, {
  int maxSegments = 4,
  int softMaxLength = 80,
  int minSegmentLength = 2,
}) {
  final text = full.trim();
  if (text.isEmpty) return const [];

  // 1) 显式分段
  var parts = text
      .split(RegExp(r'\n{2,}'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  // 2) 单段过长按句子拆
  if (parts.length == 1) {
    parts = _splitBySentences(parts.single, softMaxLength);
  } else {
    parts = [
      for (final p in parts)
        if (p.runes.length > softMaxLength) ..._splitBySentences(p, softMaxLength) else p,
    ];
  }

  // 3) 合并过短段落
  final merged = <String>[];
  for (final p in parts) {
    if (merged.isNotEmpty && p.runes.length < minSegmentLength) {
      merged[merged.length - 1] = '${merged.last}\n$p';
    } else {
      merged.add(p);
    }
  }

  // 4) 限制条数
  if (merged.length > maxSegments) {
    final head = merged.take(maxSegments - 1).toList();
    head.add(merged.skip(maxSegments - 1).join('\n\n'));
    return head;
  }
  return merged;
}

List<String> _splitBySentences(String text, int softMaxLength) {
  if (text.runes.length <= softMaxLength) return [text];

  final out = <String>[];
  final buf = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    buf.write(ch);
    final isEnd = _sentenceEnds.contains(ch) || ch == '\n';
    if (isEnd && buf.toString().trim().runes.length >= softMaxLength ~/ 2) {
      final seg = buf.toString().trim();
      if (seg.isNotEmpty) out.add(seg);
      buf.clear();
    }
  }
  final rest = buf.toString().trim();
  if (rest.isNotEmpty) {
    // 剩余段过长且无标点：硬切（避免单条气泡超长）
    if (rest.runes.length > softMaxLength * 2) {
      final runes = rest.runes.toList();
      for (var i = 0; i < runes.length; i += softMaxLength) {
        out.add(String.fromCharCodes(
            runes.skip(i).take(softMaxLength)));
      }
    } else {
      out.add(rest);
    }
  }
  return out.isEmpty ? [text] : out;
}
