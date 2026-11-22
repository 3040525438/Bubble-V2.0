// 中文友好的文本相似度工具（0~1）：去标点后按 bigram Jaccard 计算。
// 被主动决策去重与说说去重共用，保持同一判重口径。
Set<String> textBigrams(String text) {
  final cleaned = text.toLowerCase().replaceAll(
    RegExp(
      r'[\s，。！？、；：""'
      '（）()\[\]{}<>《》,.!?;:~`—…-]',
    ),
    '',
  );
  final chars = cleaned.runes.map(String.fromCharCode).toList();
  if (chars.length < 2) return chars.isEmpty ? <String>{} : chars.toSet();
  final result = <String>{};
  for (var i = 0; i < chars.length - 1; i++) {
    result.add('${chars[i]}${chars[i + 1]}');
  }
  return result;
}

double contentSimilarity(String a, String b) {
  final setA = textBigrams(a);
  final setB = textBigrams(b);
  if (setA.isEmpty || setB.isEmpty) return 0;
  final intersection = setA.intersection(setB).length;
  final union = setA.union(setB).length;
  if (union == 0) return 0;
  return intersection / union;
}
