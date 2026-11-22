// 模型管理页组件测试（T3.3）：种子模型渲染、未配置 Key 提示、用量卡。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/model_repository.dart';
import 'package:bubble/presentation/pages/model_manage_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_key_store.dart';

Future<void> pumpUntilFound(WidgetTester tester, Finder finder,
    {int maxPumps = 60}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('模型管理页渲染默认模型、Key 状态与用量卡', (tester) async {
    final db = AppDatabase(openInMemoryDatabase());
    final repo = ModelRepository(db, keyStore: InMemoryKeyStore());
    addTearDown(() async => db.close());

    await tester.pumpWidget(MaterialApp(
      theme: BubbleTheme.light(),
      home: ModelManagePage(repository: repo),
    ));
    await pumpUntilFound(tester, find.text('DeepSeek'));

    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('deepseek-chat'), findsNothing); // 与地址合并展示
    expect(find.textContaining('deepseek-chat'), findsOneWidget);
    expect(find.text('未配置 Key'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);
    expect(find.text('用量（本月）'), findsOneWidget);
    expect(find.text('测试连接'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
