// 时间展示工具（T2.2）：相对时间与会话内时间分隔条判定。
// 不依赖 intl 的 locale 初始化，避免启动期额外开销。
library;

String _two(int n) => n.toString().padLeft(2, '0');

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

bool _isYesterday(DateTime t, DateTime now) {
  final y = DateTime(now.year, now.month, now.day)
      .subtract(const Duration(days: 1));
  return _isSameDay(t, y);
}

/// 会话列表时间：今天 HH:mm / 昨天 / 今年 M月d日 / 更早 yyyy/M/d
String formatConversationTime(int? millis) {
  if (millis == null) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
  final now = DateTime.now();
  if (_isSameDay(t, now)) return '${_two(t.hour)}:${_two(t.minute)}';
  if (_isYesterday(t, now)) return '昨天';
  if (t.year == now.year) return '${t.month}月${t.day}日';
  return '${t.year}/${t.month}/${t.day}';
}

/// 聊天内时间分隔条文案：HH:mm / 昨天 HH:mm / M月d日 HH:mm / yyyy年M月d日 HH:mm
String formatMessageTimestamp(String iso) {
  final t = DateTime.tryParse(iso)?.toLocal();
  if (t == null) return '';
  final now = DateTime.now();
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  if (_isSameDay(t, now)) return hm;
  if (_isYesterday(t, now)) return '昨天 $hm';
  if (t.year == now.year) return '${t.month}月${t.day}日 $hm';
  return '${t.year}年${t.month}月${t.day}日 $hm';
}

/// 是否需要在两条消息之间插入时间分隔条（跨天或间隔 ≥ 5 分钟）。
bool needsTimeDivider(DateTime? previous, DateTime current) {
  if (previous == null) return true;
  if (!_isSameDay(previous, current)) return true;
  return current.difference(previous).inMinutes >= 5;
}
