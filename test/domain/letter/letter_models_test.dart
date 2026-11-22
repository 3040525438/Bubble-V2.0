// 信件领域单测（T11.2）：双向、草稿/寄出、7 天冷却与本地降级。
import 'package:bubble/domain/letter/letter_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('校验与标题', () {
    test('空内容与超长内容被拒绝', () {
      expect(
        LetterRules.validateDraft(
          const LetterDraft(
            direction: LetterDirection.userToBubble,
            content: '   ',
          ),
        ),
        '信的内容不能为空',
      );
      expect(
        LetterRules.validateDraft(
          LetterDraft(
            direction: LetterDirection.userToBubble,
            content: '字' * (LetterRules.maxLength + 1),
          ),
        ),
        contains('不超过'),
      );
    });

    test('标题取首行并截断', () {
      expect(LetterRules.deriveTitle('想你了\n后面'), '想你了');
      expect(LetterRules.deriveTitle(''), '一封信');
      expect(LetterRules.deriveTitle('很长的一行字' * 6).endsWith('…'), isTrue);
    });

    test('方向与落款行', () {
      expect(LetterDirection.bubbleToUser.routeLabel, '泡泡 → 你');
      expect(LetterDirection.userToBubble.routeLabel, '你 → 泡泡');
      expect(LetterDirection.fromWire('bad'), LetterDirection.bubbleToUser);
    });
  });

  group('7 天冷却', () {
    final now = DateTime(2026, 5, 20, 12).millisecondsSinceEpoch;

    test('没有历史信件时可以写', () {
      expect(LetterRules.canBubbleSend(lastSentAtMs: null, nowMs: now), isTrue);
    });

    test('不足 7 天时不能写，满 7 天可以写', () {
      final sixDays = now - 6 * 24 * 60 * 60 * 1000;
      final sevenDays = now - LetterRules.cooldownMs;
      expect(
        LetterRules.canBubbleSend(lastSentAtMs: sixDays, nowMs: now),
        isFalse,
      );
      expect(
        LetterRules.canBubbleSend(lastSentAtMs: sevenDays, nowMs: now),
        isTrue,
      );
    });

    test('下次可写时间与文案', () {
      final last = DateTime(2026, 5, 20, 10).millisecondsSinceEpoch;
      final next = LetterRules.nextBubbleSendAtMs(last);
      expect(next - last, LetterRules.cooldownMs);
      expect(LetterRules.cooldownLabel(next), '5月27日');
    });
  });

  group('筛选', () {
    test('四种筛选与方向和状态匹配', () {
      expect(
        LetterFilter.all.matches(
          LetterDirection.bubbleToUser,
          LetterState.sent,
        ),
        isTrue,
      );
      expect(
        LetterFilter.fromBubble.matches(
          LetterDirection.bubbleToUser,
          LetterState.draft,
        ),
        isTrue,
      );
      expect(
        LetterFilter.fromBubble.matches(
          LetterDirection.userToBubble,
          LetterState.sent,
        ),
        isFalse,
      );
      expect(
        LetterFilter.fromUser.matches(
          LetterDirection.userToBubble,
          LetterState.sent,
        ),
        isTrue,
      );
      expect(
        LetterFilter.drafts.matches(
          LetterDirection.userToBubble,
          LetterState.draft,
        ),
        isTrue,
      );
      expect(
        LetterFilter.drafts.matches(
          LetterDirection.userToBubble,
          LetterState.sent,
        ),
        isFalse,
      );
    });
  });

  group('生成', () {
    test('提示词包含素材、最近信件与约束', () {
      final prompt = LetterRules.buildComposePrompt(
        materials: const [
          LetterMaterial(
            id: 'exp1',
            title: '第一次一起看海',
            summary: '在傍晚的海边走了很久',
            kind: 'experience',
          ),
          LetterMaterial(id: 'mem1', title: '桂花', summary: '她喜欢桂花味'),
        ],
        recentLetters: const ['上一封信'],
      );
      expect(prompt, contains('第一次一起看海'));
      expect(prompt, contains('桂花'));
      expect(prompt, contains('上一封信'));
      expect(prompt, contains('400~800'));
      expect(prompt, contains('不要写落款'));
    });

    test('本地降级信引用真实素材且不冒充模型', () {
      final draft = LetterRules.localCompose(
        materials: const [
          LetterMaterial(
            id: 'exp1',
            title: '第一次一起看海',
            summary: '在傍晚的海边走了很久',
            kind: 'experience',
          ),
          LetterMaterial(id: 'mem1', title: '桂花', summary: '她喜欢桂花味'),
        ],
      );
      expect(draft.fromModel, isFalse);
      expect(draft.content, contains('第一次一起看海'));
      expect(draft.content, contains('桂花味'));
      expect(draft.relatedExperienceIds, ['exp1']);
      expect(draft.relatedMemoryIds, ['mem1']);
      expect(draft.title, contains('第一次一起看海'));
    });

    test('没有素材时也能写出一封完整的信', () {
      final draft = LetterRules.localCompose(materials: const []);
      expect(draft.content, contains('展信安'));
      expect(draft.content.length, greaterThan(30));
      expect(draft.relatedMemoryIds, isEmpty);
      expect(draft.relatedExperienceIds, isEmpty);
    });
  });

  test('decodeIds 容错', () {
    expect(LetterRules.decodeIds('["a","b"]'), ['a', 'b']);
    expect(LetterRules.decodeIds(null), isEmpty);
    expect(LetterRules.decodeIds('bad'), isEmpty);
  });
}
