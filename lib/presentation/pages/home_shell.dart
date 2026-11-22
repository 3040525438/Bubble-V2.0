// 主界面 Shell（底部导航）：消息 / 时间线 / 说说 / 我的 四 Tab。
// 阶段 7 起：前台定时触发思考、回前台恢复中断任务，FAB 进入思考中心。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/thinking/thinking_factory.dart';
import '../../data/thinking/thinking_orchestrator.dart';
import '../../domain/thinking/thinking_models.dart';
import '../theme/bubble_colors.dart';
import 'conversation_list_page.dart';
import 'placeholder_page.dart';
import 'profile_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  Timer? _thinkingTimer;
  ThinkingOrchestrator? _thinking;
  bool _thinkingBusy = false;

  /// 前台定时触发间隔（主动程度设置接入后按档位调整，阶段 8）
  static const Duration thinkingInterval = Duration(minutes: 60);

  static const _tabs = <(IconData, String, String)>[
    (Icons.chat_bubble_outline_rounded, '消息', '消息'),
    (Icons.timeline_rounded, '时间线', '时间线（阶段 9）'),
    (Icons.favorite_border_rounded, '说说', '说说（阶段 10）'),
    (Icons.person_outline_rounded, '我的', '我的（阶段 4/14）'),
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
      await _thinking!.recoverInterrupted();
    } catch (_) {
      // 思考模块失败不影响主界面可用
    }
    _ensureTimer();
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
    } catch (_) {
      // 定时思考失败不打扰用户
    } finally {
      _thinkingBusy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final (_, _, placeholder) = _tabs[_index];
    return Scaffold(
      body: switch (_index) {
        0 => const ConversationListPage(),
        3 => const ProfilePage(),
        _ => PlaceholderPage(title: placeholder),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final (icon, label, _) in _tabs)
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
