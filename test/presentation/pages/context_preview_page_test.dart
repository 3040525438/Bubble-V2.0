// 上下文预览面板测试（T6.2）：会话历史 + 人格/记忆总装、token 统计与 system 展示。
import 'package:bubble/data/context/chat_context_assembler.dart';
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/conversation_repository.dart';
import 'package:bubble/data/repositories/memory_repository.dart';
import 'package:bubble/presentation/pages/context_preview_page.dart';
import 'package:bubble/presentation/theme/bubble_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pumpUntilFound(WidgetTester tester, Finder finder,
    {int maxPumps = 120}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('上下文预览展示 system 块、历史与预算统计', (tester) async {
    tester.view.physicalSize = const Size(950, 1700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase(openInMemoryDatabase());
    final convRepo = ConversationRepository(db);
    final memoryRepo = MemoryRepository(db);
    addTearDown(() async => db.close());

    final conv = await convRepo.createConversation(title: '周末计划');
    await convRepo.appendUserMessage(conv.id, '说好了周末一起去看展');
    await memoryRepo.createMemory(
      type: 'agreement',
      summary: '说好了周末一起去看展',
      confidence: 'high',
      pinned: true,
    );

    final assembler = ChatContextAssembler(db, memoryRepository: memoryRepo);
    await tester.pumpWidget(MaterialApp(
      theme: BubbleTheme.light(),
      home: ContextPreviewPage(
        conversationId: conv.id,
        assembler: assembler,
        conversationRepository: convRepo,
      ),
    ));
    await pumpUntilFound(tester, find.text('上下文预览'));
    await pumpUntilFound(tester, find.textContaining('System 消息'));

    expect(find.textContaining('当前会话：周末计划'), findsOneWidget);
    expect(find.textContaining('token'), findsWidgets);
    expect(find.textContaining('说好了周末一起去看展'), findsWidgets);
    expect(find.textContaining('会话历史'), findsWidgets);
    expect(find.text('你'), findsWidgets);
    expect(find.textContaining('调试面板仅本地展示'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });
}
