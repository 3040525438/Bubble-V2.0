// GoRouter 全路由表（T1.5）：页面体系对应授权书第七章与 UI_INFORMATION_ARCHITECTURE。
// 阶段 1 为骨架：主结构 + 占位页；各正式页面随对应模块阶段落地。
import 'package:go_router/go_router.dart';

import '../pages/chat_page.dart';
import '../pages/context_preview_page.dart';
import '../pages/core_persona_edit_page.dart';
import '../pages/experience_detail_page.dart';
import '../pages/home_shell.dart';
import '../pages/lock_screen.dart';
import '../pages/memory_center_page.dart';
import '../pages/memory_conflict_page.dart';
import '../pages/memory_detail_page.dart';
import '../pages/memory_inbox_page.dart';
import '../pages/memory_inject_preview_page.dart';
import '../pages/model_manage_page.dart';
import '../pages/persona_center_page.dart';
import '../pages/placeholder_page.dart';
import '../pages/proactive_center_page.dart';
import '../pages/settings_page.dart';
import '../pages/thinking_center_page.dart';

class AppRoutes {
  static const lock = '/lock';
  static const home = '/';
  static const chat = '/chat/:conversationId';
  static const memory = '/memory';
  static const thinking = '/thinking';
  static const proactive = '/proactive';
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
      // 记忆中心（阶段 5 正式页面）+ 详情/收件箱/冲突裁决/注入预览
      GoRoute(
        path: AppRoutes.memory,
        builder: (context, state) => const MemoryCenterPage(),
        routes: [
          GoRoute(
            path: 'detail/:memoryId',
            builder: (context, state) => MemoryDetailPage(
              memoryId: state.pathParameters['memoryId'] ?? '',
            ),
          ),
          GoRoute(
            path: 'inbox',
            builder: (context, state) => const MemoryInboxPage(),
          ),
          GoRoute(
            path: 'conflict/:memoryId',
            builder: (context, state) => MemoryConflictPage(
              memoryId: state.pathParameters['memoryId'] ?? '',
            ),
          ),
          GoRoute(
            path: 'inject',
            builder: (context, state) => const MemoryInjectPreviewPage(),
          ),
        ],
      ),
      // 人格中心（阶段 4 正式页面）+ 核心人格编辑
      GoRoute(
        path: AppRoutes.persona,
        builder: (context, state) => const PersonaCenterPage(),
      ),
      GoRoute(
        path: '/persona/edit',
        builder: (context, state) => const CorePersonaEditPage(),
      ),
      // 模型管理（阶段 3 正式页面）
      GoRoute(
        path: AppRoutes.models,
        builder: (context, state) => const ModelManagePage(),
      ),
      // 思考中心（阶段 7 正式页面）
      GoRoute(
        path: AppRoutes.thinking,
        builder: (context, state) => const ThinkingCenterPage(),
      ),
      // 主动行为决策中心（阶段 8 正式页面）
      GoRoute(
        path: AppRoutes.proactive,
        builder: (context, state) => const ProactiveCenterPage(),
      ),
      // 设置主页（阶段 8：主动性分组；通知/数据分组随阶段 13/14 补齐）
      GoRoute(
        path: AppRoutes.settings,
        builder: (context, state) => const SettingsPage(),
      ),
      // 共同经历详情（阶段 9 正式页面）
      GoRoute(
        path: '/experience/:experienceId',
        builder: (context, state) => ExperienceDetailPage(
          experienceId: state.pathParameters['experienceId'] ?? '',
        ),
      ),
      // 上下文调试预览（阶段 6）
      GoRoute(
        path: '/context/preview',
        builder: (context, state) => ContextPreviewPage(
          conversationId: state.uri.queryParameters['conversationId'],
        ),
      ),
      _route(AppRoutes.search, '全局搜索'),
      _route(AppRoutes.dataCenter, '数据管理'),
    ];

GoRoute _route(String path, String title) => GoRoute(
      path: path,
      builder: (context, state) => PlaceholderPage(title: title),
    );
