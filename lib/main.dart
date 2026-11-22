// 泡泡 Bubble V2.0 — 应用入口
// 启动时打开加密数据库（SQLCipher + Keychain 密钥），随后进入路由主壳。
// 数据库初始化失败时降级内存库并记录日志，保证应用可启动（数据不可持久化）。
import 'package:flutter/material.dart';

import 'data/database/db_provider.dart';
import 'presentation/app/router.dart';
import 'presentation/theme/bubble_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await AppDb.initialize();
  } catch (error) {
    debugPrint('数据库初始化失败，已降级内存库：$error');
  }
  runApp(const BubbleApp());
}

class BubbleApp extends StatelessWidget {
  const BubbleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 阶段 1：跟随系统深浅色（设置中心「跟随系统」为默认，切换 UI 后续阶段接入）
    return MaterialApp.router(
      title: '泡泡',
      routerConfig: appRouter,
      theme: BubbleTheme.light(),
      darkTheme: BubbleTheme.dark(),
      themeMode: ThemeMode.system,
    );
  }
}
