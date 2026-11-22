// 记忆页面冒烟测试（T5.4）：总览筛选/搜索、收件箱、详情版本恢复、冲突裁决、注入预览。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/memory_repository.dart';
import 'package:bubble/domain/memory/memory_engine.dart';
import 'package:bubble/presentation/pages/memory_center_page.dart';
import 'package:bubble/presentation/pages/memory_conflict_page.dart';
import 'package:bubble/presentation/pages/memory_detail_page.dart';
import 'package:bubble/presentation/pages/memory_inbox_page.dart';
import 'package:bubble/presentation/pages/memory_inject_preview_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpUntilFound(WidgetTester tester, Finder finder,
    {int maxPumps = 100}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpUntilGone(WidgetTester tester, Finder finder,
    {int maxPumps = 100}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _useLargeSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(Widget home) => MaterialApp(theme: BubbleTheme.light(), home: home);

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

void main() {
  late AppDatabase db;
  late MemoryRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = MemoryRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  testWidgets('记忆总览：计数、类型筛选与搜索', (tester) async {
    _useLargeSurface(tester);
    await repo.createMemory(
      type: 'preference',
      title: '咖啡偏好',
      summary: '我喜欢每天早上喝一杯黑咖啡',
      confidence: 'high',
      pinned: true,
    );
    await repo.createMemory(
      type: 'project',
      title: '项目进度',
      summary: '项目进度卡在接口联调',
    );
    final draft = const MemoryEngine().extract('记住：我最近住院做手术');
    await repo.ingestDraft(draft!);

    await tester.pumpWidget(_app(MemoryCenterPage(repository: repo)));
    await pumpUntilFound(tester, find.text('记忆中心'));
    await pumpUntilFound(tester, find.textContaining('咖啡偏好'));

    expect(find.text('收件箱'), findsOneWidget);
    expect(find.text('待裁决'), findsOneWidget);
    expect(find.text('常驻'), findsWidgets);
    expect(find.textContaining('项目进度'), findsWidgets);

    await tester.tap(find.text('用户偏好').first);
    await tester.pump(const Duration(milliseconds: 80));
    await pumpUntilGone(tester, find.textContaining('项目进度'));
    expect(find.textContaining('项目进度'), findsNothing);

    await tester.tap(find.text('全部').first);
    await tester.pump(const Duration(milliseconds: 80));
    await pumpUntilFound(tester, find.textContaining('项目进度'));
    expect(find.textContaining('项目进度'), findsWidgets);

    await tester.enterText(find.byType(TextField), '黑咖啡');
    await pumpUntilGone(tester, find.textContaining('项目进度'));
    expect(find.textContaining('咖啡偏好'), findsWidgets);
    expect(find.textContaining('项目进度'), findsNothing);

    await _settle(tester);
  });

  testWidgets('收件箱：全部接受后清空', (tester) async {
    _useLargeSurface(tester);
    final draft = const MemoryEngine().extract('记住：我最近住院做手术');
    await repo.ingestDraft(draft!);

    await tester.pumpWidget(_app(MemoryInboxPage(repository: repo)));
    await pumpUntilFound(tester, find.text('记忆收件箱'));
    await pumpUntilFound(tester, find.textContaining('住院'));

    expect(find.text('全部接受'), findsOneWidget);
    expect(find.text('编辑后接受'), findsOneWidget);

    await tester.tap(find.text('全部接受'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (await repo.listCandidates().then((v) => v.isEmpty)) break;
    }
    await pumpUntilFound(tester, find.text('没有待确认的记忆'));
    expect(await repo.listCandidates(), isEmpty);

    await _settle(tester);
  });

  testWidgets('详情：来源证据、版本历史与恢复', (tester) async {
    _useLargeSurface(tester);
    final memory = await repo.createMemory(
      type: 'preference',
      title: '西湖散步',
      summary: '我喜欢在周末去西湖边散步',
      evidence: '我周末喜欢去西湖边走走',
      confidence: 'high',
    );
    await repo.updateMemory(memory.id, summary: '我喜欢在周末去西湖边散步，通常带着相机');

    await tester.pumpWidget(
      _app(MemoryDetailPage(memoryId: memory.id, repository: repo)),
    );
    await pumpUntilFound(tester, find.text('记忆详情'));
    await pumpUntilFound(tester, find.textContaining('西湖散步'));

    expect(find.text('来源证据'), findsOneWidget);
    expect(find.textContaining('我周末喜欢去西湖边走走'), findsOneWidget);
    expect(find.text('版本历史'), findsOneWidget);
    expect(find.text('v2'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget);

    await tester.tap(find.text('恢复').first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilledButton, '恢复'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final current = await repo.getMemory(memory.id);
      if (current?.summary == '我喜欢在周末去西湖边散步') break;
    }
    expect((await repo.getMemory(memory.id))!.summary, '我喜欢在周末去西湖边散步');

    await _settle(tester);
  });

  testWidgets('冲突裁决：保留 A 后生效', (tester) async {
    _useLargeSurface(tester);
    await repo.createMemory(
      type: 'preference',
      title: '养猫',
      summary: '我喜欢养猫，家里有三只，一只叫团子，一只叫年糕',
      confidence: 'high',
    );
    final draft = const MemoryEngine()
        .extract('我喜欢养猫，家里有两只，一只叫团子，一只叫年糕');
    await repo.ingestDraft(draft!);
    final candidate = (await repo.listCandidates()).first;
    final bId = await repo.acceptCandidate(candidate.id);

    await tester.pumpWidget(
      _app(MemoryConflictPage(memoryId: bId, repository: repo)),
    );
    await pumpUntilFound(tester, find.text('冲突裁决'));
    await pumpUntilFound(tester, find.text('版本 A'));

    expect(find.text('这条记忆存在两个版本'), findsOneWidget);
    expect(find.text('版本 B'), findsOneWidget);
    expect(find.text('两个都不对，我来写'), findsOneWidget);

    await tester.tap(find.text('保留 A'));
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final winner = await repo.getMemory(bId);
      if (winner?.status == 'active') break;
    }
    expect((await repo.getMemory(bId))!.status, 'active');

    await _settle(tester);
  });

  testWidgets('注入预览：常驻块与召回预览', (tester) async {
    _useLargeSurface(tester);
    await repo.createMemory(
      type: 'agreement',
      title: '看展约定',
      summary: '说好了周末一起去看展',
      confidence: 'high',
      pinned: true,
    );

    await tester.pumpWidget(_app(MemoryInjectPreviewPage(repository: repo)));
    await pumpUntilFound(tester, find.text('注入预览'));
    await pumpUntilFound(tester, find.textContaining('泡泡此刻会带上这些'));

    expect(find.textContaining('说好了周末一起去看展'), findsOneWidget);
    expect(find.textContaining('token'), findsWidgets);

    await tester.enterText(find.byType(TextField), '周末一起看展');
    await tester.tap(find.text('预览'));
    await pumpUntilFound(tester, find.textContaining('可能相关的记忆'));
    expect(find.textContaining('为什么是这几条'), findsOneWidget);

    await _settle(tester);
  });
}
