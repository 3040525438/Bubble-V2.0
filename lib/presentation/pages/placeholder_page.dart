// 占位页：骨架期路由目标。仅用于导航结构验证，
// 正式页面随各模块阶段落地后替换（授权书 §4：占位不得冒充功能完成）。
import 'package:flutter/material.dart';

class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({super.key, required this.title, this.detail});

  final String title;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$title · 骨架占位'),
            if (detail != null && detail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('参数：$detail',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
