// 主界面 Shell（底部导航）：消息 / 时间线 / 说说 / 我的 四 Tab。
// 阶段 7 起：前台定时触发思考、回前台恢复中断任务，FAB 进入思考中心。
// 阶段 13：初始化本地通知与 iOS 后台任务，通知点击深链回聊天。
import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/diary/diary_generator.dart';
import '../../data/letter/letter_generator.dart';
import '../../data/notification/background_task_service.dart';
import '../../data/notification/notification_dispatcher.dart';
import '../../data/notification/notification_runtime.dart';
import '../../data/notification/notification_scheduler.dart';
import '../../data/notification/system_channel.dart';
import '../../data/post/post_generator.dart';
import '../../data/proactive/content_deliverer.dart';
import '../../data/proactive/proactive_chat_deliverer.dart';
import '../../data/proactive/proactive_decision_center.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/thinking/thinking_factory.dart';
import '../../data/thinking/thinking_orchestrator.dart';
import '../../domain/notification/notification_models.dart';
import '../../domain/thinking/thinking_models.dart';
import '../app/router.dart';
import '../theme/bubble_colors.dart';
import 'conversation_list_page.dart';
import 'posts_page.dart';
import 'profile_page.dart';
import 'timeline_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  Timer? _thinkingTimer;
  ThinkingOrchestrator? _thinking;
  ProactiveDecisionCenter? _proactive;
  NotificationDispatcher? _notifications;
  bool _thinkingBusy = false;

  /// 前台定时触发间隔（主动程度设置接入后按档位调整，阶段 8）
  static const Duration thinkingInterval = Duration(minutes: 60);

  static const _tabs = <(IconData, String)>[
    (Icons.chat_bubble_outline_rounded, '消息'),
    (Icons.favorite_border_rounded, '说说'),
    (Icons.timeline_rounded, '时间线'),
    (Icons.person_outline_rounded, '我的'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrapThinking();
  }

  @override
  void dispose() {
    _thinkingTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_thinking == null) {
      _bootstrapThinking();
      return;
    }
    _recoverThinking();
  }

  Future<void> _bootstrapThinking() async {
    try {
      final setup = await createThinkingSetup(AppDb.instance);
      _thinking = setup.orchestrator;
      // 阶段 13：通知能力与后台任务（失败不阻断主界面与思考）
      await _bootstrapNotifications();
      // 决策中心唯一执行入口：说说/日记/信件/主动聊天由生成器真实落地（FR-DEC-01）
      final notifications = _notifications;
      _proactive = ProactiveDecisionCenter(
        AppDb.instance,
        deliverer: contentAwareDeliverer(
          post: PostGenerator(AppDb.instance),
          diary: DiaryGenerator(AppDb.instance),
          letter: LetterGenerator(AppDb.instance),
          chat: notifications == null
              ? null
              : ProactiveChatDeliverer(
                  conversations: ConversationRepository(AppDb.instance),
                  notifications: notifications,
                ),
          notifications: notifications,
        ),
      );
      await _thinking!.recoverInterrupted();
    } catch (_) {
      // 思考模块失败不影响主界面可用
    }
    _ensureTimer();
  }

  /// 初始化本地通知调度与后台任务通道（真实能力取决于平台与权限）
  Future<void> _bootstrapNotifications() async {
    try {
      final timezone = await SystemChannel.localTimezone();
      final scheduler = LocalNotificationScheduler(
        timezoneName: () => timezone,
      );
      final dispatcher = NotificationDispatcher(
        AppDb.instance,
        scheduler: scheduler,
        timezone: () => timezone,
      );
      await dispatcher.initialize(onTap: _handleNotificationTap);
      _notifications = dispatcher;
      NotificationRuntime.dispatcher = dispatcher;
      // 恢复扫描：过期通知作废、时区变化重排
      await dispatcher.reconcileExpired();
      await dispatcher.reschedulePending();

      final background = BackgroundTaskService(
        db: AppDb.instance,
        orchestrator: _thinking,
      )..initialize();
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await background.submitRefresh();
      }
    } catch (_) {
      // 通知/后台不可用时不冒充可用：设置页会显示真实权限状态
    }
  }

  void _handleNotificationTap(String? payload) {
    final decoded = NotificationPayload.tryDecode(payload);
    final path = decoded?.routePath;
    if (path == null) return;
    try {
      appRouter.push(path);
    } catch (_) {
      // 已在目标页面时不重复入栈
    }
  }

  Future<void> _recoverThinking() async {
    try {
      await _thinking?.recoverInterrupted();
    } catch (_) {
      // 忽略恢复失败，下一次触发会重试
    }
  }

  void _ensureTimer() {
    _thinkingTimer ??= Timer.periodic(thinkingInterval, (_) {
      _runThinking(ThinkingTrigger.foregroundTimer);
    });
  }

  Future<void> _runThinking(ThinkingTrigger trigger) async {
    final orchestrator = _thinking;
    if (orchestrator == null || _thinkingBusy) return;
    _thinkingBusy = true;
    try {
      await orchestrator.runNew(trigger: trigger);
      // 思考产生候选后，统一由决策中心判断是否执行（唯一执行入口 FR-DEC-01）
      await _proactive?.runOnce();
      // 顺带清理过期待投递通知（不在每次思考时重排，避免打扰）
      await _notifications?.reconcileExpired();
    } catch (_) {
      // 定时思考失败不打扰用户
    } finally {
      _thinkingBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_index) {
        0 => const ConversationListPage(),
        1 => const PostsPage(),
        2 => const TimelinePage(),
        _ => const ProfilePage(),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final (icon, label) in _tabs)
            NavigationDestination(icon: Icon(icon), label: label),
        ],
      ),
      // 泡泡 FAB（紫调投影 §5）：进入思考中心（阶段 7）
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              backgroundColor: context.bubbleColors.lavender,
              onPressed: () => context.push('/thinking'),
              child: const Icon(Icons.psychology_rounded, color: Colors.white),
            )
          : null,
    );
  }
}
