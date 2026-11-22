// 泡泡 Bubble V2.0 — 应用入口（阶段 1 骨架）
// 主题（浅/深/跟随系统）+ GoRouter 接入；锁屏在 SecurityController 就绪后前置。
import 'package:flutter/material.dart';

import 'presentation/app/router.dart';
import 'presentation/theme/bubble_theme.dart';

void main() {
  runApp(const BubbleApp());
}

class BubbleApp extends StatelessWidget {
  const BubbleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 阶段 1：跟随系统深浅色（设置中心「跟随系统」为默认，阶段 20 接切换 UI）
    return MaterialApp.router(
      title: '泡泡',
      routerConfig: appRouter,
      theme: BubbleTheme.light(),
      darkTheme: BubbleTheme.dark(),
      themeMode: ThemeMode.system,
    );
  }
}
