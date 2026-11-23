// 迁移向导页来源选择测试（T14.5 补充）：文件选择入口、路径回填与预演触发。
import 'dart:io';

import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/migration/astrbot_import_service.dart';
import 'package:bubble/data/migration/astrbot_source.dart';
import 'package:bubble/data/migration/migration_source_picker.dart';
import 'package:bubble/presentation/pages/migration_wizard_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 空只读 SQL：源目录不存在对应库文件时不会调用查询。
class _EmptySql implements ReadOnlySql {
  @override
  bool get supported => true;

  @override
  List<Map<String, Object?>> query(String dbPath, String sql) => const [];

  @override
  void close() {}
}

class _FakePicker implements MigrationSourcePicker {
  _FakePicker(this.rootPath, {this.supportsDirectory = true});

  final String rootPath;

  @override
  final bool supportsDirectory;

  @override
  Future<PickedMigrationSource?> pickArchive() async => PickedMigrationSource(
    rootPath: rootPath,
    label: 'astrbot.zip',
    fromArchive: true,
  );

  @override
  Future<PickedMigrationSource?> pickDirectory() async =>
      PickedMigrationSource(rootPath: rootPath, label: 'astrbot');
}

void main() {
  late AppDatabase db;
  late Directory root;

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_wizard_test_');
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  AstrBotImportService buildService(String rootPath) => AstrBotImportService(
    db,
    source: AstrBotSource(rootPath: rootPath, sql: _EmptySql()),
  );

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: BubbleTheme.light(), home: page),
    );
  }

  testWidgets('桌面模式展示文件夹与压缩包两个入口', (tester) async {
    await pumpPage(
      tester,
      MigrationWizardPage(
        picker: _FakePicker(root.path),
        serviceFactory: buildService,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('migration-pick-archive')), findsOneWidget);
    expect(find.byKey(const Key('migration-pick-directory')), findsOneWidget);
    expect(find.textContaining('源文件不会被修改'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('移动模式只展示压缩包入口', (tester) async {
    await pumpPage(
      tester,
      MigrationWizardPage(
        picker: _FakePicker(root.path, supportsDirectory: false),
        serviceFactory: buildService,
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('migration-pick-archive')), findsOneWidget);
    expect(find.byKey(const Key('migration-pick-directory')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('选择压缩包后回填路径并触发预演', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: BubbleTheme.light(),
          home: MigrationWizardPage(
            picker: _FakePicker(root.path, supportsDirectory: false),
            serviceFactory: buildService,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('migration-pick-archive')));
      // 轮询等待真实文件 IO 的预演完成（全量并发下固定延时不可靠）
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find.text('预演报告').evaluate().isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    final field = tester.widget<TextField>(
      find.byKey(const Key('migration-source-path')),
    );
    expect(field.controller?.text, root.path);
    expect(find.text('预演报告'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
