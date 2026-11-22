// 人格组装器测试（T4.2）：块顺序、反模板约束、样本上限与截断。
import 'package:bubble/domain/persona/persona_assembler.dart';
import 'package:bubble/domain/persona/persona_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const core = PersonaCoreFields(
    identity: '你是泡泡。',
    personality: '温柔。',
    values: '真诚。',
    relationship: '老朋友。',
    speakingStyle: '短句。',
    boundaries: '可以拒绝。',
  );

  test('核心块在最前，成长块其次，样本块在后', () {
    final prompt = PersonaAssembler.build(
      core: core,
      coreVersionNo: 12,
      growth: const PersonaGrowthValues({'称呼': '阿岚'}, updatedAt: '2026-11-20T02:00:00Z'),
      samples: const ['慢一点也没关系。'],
    );
    final coreIndex = prompt.indexOf('【核心人格 v12】');
    final growthIndex = prompt.indexOf('【成长人格】');
    final sampleIndex = prompt.indexOf('【表达风格参照');
    expect(coreIndex, 0);
    expect(growthIndex, greaterThan(coreIndex));
    expect(sampleIndex, greaterThan(growthIndex));
    expect(prompt, contains('称呼：阿岚'));
    expect(prompt, contains('2026-11-20'));
    expect(prompt, contains('慢一点也没关系。'));
  });

  test('核心六字段与反模板约束齐全', () {
    final prompt = PersonaAssembler.build(core: core, coreVersionNo: 1);
    for (final label in PersonaCoreFields.fieldLabels.values) {
      expect(prompt, contains('$label：'));
    }
    for (final rule in PersonaAssembler.antiTemplateRules) {
      expect(prompt, contains(rule));
    }
    // 没有成长/样本时也给出兜底说明
    expect(prompt, contains('暂无表达样本'));
  });

  test('样本最多 6 条、忽略空串、超长截断', () {
    final long = '长' * 200;
    final samples = <String>[
      long,
      '   ',
      for (var i = 1; i <= 7; i++) '句子 $i',
    ];
    final prompt = PersonaAssembler.build(
      core: core,
      coreVersionNo: 1,
      samples: samples,
    );
    // 空串被忽略；超长样本占 1 条，句子只取前 5 条
    expect(RegExp('句子 ').allMatches(prompt).length, 5);
    expect(prompt, isNot(contains('句子 6')));
    expect(prompt, contains('…'));
  });

  test('场景块仅在提供时追加到末尾', () {
    final withoutScene = PersonaAssembler.build(core: core, coreVersionNo: 1);
    expect(withoutScene, isNot(contains('【当前场景】')));

    final withScene = PersonaAssembler.build(
      core: core,
      coreVersionNo: 1,
      sceneNote: '当前会话：养植物计划。',
    );
    expect(withScene.indexOf('【当前场景】'),
        greaterThan(withScene.indexOf('【表达风格参照')));
  });

  test('成长值 JSON 往返与更新', () {
    final values = const PersonaGrowthValues({'称呼': '阿岚'})
        .withValue('口头禅', '好呀', at: DateTime.utc(2026, 11, 22));
    final parsed = PersonaGrowthValues.parse(values.toJsonString());
    expect(parsed.valueOf('称呼'), '阿岚');
    expect(parsed.valueOf('口头禅'), '好呀');
    expect(parsed.updatedAt, '2026-11-22T00:00:00.000Z');
    expect(parsed.isEmpty, isFalse);
    expect(const PersonaGrowthValues({}).isEmpty, isTrue);
  });
}
