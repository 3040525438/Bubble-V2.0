// bigram 分词器单测：中英文语料（DATABASE_DESIGN §2.30 规则）
import 'package:bubble/domain/search/tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('tokenize 中文', () {
    test('短句：单字 + 双字', () {
      final tokens = tokenize('泡泡');
      expect(tokens, containsAll(<String>['泡', '泡泡']));
      expect(tokens.length, 3); // 泡, 泡, 泡泡
    });

    test('三字词含全部双字', () {
      final tokens = tokenize('长期记忆');
      expect(tokens, containsAll(<String>['长', '期', '记忆', '期记', '长期']));
      expect(tokens.contains('忆'), isTrue);
    });

    test('标点分隔后重新分词', () {
      final tokens = tokenize('你好，泡泡！');
      expect(tokens, containsAll(<String>['你好', '你好'.split('')[0]]));
      expect(tokens.any((t) => t.contains('，')), isFalse);
    });

    test('中英混合', () {
      final tokens = tokenize('泡泡是我的AI伴侣');
      expect(tokens, contains('ai'));
      expect(tokens, contains('泡泡'));
      expect(tokens, contains('伴侣'));
    });

    test('数字串整词', () {
      final tokens = tokenize('纪念日2026年11月');
      expect(tokens, contains('2026'));
      expect(tokens, contains('11'));
    });

    test('emoji 被过滤', () {
      final tokens = tokenize('😀开心');
      expect(tokens.every((t) => !t.contains('😀')), isTrue);
      expect(tokens, contains('开心'));
    });

    test('空串与空白', () {
      expect(tokenize(''), isEmpty);
      expect(tokenize('   '), isEmpty);
    });

    test('繁简混杂按字符处理', () {
      final tokens = tokenize('記憶');
      expect(tokens, contains('記憶'));
    });
  });

  group('tokenize 拉丁', () {
    test('英文单词小写化', () {
      final tokens = tokenize('Hello World');
      expect(tokens, ['hello', 'world']);
    });

    test('连字符分隔', () {
      final tokens = tokenize('e-mail');
      expect(tokens, ['e', 'mail']);
    });

    test('大写缩写', () {
      expect(tokenize('DeepSeek API'), containsAll(<String>['deepseek', 'api']));
    });
  });

  group('similarityTokens（相似度输入）', () {
    test('CJK 单字不参与', () {
      final s = similarityTokens('我');
      expect(s, isEmpty); // 仅 1 字 CJK 不参与
    });

    test('双字 CJK 与拉丁词参与', () {
      final s = similarityTokens('泡泡 AI');
      expect(s, contains('泡泡'));
      expect(s, contains('ai'));
      expect(s, isNot(contains('泡')));
    });
  });

  group('overlapCoefficient 重叠系数', () {
    test('完全一致 = 1', () {
      final a = similarityTokens('长期记忆系统');
      final b = similarityTokens('长期记忆系统');
      expect(overlapCoefficient(a, b), 1.0);
    });

    test('部分重叠 ∈ (0,1)', () {
      final a = similarityTokens('长期记忆系统');
      final b = similarityTokens('记忆检索');
      final c = overlapCoefficient(a, b);
      expect(c, greaterThan(0));
      expect(c, lessThan(1));
    });

    test('无重叠 = 0', () {
      final a = similarityTokens('长期记忆');
      final b = similarityTokens('说说内容');
      // 注意单字不含于相似度集合，两集合应无交集
      expect(overlapCoefficient(a, b), 0);
    });

    test('空集合 = 0', () {
      expect(overlapCoefficient(<String>{}, <String>{'ai'}), 0);
      expect(overlapCoefficient(<String>{}, <String>{}), 0);
    });
  });

  group('语料冒烟（阶段 1 快速集；≥100 例全集在阶段 5 T5.7）', () {
    const corpus = [
      '我喜欢在清晨喝一杯咖啡',
      '今天和小泡聊了关于工作计划的事',
      'User prefers dark theme at night',
      '泡泡记得我的生日是1998年3月',
      'Agreement: weekly review every Sunday',
    ];
    test('全部语料可分词且非空', () {
      for (final text in corpus) {
        final tokens = tokenize(text);
        expect(tokens, isNotEmpty, reason: text);
        expect(tokens.every((t) => t.isNotEmpty), isTrue);
      }
    });
  });
}
