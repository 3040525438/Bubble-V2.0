// 工程健康检查冒烟测试（阶段 1 骨架版）
import 'package:bubble/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('应用骨架可渲染', (tester) async {
    await tester.pumpWidget(const BubbleApp());
    expect(find.text('泡泡 Bubble V2.0 · 阶段 1 骨架'), findsOneWidget);
  });
}
