// 泡泡 Bubble V2.0 — 应用入口（阶段 1 骨架版）
// 完整主题/路由/锁屏在阶段 1-7/1-8 接入，此版本仅验证工程链路。
import 'package:flutter/material.dart';

void main() {
  runApp(const BubbleApp());
}

class BubbleApp extends StatelessWidget {
  const BubbleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '泡泡',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF58AEF0), useMaterial3: true),
      home: const Scaffold(
        body: Center(child: Text('泡泡 Bubble V2.0 · 阶段 1 骨架')),
      ),
    );
  }
}
