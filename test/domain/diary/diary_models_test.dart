// 日记领域单测（T11.1）：日期归档、版本保留、月历聚合、整理与导出。
import 'package:bubble/domain/diary/diary_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('日期与校验', () {
    test('dateKey / parseDateKey / displayDate 往返一致', () {
      final date = DateTime(2026, 5, 20);
      expect(DiaryRules.dateKey(date), '2026-05-20');
      expect(DiaryRules.parseDateKey('2026-05-20')?.day, 20);
      expect(DiaryRules.parseDateKey('2026-13-01'), isNull);
      expect(DiaryRules.displayDate('2026-05-20'), '2026年05月20日 周三');
    });

    test('空内容与超长内容被拒绝', () {
      expect(
        DiaryRules.validateDraft(
          DiaryDraft(entryDate: DateTime(2026, 5, 20), content: '  '),
        ),
        '日记内容不能为空',
      );
      expect(
        DiaryRules.validateDraft(
          DiaryDraft(
            entryDate: DateTime(2026, 5, 20),
            content: '字' * (DiaryRules.maxLength + 1),
          ),
        ),
        contains('不超过'),
      );
    });

    test('标题取正文首个非空行并截断', () {
      expect(DiaryRules.deriveTitle('\n 今天很好\n第二行'), '今天很好');
      expect(DiaryRules.deriveTitle('   '), '无题');
      final long = DiaryRules.deriveTitle('这是一个非常非常长的标题' * 3);
      expect(long.endsWith('…'), isTrue);
    });
  });

  group('版本保留', () {
    test('追加版本保持顺序', () {
      final first = DiaryRules.appendVersion(
        const <DiaryVersion>[],
        const DiaryVersion(
          savedAtMs: 1,
          content: '第一版',
          origin: DiaryOrigin.aiOrganized,
        ),
      );
      final second = DiaryRules.appendVersion(
        first,
        const DiaryVersion(
          savedAtMs: 2,
          content: '第二版',
          origin: DiaryOrigin.manual,
        ),
      );
      expect(second.length, 2);
      expect(second.first.content, '第一版');
      expect(second.last.origin, DiaryOrigin.manual);
    });

    test('版本数量有上限且保留最近版本', () {
      var versions = <DiaryVersion>[];
      for (var i = 0; i < DiaryRules.maxVersions + 5; i++) {
        versions = DiaryRules.appendVersion(
          versions,
          DiaryVersion(
            savedAtMs: i,
            content: '版本$i',
            origin: DiaryOrigin.aiOrganized,
          ),
        );
      }
      expect(versions.length, DiaryRules.maxVersions);
      expect(versions.last.content, '版本${DiaryRules.maxVersions + 4}');
    });

    test('损坏的版本 JSON 不阻断页面', () {
      expect(DiaryRules.parseVersions('not-json'), isEmpty);
      expect(DiaryRules.parseVersions(null), isEmpty);
    });
  });

  group('月历聚合', () {
    test('按月分组、同日合并并优先展示补写来源', () {
      final groups = DiaryRules.groupByMonth(const [
        DiaryDayMark(dateKey: '2026-05-20', origin: DiaryOrigin.aiOrganized),
        DiaryDayMark(dateKey: '2026-05-20', origin: DiaryOrigin.manual),
        DiaryDayMark(dateKey: '2026-05-03', origin: DiaryOrigin.aiOrganized),
        DiaryDayMark(dateKey: '2026-04-30', origin: DiaryOrigin.manual),
      ]);
      expect(groups.length, 2);
      expect(groups.first.month, 5);
      expect(groups.first.count, 3);
      expect(groups.first.days[20]!.count, 2);
      expect(groups.first.days[20]!.origin, DiaryOrigin.manual);
      expect(groups.first.days[3]!.origin, DiaryOrigin.aiOrganized);
      expect(groups.last.month, 4);
      expect(groups.last.count, 1);
    });
  });

  group('整理与导出', () {
    test('提示词包含日期、素材与约束', () {
      final prompt = DiaryRules.buildOrganizePrompt(
        dateKey: '2026-05-20',
        materials: const [
          DiaryMaterial(id: 'm1', content: '你：今天去了咖啡店', timeLabel: '10:30'),
          DiaryMaterial(id: 'mem1', content: '她喜欢下雨天', kind: 'memory'),
        ],
      );
      expect(prompt, contains('2026年05月20日'));
      expect(prompt, contains('今天去了咖啡店'));
      expect(prompt, contains('她喜欢下雨天'));
      expect(prompt, contains('300~600'));
    });

    test('本地整理引用真实素材并标注非模型', () {
      final draft = DiaryRules.localOrganize(
        dateKey: '2026-05-20',
        materials: const [
          DiaryMaterial(id: 'm1', content: '你：今天去了咖啡店', kind: 'message'),
          DiaryMaterial(id: 'mem1', content: '她喜欢下雨天', kind: 'memory'),
        ],
      );
      expect(draft.fromModel, isFalse);
      expect(draft.content, contains('咖啡店'));
      expect(draft.content, contains('翻记忆'));
      expect(draft.relatedMessageIds, ['m1']);
      expect(draft.relatedMemoryIds, ['mem1']);
    });

    test('无素材时本地整理仍可读', () {
      final draft = DiaryRules.localOrganize(
        dateKey: '2026-05-20',
        materials: const [],
      );
      expect(draft.content, contains('安静'));
      expect(draft.relatedMessageIds, isEmpty);
    });

    test('导出 Markdown 按日期升序且包含来源', () {
      final markdown = DiaryRules.exportMarkdown(
        const [
          DiaryExportEntry(
            dateKey: '2026-05-21',
            content: '第二篇',
            origin: DiaryOrigin.manual,
          ),
          DiaryExportEntry(
            dateKey: '2026-05-20',
            content: '第一篇',
            origin: DiaryOrigin.aiOrganized,
          ),
        ],
        title: '测试日记',
        exportedAt: DateTime(2026, 5, 22),
      );
      expect(markdown, contains('# 测试日记'));
      expect(markdown, contains('2026年05月20日'));
      expect(markdown, contains('AI 整理'));
      expect(markdown, contains('你补写'));
      expect(markdown.indexOf('第一篇'), lessThan(markdown.indexOf('第二篇')));
    });

    test('空导出给出可读提示', () {
      final markdown = DiaryRules.exportMarkdown(const []);
      expect(markdown, contains('还没有日记'));
    });
  });
}
