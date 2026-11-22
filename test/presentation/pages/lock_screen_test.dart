// 应用锁骨架测试（T1.6）：渲染 + 文案（验证按钮存在）
import 'package:bubble/presentation/pages/lock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('锁屏页渲染：头像/文案/验证按钮', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MaterialApp(home: LockScreen()));
    await tester.pump(const Duration(seconds: 3)); // 呼吸动效数帧
    expect(find.text('泡泡已锁定'), findsOneWidget);
    expect(find.text('验证以继续'), findsOneWidget);
    expect(find.byIcon(Icons.face_retouching_natural_rounded), findsOneWidget);
    expect(find.text('Face ID 解锁'), findsOneWidget);
  });
}
