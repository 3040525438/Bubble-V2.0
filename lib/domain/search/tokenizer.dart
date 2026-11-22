// bigram 分词器与相似度（T1.4）：domain 层纯函数，无 IO（ADR-1/ADR-2）。
// 依据 DATABASE_DESIGN §2.30：
// - CJK 单字 + 相邻双字（bigram）；拉丁字母/数字连续串作为整词（小写化）
// - 检索相似度 = 重叠系数 |A∩B|/min(|A|,|B|)，只用 ≥2 字 token 与拉丁词
// - 索引是派生数据，可全量重建（FR-MEM-06）
library;

/// 判断是否 CJK 字符（汉字基本区+扩展A，覆盖常用中文）
bool _isCjk(int code) {
  return (code >= 0x4E00 && code <= 0x9FFF) ||
      (code >= 0x3400 && code <= 0x4DBF);
}

/// 判断是否拉丁字母或数字（检索词元）
bool _isLatinOrDigit(int code) {
  return (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      (code >= 0x30 && code <= 0x39);
}

/// 分词：返回 token 列表（含重复，写入倒排时按 (token, doc) 去重取权重）。
///
/// 规则：
/// - 全文小写化
/// - CJK：每个单字 + 每对相邻双字
/// - 拉丁/数字：连续串为一个整词
/// - 其他字符（空白/标点/emoji）为分隔符
/// - 空输入返回空列表
List<String> tokenize(String text) {
  final tokens = <String>[];
  if (text.isEmpty) return tokens;

  final lower = text.toLowerCase();
  final sb = StringBuffer();
  for (var i = 0; i < lower.length; i++) {
    final c = lower.codeUnitAt(i);
    if (_isCjk(c) || _isLatinOrDigit(c)) {
      sb.writeCharCode(c);
    } else {
      sb.write(' ');
    }
  }

  for (final seg in sb.toString().split(' ')) {
    if (seg.isEmpty) continue;
    final runes = seg.runes.toList();
    var i = 0;
    while (i < runes.length) {
      if (_isCjk(runes[i])) {
        tokens.add(String.fromCharCode(runes[i])); // 单字
        if (i + 1 < runes.length && _isCjk(runes[i + 1])) {
          tokens.add(String.fromCharCodes([runes[i], runes[i + 1]])); // 双字
        }
        i++;
      } else if (_isLatinOrDigit(runes[i])) {
        // 连续拉丁/数字整词
        var j = i;
        final word = StringBuffer();
        while (j < runes.length && _isLatinOrDigit(runes[j])) {
          word.writeCharCode(runes[j]);
          j++;
        }
        tokens.add(word.toString());
        i = j;
      } else {
        i++;
      }
    }
  }
  return tokens;
}

/// 用于相似度计算的 token 集合：仅 ≥2 字 CJK token 与拉丁词（DATABASE_DESIGN §2.30）。
Set<String> similarityTokens(String text) {
  return tokenize(text).where((t) {
    if (t.isEmpty) return false;
    final first = t.runes.first;
    if (_isCjk(first)) return t.runes.length >= 2; // CJK 需 ≥2 字
    return true; // 拉丁词直接用
  }).toSet();
}

/// 重叠系数 |A∩B|/min(|A|,|B|)；任一为空返回 0。
double overlapCoefficient(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final intersection = a.intersection(b).length;
  final minSize = a.length < b.length ? a.length : b.length;
  return intersection / minSize;
}
