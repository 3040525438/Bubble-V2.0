// 通知领域单测（T13.3/T13.5）：隐私渲染、勿扰顺延、上限、深链与 ID 稳定性。
import 'package:bubble/domain/notification/notification_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('隐私三档渲染', () {
    const text = '今天的云像棉花糖，你那边也在下雨吗？';

    test('full：标题带来源、正文为摘要', () {
      final content = renderNotification(
        privacy: NotificationPrivacy.full,
        sourceLabel: '新消息',
        messageText: text,
      );
      expect(content.title, '泡泡 · 新消息');
      expect(content.body, text);
      expect(content.subtitle, '新消息');
    });

    test('minimal：只提示有新消息，不泄露内容', () {
      final content = renderNotification(
        privacy: NotificationPrivacy.minimal,
        sourceLabel: '新消息',
        messageText: text,
      );
      expect(content.title, '泡泡有新消息');
      expect(content.body, isEmpty);
      expect(content.title.contains('云'), isFalse);
    });

    test('hidden：仅应用名，无标题正文细节', () {
      final content = renderNotification(
        privacy: NotificationPrivacy.hidden,
        sourceLabel: '日记',
        messageText: text,
      );
      expect(content.title, '泡泡');
      expect(content.body, isEmpty);
    });

    test('超长摘要截断为 60 字', () {
      final content = renderNotification(
        privacy: NotificationPrivacy.full,
        sourceLabel: '新消息',
        messageText: '啊' * 100,
      );
      expect(content.body.length, 61); // 60 字 + 省略号
      expect(content.body.endsWith('…'), isTrue);
    });

    test('空内容回退为温和提示', () {
      final content = renderNotification(
        privacy: NotificationPrivacy.full,
        sourceLabel: '新消息',
        messageText: '  ',
      );
      expect(content.body, '想和你说句话');
    });

    test('wire 解析回退 minimal', () {
      expect(NotificationPrivacy.fromWire('full'), NotificationPrivacy.full);
      expect(
        NotificationPrivacy.fromWire('hidden'),
        NotificationPrivacy.hidden,
      );
      expect(
        NotificationPrivacy.fromWire('unknown'),
        NotificationPrivacy.minimal,
      );
      expect(NotificationPrivacy.fromWire(null), NotificationPrivacy.minimal);
    });
  });

  group('勿扰策略', () {
    test('跨午夜窗口 23:00–08:00', () {
      expect(
        NotificationPolicy.inQuietHours(
          DateTime(2026, 5, 20, 23, 30),
          '23:00',
          '08:00',
        ),
        isTrue,
      );
      expect(
        NotificationPolicy.inQuietHours(
          DateTime(2026, 5, 21, 7, 0),
          '23:00',
          '08:00',
        ),
        isTrue,
      );
      expect(
        NotificationPolicy.inQuietHours(
          DateTime(2026, 5, 21, 12, 0),
          '23:00',
          '08:00',
        ),
        isFalse,
      );
      expect(
        NotificationPolicy.inQuietHours(
          DateTime(2026, 5, 21, 8, 0),
          '23:00',
          '08:00',
        ),
        isFalse,
      );
    });

    test('非跨午夜窗口 12:00–14:00', () {
      expect(
        NotificationPolicy.inQuietHours(
          DateTime(2026, 5, 21, 13, 0),
          '12:00',
          '14:00',
        ),
        isTrue,
      );
      expect(
        NotificationPolicy.inQuietHours(
          DateTime(2026, 5, 21, 15, 0),
          '12:00',
          '14:00',
        ),
        isFalse,
      );
    });

    test('顺延：深夜顺延到次日早晨，凌晨顺延到当天早晨', () {
      final night = NotificationPolicy.deferOutOfQuietHours(
        DateTime(2026, 5, 20, 23, 30),
        '23:00',
        '08:00',
      );
      expect(night, DateTime(2026, 5, 21, 8, 0));

      final early = NotificationPolicy.deferOutOfQuietHours(
        DateTime(2026, 5, 21, 6, 30),
        '23:00',
        '08:00',
      );
      expect(early, DateTime(2026, 5, 21, 8, 0));
    });

    test('窗口外保持不变', () {
      final at = DateTime(2026, 5, 21, 12, 0);
      expect(NotificationPolicy.deferOutOfQuietHours(at, '23:00', '08:00'), at);
    });

    test('非法时间格式不生效（不误判为勿扰）', () {
      final at = DateTime(2026, 5, 21, 12, 0);
      expect(NotificationPolicy.inQuietHours(at, '25:00', '08:00'), isFalse);
      expect(NotificationPolicy.deferOutOfQuietHours(at, 'bad', '08:00'), at);
    });
  });

  group('上限与过期', () {
    test('每日上限', () {
      expect(NotificationPolicy.exceedsDailyCap(0, 3), isFalse);
      expect(NotificationPolicy.exceedsDailyCap(2, 3), isFalse);
      expect(NotificationPolicy.exceedsDailyCap(3, 3), isTrue);
      expect(NotificationPolicy.exceedsDailyCap(0, 0), isTrue);
    });

    test('过期判定（空不过期）', () {
      final now = DateTime(2026, 5, 21, 12);
      expect(NotificationPolicy.isExpired(null, now), isFalse);
      expect(
        NotificationPolicy.isExpired(
          now.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
          now,
        ),
        isTrue,
      );
      expect(
        NotificationPolicy.isExpired(
          now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
          now,
        ),
        isFalse,
      );
    });

    test('时区变化判定', () {
      expect(
        NotificationPolicy.timezoneChanged('Asia/Shanghai', 'Asia/Shanghai'),
        isFalse,
      );
      expect(
        NotificationPolicy.timezoneChanged('Asia/Shanghai', 'Europe/Berlin'),
        isTrue,
      );
      expect(
        NotificationPolicy.timezoneChanged(null, 'Europe/Berlin'),
        isFalse,
      );
    });
  });

  group('深链载荷与通知 id', () {
    test('聊天深链带 focus，其他来源跳详情', () {
      final chat = NotificationPayload(
        type: 'chat',
        conversationId: 'c1',
        messageId: 'm1',
      );
      expect(chat.routePath, '/chat/c1?focus=m1');
      expect(
        NotificationPayload(type: 'chat', conversationId: 'c1').routePath,
        '/chat/c1',
      );
      expect(
        NotificationPayload(type: 'post', targetId: 'p1').routePath,
        '/post/p1',
      );
      expect(
        NotificationPayload(type: 'diary', targetId: 'd1').routePath,
        '/diary/d1',
      );
      expect(
        NotificationPayload(type: 'letter', targetId: 'l1').routePath,
        '/letters/l1',
      );
      expect(NotificationPayload(type: 'chat').routePath, isNull);
      expect(
        NotificationPayload(type: 'unknown', targetId: 'x').routePath,
        isNull,
      );
    });

    test('载荷 JSON 编解码往返；坏数据返回 null', () {
      final payload = NotificationPayload(
        type: 'chat',
        conversationId: 'c1',
        messageId: 'm1',
      );
      final decoded = NotificationPayload.tryDecode(payload.encode())!;
      expect(decoded.type, 'chat');
      expect(decoded.conversationId, 'c1');
      expect(decoded.messageId, 'm1');
      expect(NotificationPayload.tryDecode(null), isNull);
      expect(NotificationPayload.tryDecode(''), isNull);
      expect(NotificationPayload.tryDecode('{bad json'), isNull);
      expect(NotificationPayload.tryDecode('{"type":""}'), isNull);
    });

    test('同一 UUID 的 int id 稳定且在 31 位内', () {
      final a = NotificationPolicy.notificationIntId('abc-123');
      final b = NotificationPolicy.notificationIntId('abc-123');
      expect(a, b);
      expect(a, greaterThanOrEqualTo(0));
      expect(a, lessThan(0x7fffffff));
      expect(
        NotificationPolicy.notificationIntId('abc-123'),
        isNot(NotificationPolicy.notificationIntId('abc-124')),
      );
    });
  });

  group('通知设置', () {
    test('默认值与类别开关', () {
      const settings = NotificationSettings();
      expect(settings.privacyMode, NotificationPrivacy.minimal);
      expect(settings.dailyNotifyCap, 10);
      expect(settings.quietStart, '23:00');
      expect(settings.quietEnd, '08:00');
      expect(settings.allowsKind('chat'), isTrue);
      expect(
        settings.copyWith(allowPostNotify: false).allowsKind('post'),
        isFalse,
      );
      expect(
        settings.copyWith(allowDiaryLetterNotify: false).allowsKind('diary'),
        isFalse,
      );
      expect(
        settings.copyWith(allowDiaryLetterNotify: false).allowsKind('letter'),
        isFalse,
      );
    });
  });
}
