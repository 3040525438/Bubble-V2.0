// 核心人格编辑页测试（T4.3）：六字段渲染、保存前逐项 diff 确认。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/persona_repository.dart';
import 'package:bubble/presentation/pages/core_persona_edit_page.dart';
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

void main() {
  testWidgets('六字段渲染，diff 需逐项勾选后才可保存', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase(openInMemoryDatabase());
    final repo = PersonaRepository(db);
    addTearDown(() async => db.close());
    await repo.ensureSeed();

    await tester.pumpWidget(MaterialApp(
      theme: BubbleTheme.light(),
      home: CorePersonaEditPage(repository: repo),
    ));
    await pumpUntilFound(tester, find.byKey(const ValueKey('core_field_identity')));

    for (final label in ['身份', '性格底色', '价值观', '关系定位', '说话习惯', '行为边界']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.enterText(
        find.byKey(const ValueKey('core_field_identity')), '你是泡泡，也是我的云朵。');
    await tester.pump();
    await tester.ensureVisible(find.text('保存修改'));
    await tester.tap(find.text('保存修改'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.text('确认修改（生成 v3）').evaluate().isNotEmpty) break;
    }

    expect(find.text('确认修改（生成 v3）'), findsOneWidget);
    final confirmFinder = find.widgetWithText(FilledButton, '确认保存（生成 v3）');
    expect(confirmFinder, findsOneWidget);
    expect(tester.widget<FilledButton>(confirmFinder).onPressed, isNotNull);

    // 取消唯一一项勾选 → 保存按钮禁用（逐项确认门禁）
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmFinder).onPressed, isNull);

    // 重新勾选 → 恢复可用；放弃则不产生新版本
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirmFinder).onPressed, isNotNull);
    await tester.tap(find.text('放弃'));
    await tester.pump(const Duration(milliseconds: 120));

    expect((await repo.versions(layer: 'core')).length, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
