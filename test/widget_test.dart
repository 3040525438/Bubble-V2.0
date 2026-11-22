// 工程健康检查冒烟测试：应用骨架可渲染（主 Shell + 会话列表）
import 'package:bubble/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('应用骨架可渲染（主 Shell + 会话列表）', (tester) async {
    await tester.pumpWidget(const BubbleApp());
    // 等待会话列表首次查询完成（加载动画会阻止 pumpAndSettle）
    for (var i = 0; i < 40; i++) {
      if (find.text('还没有对话').evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('消息'), findsWidgets); // 页面标题 + 底部导航 Tab
    expect(find.text('还没有对话'), findsOneWidget);

    // 卸载并让 drift watch 的收尾零时长定时器执行，避免 pending timer 断言
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
