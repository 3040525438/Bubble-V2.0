// 测试用假聊天模型（可切换失败 / 手动控制流）
import 'dart:async';

import 'package:bubble/domain/chat/chat_provider.dart';

/// 立即产出的假模型：按 segments 顺序输出（空行分隔 → 拆分多气泡）
class FakeProvider extends ChatCompletionProvider {
  FakeProvider({
    this.segments = const ['第一段回复内容', '第二段回复内容'],
    this.shouldFail = false,
  });

  final List<String> segments;
  bool shouldFail;
  int calls = 0;

  @override
  String get providerId => 'fake';

  @override
  String get displayName => '测试假模型';

  @override
  bool get isMock => true;

  @override
  Stream<String> stream(List<ChatTurn> history) async* {
    calls++;
    if (shouldFail) throw StateError('mock network down');
    for (var i = 0; i < segments.length; i++) {
      if (i > 0) yield '\n\n';
      yield segments[i];
    }
  }
}

/// 手动可控流：测试通过 controllers.last 主动推入分片/错误/关闭
class ManualProvider extends ChatCompletionProvider {
  final List<StreamController<String>> controllers = [];

  @override
  String get providerId => 'manual';

  @override
  String get displayName => '手动假模型';

  @override
  bool get isMock => true;

  @override
  Stream<String> stream(List<ChatTurn> history) {
    final controller = StreamController<String>();
    controllers.add(controller);
    return controller.stream;
  }
}
