// 主界面 Shell（底部导航）：消息 / 时间线 / 说说 / 我的 四 Tab。
// 对应 UI_INFORMATION_ARCHITECTURE 主结构；Tab 内容为骨架占位，
// 正式页面在阶段 2（消息）/9（时间线）/10（说说）/4+14（我的）落地。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/bubble_colors.dart';
import 'placeholder_page.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _tabs = <(IconData, String, String)>[
    (Icons.chat_bubble_outline_rounded, '消息', '消息（阶段 2）'),
    (Icons.timeline_rounded, '时间线', '时间线（阶段 9）'),
    (Icons.favorite_border_rounded, '说说', '说说（阶段 10）'),
    (Icons.person_outline_rounded, '我的', '我的（阶段 4/14）'),
  ];

  @override
  Widget build(BuildContext context) {
    final (icon, label, placeholder) = _tabs[_index];
    return Scaffold(
      body: PlaceholderPage(title: placeholder),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final (icon, label, _) in _tabs)
            NavigationDestination(icon: Icon(icon), label: label),
        ],
      ),
      // 泡泡 FAB（紫调投影 §5：突出"思考"入口，阶段 7 接自主思考）
      floatingActionButton: FloatingActionButton(
        backgroundColor:
            Theme.of(context).extension<BubbleSemanticColors>()?.lavender,
        onPressed: () => context.push('/memory'),
        child: const Icon(Icons.psychology_rounded, color: Colors.white),
      ),
    );
  }
}
