// 主界面 Shell（底部导航）：消息 / 时间线 / 说说 / 我的 四 Tab。
// 对应 UI_INFORMATION_ARCHITECTURE 主结构；消息 Tab 阶段 2 已落地，
// 其余 Tab 为骨架占位（阶段 9/10/4+14 分别落地）。
import 'package:flutter/material.dart';

import '../theme/bubble_colors.dart';
import 'conversation_list_page.dart';
import 'placeholder_page.dart';
import 'profile_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _tabs = <(IconData, String, String)>[
    (Icons.chat_bubble_outline_rounded, '消息', '消息'),
    (Icons.timeline_rounded, '时间线', '时间线（阶段 9）'),
    (Icons.favorite_border_rounded, '说说', '说说（阶段 10）'),
    (Icons.person_outline_rounded, '我的', '我的（阶段 4/14）'),
  ];

  void _onThinkTap() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('自主思考将在阶段 7 开放'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(milliseconds: 1600),
      ));
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
      // 泡泡 FAB（紫调投影 §5）：思考入口，阶段 7 接自主思考
      floatingActionButton: _index == 0
          ? FloatingActionButton(
              backgroundColor: context.bubbleColors.lavender,
              onPressed: _onThinkTap,
              child: const Icon(Icons.psychology_rounded, color: Colors.white),
            )
          : null,
    );
  }
}
