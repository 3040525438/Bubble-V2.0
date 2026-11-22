// 消息状态机单测（T2.4）
import 'package:bubble/domain/chat/message_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('canTransitionMessageStatus', () {
    test('同状态幂等写入合法', () {
      for (final status in MessageStatuses.all) {
        expect(canTransitionMessageStatus(status, status), isTrue);
      }
    });

    test('正常流转链', () {
      expect(canTransitionMessageStatus(
          MessageStatuses.sending, MessageStatuses.streaming), isTrue);
      expect(canTransitionMessageStatus(
          MessageStatuses.streaming, MessageStatuses.sent), isTrue);
      expect(canTransitionMessageStatus(
          MessageStatuses.streaming, MessageStatuses.interrupted), isTrue);
      expect(canTransitionMessageStatus(
          MessageStatuses.streaming, MessageStatuses.failed), isTrue);
    });

    test('失败可重试，停止可继续', () {
      expect(canTransitionMessageStatus(
          MessageStatuses.failed, MessageStatuses.sending), isTrue);
      expect(canTransitionMessageStatus(
          MessageStatuses.interrupted, MessageStatuses.streaming), isTrue);
    });

    test('终态不可回退', () {
      expect(canTransitionMessageStatus(
          MessageStatuses.sent, MessageStatuses.sending), isFalse);
      expect(canTransitionMessageStatus(
          MessageStatuses.sent, MessageStatuses.streaming), isFalse);
      expect(canTransitionMessageStatus(
          MessageStatuses.deleted, MessageStatuses.sent), isFalse);
    });

    test('未完成状态判定', () {
      expect(isUnfinishedStatus(MessageStatuses.sending), isTrue);
      expect(isUnfinishedStatus(MessageStatuses.streaming), isTrue);
      expect(isUnfinishedStatus(MessageStatuses.sent), isFalse);
      expect(isUnfinishedStatus(MessageStatuses.interrupted), isFalse);
    });

    test('状态中文文案齐备', () {
      for (final status in MessageStatuses.all) {
        expect(messageStatusLabel(status), isNotEmpty);
      }
      expect(chatErrorText('empty_reply'), contains('重试'));
    });
  });
}
