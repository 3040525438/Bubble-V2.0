// 全局搜索纯模型测试（T14.1）：分区映射、片段截取、高亮切片。
import 'package:bubble/domain/search/search_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SearchDomain / SearchSection', () {
    test('六域 wire 往返解析', () {
      for (final domain in SearchDomain.values) {
        expect(SearchDomain.fromWire(domain.wire), domain);
      }
      expect(SearchDomain.fromWire('unknown'), isNull);
      expect(SearchDomain.fromWire(null), isNull);
    });

    test('日记/信件/经历合并为 journal 分区', () {
      expect(SearchSection.of(SearchDomain.diary), SearchSection.journal);
      expect(SearchSection.of(SearchDomain.letter), SearchSection.journal);
      expect(SearchSection.of(SearchDomain.experience), SearchSection.journal);
      expect(SearchSection.of(SearchDomain.chat), SearchSection.chat);
      expect(
        SearchSection.of(SearchDomain.attachment),
        SearchSection.attachment,
      );
    });
  });

  group('buildSnippet', () {
    test('命中词附近截取并带省略号', () {
      final text = '${'前文' * 40}咖啡店${'后文' * 40}';
      final snippet = buildSnippet(text, '咖啡店', window: 10, maxLength: 60);
      expect(snippet.contains('咖啡店'), isTrue);
      expect(snippet.startsWith('…'), isTrue);
      expect(snippet.endsWith('…'), isTrue);
    });

    test('未命中时退化为前段截断', () {
      final snippet = buildSnippet('这是一段没有任何关键词的文本内容', '不存在');
      expect(snippet.isNotEmpty, isTrue);
      expect(snippet.contains('不存在'), isFalse);
    });

    test('空文本返回空串', () {
      expect(buildSnippet('   ', '词'), '');
    });
  });

  group('highlightSpans', () {
    test('切分命中与非命中片段', () {
      final spans = highlightSpans('我喜欢咖啡和咖啡豆', ['咖啡']);
      final hits = spans.where((s) => s.hit).map((s) => s.text).toList();
      expect(hits, ['咖啡', '咖啡']);
      expect(spans.map((s) => s.text).join(), '我喜欢咖啡和咖啡豆');
    });

    test('无命中词返回单一非命中片段', () {
      final spans = highlightSpans('普通文本', const []);
      expect(spans, hasLength(1));
      expect(spans.first.hit, isFalse);
    });

    test('重叠命中按最长优先不重复标注', () {
      final spans = highlightSpans('DeepSeek 模型', ['Deep', 'DeepSeek']);
      final hits = spans.where((s) => s.hit).map((s) => s.text).toList();
      expect(hits, ['DeepSeek']);
    });
  });
}
