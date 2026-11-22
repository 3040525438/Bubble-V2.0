// 工程健康检查冒烟测试（阶段 1 骨架版）
import 'package:bubble/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('应用骨架可渲染（主 Shell + 首个 Tab）', (tester) async {
    await tester.pumpWidget(const BubbleApp());
    await tester.pumpAndSettle();
    expect(find.text('消息（阶段 2）'), findsOneWidget);
    expect(find.text('消息'), findsWidgets); // 底部导航 Tab
  });
}
