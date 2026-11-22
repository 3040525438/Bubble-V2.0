// 全局搜索纯模型（T14.1）：六域、命中、分组与高亮片段。
// 依据 UI_PAGE_SPEC §20 与 FR-MISC-03；本文件不依赖 Flutter/Drift，可纯单测。
library;

/// 参与全局搜索的六个数据域。
enum SearchDomain {
  chat('chat', '聊天'),
  memory('memory', '记忆'),
  post('post', '说说'),
  diary('diary', '日记'),
  letter('letter', '信件'),
  experience('experience', '经历'),
  attachment('attachment', '图片');

  const SearchDomain(this.wire, this.label);

  final String wire;
  final String label;

  static SearchDomain? fromWire(String? value) {
    for (final d in SearchDomain.values) {
      if (d.wire == value) return d;
    }
    return null;
  }
}

/// 页面展示分区：日记/信件/经历合并为一组（UI_PAGE_SPEC §20 的「日记·信件·经历」）。
enum SearchSection {
  chat('聊天', [SearchDomain.chat]),
  memory('记忆', [SearchDomain.memory]),
  post('说说', [SearchDomain.post]),
  journal('日记·信件·经历', [
    SearchDomain.diary,
    SearchDomain.letter,
    SearchDomain.experience,
  ]),
  attachment('图片', [SearchDomain.attachment]);

  const SearchSection(this.label, this.domains);

  final String label;
  final List<SearchDomain> domains;

  static SearchSection? of(SearchDomain domain) {
    for (final s in SearchSection.values) {
      if (s.domains.contains(domain)) return s;
    }
    return null;
  }
}

/// 单条命中：标题、片段与锚点路径。
class SearchHit {
  const SearchHit({
    required this.domain,
    required this.docId,
    required this.title,
    required this.snippet,
    required this.anchorPath,
    this.score = 0,
    this.subtitle,
  });

  final SearchDomain domain;
  final String docId;
  final String title;
  final String snippet;

  /// 点击跳转的 GoRouter 路径；为空表示不可跳转（仅展示）。
  final String anchorPath;
  final double score;

  /// 可选副标题（如会话标题、日期）。
  final String? subtitle;

  SearchSection? get section => SearchSection.of(domain);
}

/// 某分区内的命中集合。
class SearchSectionResult {
  const SearchSectionResult({required this.section, required this.hits});

  final SearchSection section;
  final List<SearchHit> hits;

  int get count => hits.length;
}

/// 一次搜索的完整结果。
class GlobalSearchResult {
  const GlobalSearchResult({
    required this.query,
    required this.sections,
    required this.elapsedMs,
    this.indexWasEmpty = false,
  });

  final String query;
  final List<SearchSectionResult> sections;
  final int elapsedMs;

  /// 索引为空并触发了自动重建。
  final bool indexWasEmpty;

  int get total => sections.fold(0, (sum, s) => sum + s.count);

  bool get isEmpty => total == 0;

  static GlobalSearchResult empty(String query) =>
      GlobalSearchResult(query: query, sections: const [], elapsedMs: 0);
}

/// 生成命中片段：围绕第一个命中词截取窗口，并保留前后省略号。
String buildSnippet(
  String content,
  String query, {
  int window = 38,
  int maxLength = 90,
}) {
  final text = content.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return '';
  final lower = text.toLowerCase();
  final q = query.trim().toLowerCase();
  var index = q.isEmpty ? -1 : lower.indexOf(q);
  if (index < 0) {
    // 退化为任意非空片段
    return text.length <= maxLength ? text : '${text.substring(0, maxLength)}…';
  }
  final start = (index - window).clamp(0, text.length);
  final end = (index + q.length + window).clamp(0, text.length);
  final prefix = start > 0 ? '…' : '';
  final suffix = end < text.length ? '…' : '';
  var snippet = '$prefix${text.substring(start, end)}$suffix';
  if (snippet.length > maxLength + 2) {
    snippet = '${snippet.substring(0, maxLength)}…';
  }
  return snippet;
}

/// 把文本按查询词切分为高亮片段（[HighlightSpan.hit] 为 true 表示命中）。
List<HighlightSpan> highlightSpans(String text, List<String> terms) {
  final cleaned =
      terms.map((t) => t.trim()).where((t) => t.isNotEmpty).toSet().toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  if (cleaned.isEmpty || text.isEmpty) {
    return [HighlightSpan(text, false)];
  }
  final lower = text.toLowerCase();
  final ranges = <({int start, int end})>[];
  for (final term in cleaned) {
    final t = term.toLowerCase();
    var from = 0;
    while (true) {
      final index = lower.indexOf(t, from);
      if (index < 0) break;
      ranges.add((start: index, end: index + t.length));
      from = index + t.length;
    }
  }
  if (ranges.isEmpty) return [HighlightSpan(text, false)];
  ranges.sort((a, b) => a.start.compareTo(b.start));

  final spans = <HighlightSpan>[];
  var cursor = 0;
  for (final r in ranges) {
    if (r.start < cursor) continue;
    if (r.start > cursor) {
      spans.add(HighlightSpan(text.substring(cursor, r.start), false));
    }
    spans.add(HighlightSpan(text.substring(r.start, r.end), true));
    cursor = r.end;
  }
  if (cursor < text.length) {
    spans.add(HighlightSpan(text.substring(cursor), false));
  }
  return spans;
}

/// 高亮片段。
class HighlightSpan {
  const HighlightSpan(this.text, this.hit);

  final String text;
  final bool hit;
}
