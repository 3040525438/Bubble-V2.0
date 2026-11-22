// 日记仓储单测（T11.1）：日期归档、搜索、版本保留、恢复与导出。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/diary_repository.dart';
import 'package:bubble/domain/diary/diary_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late DiaryRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    repo = DiaryRepository(db, clock: () => DateTime(2026, 5, 20, 21));
  });

  tearDown(() async {
    await db.close();
  });

  Future<Diary> create({
    DateTime? date,
    String content = '今天一起看了很久的云',
    DiaryOrigin origin = DiaryOrigin.aiOrganized,
    List<String> memoryIds = const <String>[],
  }) {
    return repo.createDiary(
      DiaryDraft(
        entryDate: date ?? DateTime(2026, 5, 20),
        content: content,
        origin: origin,
        relatedMemoryIds: memoryIds,
      ),
    );
  }

  group('创建与列表', () {
    test('按日期倒序列出并支持按月筛选', () async {
      await create(date: DateTime(2026, 5, 20), content: '五月二十');
      await create(date: DateTime(2026, 5, 21), content: '五月二十一');
      await create(date: DateTime(2026, 4, 30), content: '四月三十');

      final all = await repo.listDiaries();
      expect(all.length, 3);
      expect(all.first.entryDate, '2026-05-21');
      expect(await repo.countDiaries(), 3);

      final may = await repo.listDiaries(year: 2026, month: 5);
      expect(may.length, 2);
      expect(may.every((row) => row.entryDate.startsWith('2026-05')), isTrue);
    });

    test('同一天可以有多篇并按日期查询', () async {
      await create(content: '早上的版本');
      await create(content: '晚上的版本');
      final rows = await repo.listByDate(DateTime(2026, 5, 20));
      expect(rows.length, 2);
    });

    test('关键词搜索命中正文', () async {
      await create(content: '今天去了咖啡店');
      await create(content: '晚上读了书');
      final rows = await repo.listDiaries(keyword: '咖啡');
      expect(rows.length, 1);
      expect(rows.single.content, contains('咖啡'));
    });

    test('空内容被拒绝', () async {
      await expectLater(
        repo.createDiary(
          DiaryDraft(entryDate: DateTime(2026, 5, 20), content: '  '),
        ),
        throwsArgumentError,
      );
    });
  });

  group('版本保留', () {
    test('编辑把旧内容写入版本并可继续追加', () async {
      final diary = await create(content: '最初的版本');
      await repo.updateDiary(diary.id, content: '第二版');
      var updated = (await repo.getDiary(diary.id))!;
      expect(updated.content, '第二版');
      var versions = DiaryRules.parseVersions(updated.versions);
      expect(versions.length, 1);
      expect(versions.single.content, '最初的版本');

      await repo.updateDiary(diary.id, content: '第三版');
      updated = (await repo.getDiary(diary.id))!;
      versions = DiaryRules.parseVersions(updated.versions);
      expect(versions.length, 2);
      expect(versions.last.content, '第二版');
    });

    test('编辑为空被拒绝且不产生版本', () async {
      final diary = await create(content: '原文');
      await expectLater(
        repo.updateDiary(diary.id, content: '   '),
        throwsArgumentError,
      );
      final row = (await repo.getDiary(diary.id))!;
      expect(row.content, '原文');
      expect(DiaryRules.parseVersions(row.versions), isEmpty);
    });

    test('可以把来源改为你补写', () async {
      final diary = await create();
      await repo.updateDiary(diary.id, origin: DiaryOrigin.manual);
      final row = (await repo.getDiary(diary.id))!;
      expect(row.origin, DiaryOrigin.manual.wire);
    });
  });

  group('删除恢复与导出', () {
    test('软删除后不可见，恢复后重新出现', () async {
      final diary = await create();
      await repo.softDelete(diary.id);
      expect(await repo.listDiaries(), isEmpty);
      expect(await repo.countDiaries(), 0);

      await repo.restore(diary.id);
      final rows = await repo.listDiaries();
      expect(rows.length, 1);
      expect(rows.single.id, diary.id);
    });

    test('导出 Markdown 可读且包含日期与来源', () async {
      await create(content: '第一篇正文');
      await create(
        date: DateTime(2026, 5, 21),
        content: '第二篇正文',
        origin: DiaryOrigin.manual,
      );
      final markdown = await repo.exportMarkdown();
      expect(markdown, contains('# 泡泡日记'));
      expect(markdown, contains('2026年05月20日'));
      expect(markdown, contains('第一篇正文'));
      expect(markdown, contains('AI 整理'));
      expect(markdown, contains('你补写'));
    });

    test('月历标记按天返回', () async {
      await create(date: DateTime(2026, 5, 20));
      await create(date: DateTime(2026, 5, 20), origin: DiaryOrigin.manual);
      final marks = await repo.dayMarks(year: 2026, month: 5);
      expect(marks.length, 2);
      final groups = DiaryRules.groupByMonth(marks);
      expect(groups.single.count, 2);
      expect(groups.single.days[20]!.count, 2);
      expect(groups.single.days[20]!.origin, DiaryOrigin.manual);
    });
  });
}
