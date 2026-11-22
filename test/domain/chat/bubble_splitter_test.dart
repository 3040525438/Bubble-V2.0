// 连续多气泡拆分单测（T2.4）
import 'package:bubble/domain/chat/bubble_splitter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('splitReplySegments', () {
    test('空内容返回空列表', () {
      expect(splitReplySegments(''), isEmpty);
      expect(splitReplySegments('   \n '), isEmpty);
    });

    test('空行是显式分段标记', () {
      final segments = splitReplySegments('第一段内容\n\n第二段内容');
      expect(segments, ['第一段内容', '第二段内容']);
    });

    test('单段过长按句末标点拆分', () {
      final long = List.generate(8, (i) => '这是第${i + 1}句比较长的中文内容用来凑字数。').join();
      final segments = splitReplySegments(long);
      expect(segments.length, greaterThan(1));
      for (final s in segments) {
        expect(s.trim(), isNotEmpty);
      }
    });

    test('过短段落合并到前一段', () {
      final segments = splitReplySegments('这是一段正常长度的内容。\n\n嗯');
      expect(segments.length, 1);
      expect(segments.single, contains('嗯'));
    });

    test('超过最大条数时合并尾部', () {
      final text = List.generate(6, (i) => '第$i段完整内容如下').join('\n\n');
      final segments = splitReplySegments(text, maxSegments: 3);
      expect(segments.length, 3);
    });

    test('无标点的超长文本硬切', () {
      final text = '啊' * 400;
      final segments =
          splitReplySegments(text, softMaxLength: 80, maxSegments: 8);
      expect(segments.length, greaterThan(1));
      expect(segments.join(), text);
    });
  });
}
