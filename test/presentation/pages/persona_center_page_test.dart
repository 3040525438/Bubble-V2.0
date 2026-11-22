// 人格中心页面测试（T4.3）：四层切换、锁条、成长建议接受生效。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/persona_repository.dart';
import 'package:bubble/presentation/pages/persona_center_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpUntilFound(WidgetTester tester, Finder finder,
    {int maxPumps = 80}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _useLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('四层切换与核心锁条渲染', (tester) async {
    _useLargeSurface(tester);
    final db = AppDatabase(openInMemoryDatabase());
    final repo = PersonaRepository(db);
    addTearDown(() async => db.close());
    await repo.ensureSeed();

    await tester.pumpWidget(MaterialApp(
      theme: BubbleTheme.light(),
      home: PersonaCenterPage(repository: repo),
    ));
    await pumpUntilFound(tester, find.textContaining('核心人格 · v'));

    expect(find.text('已确认'), findsOneWidget);
    expect(find.text('编辑核心人格'), findsOneWidget);
    expect(find.text('只有你能修改核心人格 · 泡泡只能提建议'), findsOneWidget);

    await tester.tap(find.text('成长'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('暂时没有待审的成长建议'), findsOneWidget);
    expect(find.text('成长建议只由泡泡提出 · 每次接受都会生成新版本'), findsOneWidget);

    await tester.tap(find.text('表达样本'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('还没有表达样本'), findsOneWidget);
    expect(find.text('手动添加'), findsOneWidget);

    await tester.tap(find.text('成长记录'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('版本时间线'), findsOneWidget);
    // 全局版本号：核心层 v1 + 成长层 v2
    expect(find.text('v1'), findsWidgets);
    expect(find.text('v2'), findsWidgets);
    expect(find.text('全部修改留痕 · 恢复是新增版本而非覆盖'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('接受成长建议后成长层生效且待审清零', (tester) async {
    _useLargeSurface(tester);
    final db = AppDatabase(openInMemoryDatabase());
    final repo = PersonaRepository(db);
    addTearDown(() async => db.close());
    await repo.ensureSeed();
    await repo.proposeGrowth(
      growthType: '称呼',
      beforeValue: '你',
      afterValue: '阿岚',
      reason: '你说过想被这样叫',
    );

    await tester.pumpWidget(MaterialApp(
      theme: BubbleTheme.light(),
      home: PersonaCenterPage(repository: repo),
    ));
    await pumpUntilFound(tester, find.textContaining('核心人格 · v'));
    expect(find.textContaining('泡泡提了 1 条成长建议'), findsOneWidget);

    await tester.tap(find.text('成长'));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('成长建议'), findsOneWidget);
    expect(find.text('阿岚'), findsOneWidget);

    await tester.tap(find.text('接受'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (await repo.pendingGrowthCount() == 0) break;
    }
    expect(await repo.pendingGrowthCount(), 0);
    expect((await repo.growthValues()).valueOf('称呼'), '阿岚');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
