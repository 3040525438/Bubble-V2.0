// 反馈纯模型测试（T14.2）：枚举解析与输入校验规则。
import 'package:bubble/domain/feedback/feedback_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('枚举解析', () {
    test('六类反馈目标 wire 往返', () {
      expect(FeedbackTargetKind.values, hasLength(6));
      for (final kind in FeedbackTargetKind.values) {
        expect(FeedbackTargetKind.fromWire(kind.wire), kind);
      }
      expect(FeedbackTargetKind.fromWire('nope'), isNull);
    });

    test('四种态度 wire 往返', () {
      expect(FeedbackVerdict.values, hasLength(4));
      for (final verdict in FeedbackVerdict.values) {
        expect(FeedbackVerdict.fromWire(verdict.wire), verdict);
      }
    });
  });

  group('validateFeedback', () {
    test('目标为空报错', () {
      expect(
        validateFeedback(
          kind: FeedbackTargetKind.post,
          targetId: '  ',
          verdict: FeedbackVerdict.like,
        ),
        isNotNull,
      );
    });

    test('纠正必须填写内容', () {
      expect(
        validateFeedback(
          kind: FeedbackTargetKind.memoryCorrection,
          targetId: 'mem_1',
          verdict: FeedbackVerdict.correct,
        ),
        contains('纠正'),
      );
      expect(
        validateFeedback(
          kind: FeedbackTargetKind.memoryCorrection,
          targetId: 'mem_1',
          verdict: FeedbackVerdict.correct,
          note: '这里记错了',
        ),
        isNull,
      );
    });

    test('备注超长报错', () {
      expect(
        validateFeedback(
          kind: FeedbackTargetKind.post,
          targetId: 'post_1',
          verdict: FeedbackVerdict.adjust,
          note: '字' * 501,
        ),
        isNotNull,
      );
    });

    test('合法输入通过', () {
      expect(
        validateFeedback(
          kind: FeedbackTargetKind.post,
          targetId: 'post_1',
          verdict: FeedbackVerdict.like,
        ),
        isNull,
      );
    });
  });

  group('FeedbackEntry', () {
    test('撤销状态与时间解析', () {
      final entry = FeedbackEntry(
        id: 'fb_1',
        targetKind: FeedbackTargetKind.post,
        targetId: 'post_1',
        verdict: FeedbackVerdict.like,
        createdAt: '2026-11-20T02:00:00.000Z',
      );
      expect(entry.isReverted, isFalse);
      expect(entry.createdAtTime, isNotNull);
    });
  });
}
