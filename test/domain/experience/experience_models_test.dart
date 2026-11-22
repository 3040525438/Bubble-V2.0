// 共同经历领域规则单测（T9.1）：历史事实防改、视角建议、回顾只追加。
import 'package:bubble/domain/experience/experience_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ExperienceDraft draft({
    String name = '第一次一起看雪',
    String content = '那天我们在西湖边看到今年第一场雪',
    int occurredAtMs = 1735689600000,
    int importance = 70,
  }) {
    return ExperienceDraft(
      name: name,
      occurredAtMs: occurredAtMs,
      eventContent: content,
      importance: importance,
    );
  }

  group('草稿校验', () {
    test('合法草稿通过', () {
      expect(ExperienceRules.validateDraft(draft()), isNull);
    });

    test('空白名称/内容/时间/重要度被拒绝', () {
      expect(ExperienceRules.validateDraft(draft(name: '   ')), '经历名称不能为空');
      expect(ExperienceRules.validateDraft(draft(content: '  ')), '发生的事不能为空');
      expect(ExperienceRules.validateDraft(draft(occurredAtMs: 0)), '发生时间无效');
      expect(
        ExperienceRules.validateDraft(draft(importance: 120)),
        '重要程度需在 0~100',
      );
    });
  });

  group('回顾记录只追加', () {
    final first = ExperienceReviewEntry(
      atMs: 1000,
      content: '第一次回看',
      author: 'bubble',
    );

    test('追加返回新列表且保留旧记录', () {
      final original = <ExperienceReviewEntry>[first];
      final next = ExperienceRules.appendReview(
        original,
        const ExperienceReviewEntry(
          atMs: 2000,
          content: '第二次回看',
          author: 'user',
        ),
      );
      expect(next.length, 2);
      expect(next.first.content, '第一次回看');
      expect(next.last.content, '第二次回看');
      expect(original.length, 1, reason: '原列表不应被修改');
    });

    test('空白内容与超长内容被拒绝', () {
      expect(
        () => ExperienceRules.appendReview(
          originalOrEmpty(),
          const ExperienceReviewEntry(
            atMs: 3000,
            content: '   ',
            author: 'user',
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => ExperienceRules.appendReview(
          originalOrEmpty(),
          ExperienceReviewEntry(atMs: 3000, content: '很' * 501, author: 'user'),
        ),
        throwsArgumentError,
      );
    });

    test('内容首尾空白会被清理后保存', () {
      final next = ExperienceRules.appendReview(
        originalOrEmpty(),
        const ExperienceReviewEntry(
          atMs: 3000,
          content: '  那天真的很开心  ',
          author: 'user',
        ),
      );
      expect(next.single.content, '那天真的很开心');
    });

    test('损坏 JSON 不抛异常且返回空列表', () {
      expect(ExperienceRules.parseReviewLog('{坏的'), isEmpty);
      expect(ExperienceRules.parseReviewLog(null), isEmpty);
      expect(ExperienceRules.parseReviewLog('[]'), isEmpty);
    });

    test('编码后可完整解析', () {
      final encoded = ExperienceRules.encodeReviewLog([first, first]);
      final parsed = ExperienceRules.parseReviewLog(encoded);
      expect(parsed.length, 2);
      expect(parsed.first.author, 'bubble');
    });
  });

  group('历史事实防改', () {
    test('视角建议只改文本，不触碰事实', () {
      const facts = ExperienceFacts(
        name: '第一次一起看雪',
        occurredAtMs: 1735689600000,
        eventContent: '那天我们在西湖边看到今年第一场雪',
      );
      final suggestion = ExperienceRules.proposePerspective(
        '觉得冷但很开心',
        '泡泡觉得那是很安静的一天',
      );
      expect(suggestion, '泡泡觉得那是很安静的一天');
      expect(facts.name, '第一次一起看雪');
      expect(facts.eventContent, '那天我们在西湖边看到今年第一场雪');
    });

    test('空建议不覆盖已有视角', () {
      expect(ExperienceRules.proposePerspective('原来的视角', '   '), '原来的视角');
    });

    test('事实一致性校验能识别篡改', () {
      const before = ExperienceFacts(
        name: '一起看雪',
        occurredAtMs: 100,
        eventContent: '真实发生的事',
      );
      expect(
        ExperienceRules.factsUnchanged(
          before,
          const ExperienceFacts(
            name: '一起看雪',
            occurredAtMs: 100,
            eventContent: '真实发生的事',
          ),
        ),
        isTrue,
      );
      expect(
        ExperienceRules.factsUnchanged(
          before,
          const ExperienceFacts(
            name: '一起看雪',
            occurredAtMs: 100,
            eventContent: '编造的事',
          ),
        ),
        isFalse,
      );
    });

    test('提名转草稿保留来源记忆引用', () {
      const nomination = ExperienceNomination(
        sourceKind: 'memory',
        sourceId: 'mem_1',
        suggestedName: '一起看雪',
        occurredAtMs: 100,
        eventContent: '真实发生的事',
        reason: '值得记住',
        importance: 80,
        relatedMemoryIds: ['mem_1'],
      );
      final draft = nomination.toDraft();
      expect(draft.name, '一起看雪');
      expect(draft.importance, 80);
      expect(draft.relatedMemoryIds, ['mem_1']);
    });
  });

  test('锁条文案包含不可修改说明', () {
    expect(ExperienceRules.factLockNote, contains('不可修改'));
    expect(ExperienceRules.factLockNote, contains('只追加'));
  });
}

List<ExperienceReviewEntry> originalOrEmpty() =>
    const <ExperienceReviewEntry>[];
