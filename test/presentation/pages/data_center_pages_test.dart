// 阶段 14 页面测试：数据中心 / 删除全部数据 / 备份恢复 / 反馈历史。
import 'dart:io';

import 'package:bubble/data/backup/backup_service.dart';
import 'package:bubble/data/backup/export_service.dart';
import 'package:bubble/data/data_center/data_center_service.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/feedback_repository.dart';
import 'package:bubble/domain/feedback/feedback_models.dart';
import 'package:bubble/presentation/pages/backup_restore_page.dart';
import 'package:bubble/presentation/pages/data_center_page.dart';
import 'package:bubble/presentation/pages/delete_all_data_page.dart';
import 'package:bubble/presentation/pages/feedback_history_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxPumps = 160,
}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late AppDatabase db;
  late Directory root;
  late DataCenterService dataCenter;
  late FeedbackRepository feedbackRepo;
  final nowIso = DateTime.utc(2026, 11, 20).toIso8601String();

  setUp(() async {
    db = AppDatabase(openInMemoryDatabase());
    root = await Directory.systemTemp.createTemp('bubble_pages_test_');
    dataCenter = DataCenterService(
      db,
      root: root,
      clock: () => DateTime.utc(2026, 11, 20, 9, 30),
    );
    feedbackRepo = FeedbackRepository(
      db,
      clock: () => DateTime.utc(2026, 11, 20, 9, 30),
    );

    await db
        .into(db.conversations)
        .insert(
          ConversationsCompanion.insert(
            id: 'conv_1',
            title: '测试会话',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
    await db
        .into(db.memories)
        .insert(
          MemoriesCompanion.insert(
            id: 'mem_1',
            type: 'preference',
            summary: '喜欢咖啡',
            createdAt: nowIso,
            updatedAt: nowIso,
          ),
        );
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(theme: BubbleTheme.light(), home: page),
    );
  }

  Future<void> settleDown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('数据中心展示状态卡与维护入口', (tester) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // loadStatus 含真实文件 IO，需在 runAsync 中完成首帧加载
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: BubbleTheme.light(),
          home: DataCenterPage(
            service: dataCenter,
            exporter: ExportService(db, root: root),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await pumpUntilFound(tester, find.text('维护操作'));

    expect(find.text('数据中心'), findsOneWidget);
    expect(find.text('数据库'), findsOneWidget);
    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('迁移与导入向导'), findsOneWidget);
    expect(find.text('完整性检查'), findsOneWidget);
    expect(find.text('删除全部数据'), findsOneWidget);
    expect(find.text('危险区'), findsOneWidget);

    await settleDown(tester);
  });

  testWidgets('删除全部数据页三重门：未输入短语时按钮禁用', (tester) async {
    await pumpPage(tester, DeleteAllDataPage(service: dataCenter));
    await pumpUntilFound(tester, find.text('门一 · 将被删除的内容'));

    expect(find.text('门二 · 输入确认短语'), findsOneWidget);
    expect(find.text('门三 · 独立备份'), findsOneWidget);

    var button = tester.widget<FilledButton>(
      find.byKey(const Key('delete-all-button')),
    );
    expect(button.onPressed, isNull);

    await tester.enterText(
      find.byKey(const Key('delete-confirm-phrase')),
      kDeleteConfirmPhrase,
    );
    await tester.pump();

    button = tester.widget<FilledButton>(
      find.byKey(const Key('delete-all-button')),
    );
    expect(button.onPressed, isNotNull);

    // 输入错误短语再次禁用
    await tester.enterText(
      find.byKey(const Key('delete-confirm-phrase')),
      '删除吧',
    );
    await tester.pump();
    button = tester.widget<FilledButton>(
      find.byKey(const Key('delete-all-button')),
    );
    expect(button.onPressed, isNull);

    await settleDown(tester);
  });

  testWidgets('备份恢复页空态与「立即备份」入口', (tester) async {
    await pumpPage(
      tester,
      BackupRestorePage(service: BackupService(db, root: root)),
    );
    await pumpUntilFound(tester, find.text('还没有备份'));

    expect(find.text('备份与恢复'), findsOneWidget);
    expect(find.text('立即备份'), findsOneWidget);
    expect(find.textContaining('目录包备份'), findsWidgets);

    await settleDown(tester);
  });

  testWidgets('反馈历史展示记录并可撤销', (tester) async {
    final entry = await feedbackRepo.record(
      kind: FeedbackTargetKind.post,
      targetId: 'post_1',
      verdict: FeedbackVerdict.like,
      note: '这条说说很温暖',
    );

    await pumpPage(tester, FeedbackHistoryPage(repository: feedbackRepo));
    await pumpUntilFound(tester, find.text('这条说说很温暖'));

    expect(find.text('反馈历史'), findsOneWidget);
    expect(find.text('喜欢'), findsOneWidget);

    await tester.tap(find.byKey(Key('revert-${entry.id}')));
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byKey(Key('revert-${entry.id}')).evaluate().isEmpty) break;
    }
    expect(find.text('已撤销'), findsWidgets);

    await settleDown(tester);
  });

  testWidgets('反馈历史空态提示', (tester) async {
    await pumpPage(tester, FeedbackHistoryPage(repository: feedbackRepo));
    await pumpUntilFound(tester, find.text('还没有反馈记录'));
    expect(find.text('还没有反馈记录'), findsOneWidget);
    await settleDown(tester);
  });
}
