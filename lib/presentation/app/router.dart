// GoRouter 全路由表（T1.5）：页面体系对应授权书第七章与 UI_INFORMATION_ARCHITECTURE。
// 阶段 1 为骨架：主结构 + 占位页；各正式页面随对应模块阶段落地。
import 'package:go_router/go_router.dart';

import '../pages/chat_page.dart';
import '../pages/home_shell.dart';
import '../pages/lock_screen.dart';
import '../pages/model_manage_page.dart';
import '../pages/placeholder_page.dart';

class AppRoutes {
  static const lock = '/lock';
  static const home = '/';
  static const chat = '/chat/:conversationId';
  static const memory = '/memory';
  static const persona = '/persona';
  static const models = '/models';
  static const search = '/search';
  static const dataCenter = '/data';
  static const settings = '/settings';
}

final GoRouter appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    // 锁屏（T1.6 应用锁）
    GoRoute(
      path: AppRoutes.lock,
      builder: (context, state) => const LockScreen(),
    ),
    // 主界面（底部导航 Shell：消息 / 时间线 / 说说 / 我的）
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const HomeShell(),
    ),
    // 会话详情（阶段 2 正式页面；通知深链阶段 13 接入 ?focus=<messageId>）
    GoRoute(
      path: AppRoutes.chat,
      builder: (context, state) => ChatPage(
        conversationId: state.pathParameters['conversationId'] ?? '',
      ),
    ),
    ..._simpleRoutes(),
  ],
);

List<GoRoute> _simpleRoutes() => [
      _route(AppRoutes.memory, '记忆中心'),
      _route(AppRoutes.persona, '人格中心'),
      // 模型管理（阶段 3 正式页面）
      GoRoute(
        path: AppRoutes.models,
        builder: (context, state) => const ModelManagePage(),
      ),
      _route(AppRoutes.search, '全局搜索'),
      _route(AppRoutes.dataCenter, '数据管理'),
      _route(AppRoutes.settings, '设置'),
    ];

GoRoute _route(String path, String title) => GoRoute(
      path: path,
      builder: (context, state) => PlaceholderPage(title: title),
    );
