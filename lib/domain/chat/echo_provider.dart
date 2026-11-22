// 开发用回声模型（T2.2/T2.4 联调用）：不产生真实智能，仅模拟流式输出与分段。
// 依据 ROADMAP 阶段 2「EchoProvider 假模型仅用于开发，交付前移除，不冒充真功能」。
// UI 依据 isMock 在聊天页顶部常驻「开发模式」提示条，禁止伪装为真实模型。
import 'dart:async';

import 'chat_provider.dart';

class EchoProvider extends ChatCompletionProvider {
  const EchoProvider({this.chunkDelay = const Duration(milliseconds: 18)});

  /// 每个分片间隔（测试可传 Duration.zero 加速）
  final Duration chunkDelay;

  @override
  String get providerId => 'echo';

  @override
  String get displayName => '本地回声（开发用）';

  @override
  bool get isMock => true;

  @override
  Stream<String> stream(List<ChatTurn> history) async* {
    final lastUser = history.lastWhere(
      (t) => t.role == 'user',
      orElse: () => const ChatTurn(role: 'user', content: ''),
    );
    // 历史最后一条是助手（继续场景）→ 输出续写段落
    final isContinuation =
        history.isNotEmpty && history.last.role == 'assistant';

    final reply = isContinuation
        ? _continuationReply(lastUser.content)
        : _normalReply(lastUser.content);

    final segments = reply.split('\n\n');
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) {
        await Future<void>.delayed(chunkDelay);
        yield '\n\n';
      }
      final runes = segments[i].runes.toList();
      for (var j = 0; j < runes.length; j += 6) {
        await Future<void>.delayed(chunkDelay);
        yield String.fromCharCodes(runes.skip(j).take(6));
      }
    }
  }

  String _normalReply(String userText) {
    final quoted = _clip(userText, 24);
    return '嗯，我在听。\n\n'
        '你说「$quoted」，我记下啦。\n\n'
        '这是本地回声模型的占位回复，真实回答会在接入 DeepSeek 后启用。';
  }

  String _continuationReply(String userText) {
    final quoted = _clip(userText, 16);
    return '接着刚才的话说下去——\n\n'
        '关于「$quoted」，我还有一些想补充的。\n\n'
        '（开发模式回声：续写内容为占位）';
  }

  String _clip(String text, int maxRunes) {
    final trimmed = text.trim();
    final runes = trimmed.runes.toList();
    if (runes.length <= maxRunes) return trimmed;
    return '${String.fromCharCodes(runes.take(maxRunes))}…';
  }
}
