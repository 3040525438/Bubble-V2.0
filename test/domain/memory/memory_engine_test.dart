// 记忆引擎单测（T5.1）：规则提取、噪声、机密扫描、敏感降级、grounding 与比较决策。
import 'package:bubble/domain/memory/memory_engine.dart';
import 'package:bubble/domain/memory/memory_models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fixtures/memory_corpus.dart';

MemoryDraft _draft({
  String type = 'profile',
  String title = '',
  String summary = '',
  MemoryConfidence confidence = MemoryConfidence.high,
  List<String> sensitive = const <String>[],
}) {
  return MemoryDraft(
    type: MemoryType.fromWire(type) ?? MemoryType.profile,
    title: title,
    summary: summary,
    confidence: confidence,
    importance: 60,
    evidence: summary,
    rawText: summary,
    sensitiveCategories: sensitive,
  );
}

ExistingMemoryBrief _existing(String id, String summary,
    {String type = 'profile', String status = 'active'}) {
  return ExistingMemoryBrief(
    id: id,
    type: type,
    summary: summary,
    confidence: 'high',
    status: status,
  );
}

void main() {
  const engine = MemoryEngine();

  group('中文语料提取', () {
    test('100 例语料类型命中率 ≥95%，噪声全部过滤', () {
      var correct = 0;
      var noiseCorrect = 0;
      for (final item in memoryCorpus) {
        final draft = engine.extract(item.text);
        if (item.noise) {
          if (draft == null) noiseCorrect++;
          continue;
        }
        if (draft != null && draft.type.wire == item.type) correct++;
      }
      expect(correct / 90, greaterThanOrEqualTo(0.95));
      expect(noiseCorrect, 10);
    });

    test('显式“记住：”是最高优先级偏好且置信度高', () {
      final draft = engine.extract('记住：我不喝冰的');
      expect(draft, isNotNull);
      expect(draft!.type, MemoryType.preference);
      expect(draft.confidence, MemoryConfidence.high);
      expect(draft.summary.contains('不喝冰的'), isTrue);
    });

    test('观点变化标记与共同经历提名', () {
      final opinion = engine.extract('以前我觉得独处很好，现在发现有人陪也不错。');
      expect(opinion!.type, MemoryType.opinion);
      expect(opinion.opinionChange, isTrue);

      final joint = engine.extract('上次我们一起熬夜赶方案。');
      expect(joint!.type, MemoryType.experienceJoint);
      expect(joint.sharedExperience, isTrue);
    });

    test('敏感信息降级为最多 medium，只能进待确认', () {
      final draft = engine.extract('记住：我最近住院做手术');
      expect(draft, isNotNull);
      expect(draft!.sensitive, isTrue);
      expect(draft.confidence.rank,
          lessThanOrEqualTo(MemoryConfidence.medium.rank));
    });

    test('寒暄/表情/单字回应判为噪声', () {
      for (final text in ['嗯嗯', '哈哈', '好的', '在吗', '😊😊', '。。。']) {
        expect(engine.isNoise(text), isTrue, reason: text);
      }
      expect(engine.isNoise('我喜欢喝咖啡'), isFalse);
    });
  });

  group('机密扫描（11 类）', () {
    test('密码/API Key/私钥/银行卡/身份证等 high 命中整条拒绝', () {
      final privateKeyHeader = '-----BEGIN '
          'RSA '
          'PRIVATE KEY-----';
      final skStyle = 'sk'
          '-abcdefghijklmnop';
      final cases = <String>[
        '我的密码是 abc12345',
        'api_key = sk1234567890abcd',
        privateKeyHeader,
        '我的银行卡号 6222021234567890123',
        '身份证号 110101199001011234',
        '我的密钥是 abcdefg',
        'token: abcdefgh12345',
        skStyle,
        'https://user:pass@example.com/path',
      ];
      for (final text in cases) {
        final result = engine.scanSecrets(text);
        expect(result.findings, isNotEmpty, reason: text);
        expect(result.hasHigh, isTrue, reason: text);
        expect(result.rejected, isTrue, reason: text);
      }
    });

    test('手机号/邮箱为 low：脱敏保留，不拒绝整条', () {
      final text = '我的手机号是 13800138000，平时工作比较忙，晚上再联系我';
      final result = engine.scanSecrets(text);
      expect(result.hasHigh, isFalse);
      expect(result.rejected, isFalse);
      expect(result.maskedText.contains('13800138000'), isFalse);
      expect(result.maskedText.contains('已脱敏'), isTrue);

      final email = engine.scanSecrets('我的邮箱是 linyu@example.com，有事可以发邮件给我，白天回复');
      expect(email.rejected, isFalse);
      expect(email.maskedText.contains('linyu@example.com'), isFalse);
    });

    test('机密占比 ≥50% 时整条拒绝', () {
      final result = engine.scanSecrets('13800138000 13800138000 13800138000');
      expect(result.rejected, isTrue);
      expect(result.coverage, greaterThanOrEqualTo(0.5));
    });

    test('重叠 span 合并为一条', () {
      final result = engine.scanSecrets('密码是 abcdefgh123456');
      expect(result.findings.length, 1);
      expect(result.findings.first.isHigh, isTrue);
    });
  });

  group('敏感类别扫描', () {
    test('健康/财务/身份/关系/法律五类识别', () {
      expect(engine.scanSensitivity('我最近在做体检，医生说要休息').categories,
          contains('健康'));
      expect(engine.scanSensitivity('这个月工资还没发，房贷压力大').categories,
          contains('财务'));
      expect(engine.scanSensitivity('我的身份证放在抽屉里').categories,
          contains('身份'));
      expect(engine.scanSensitivity('我和前任已经分手了').categories, contains('关系'));
      expect(engine.scanSensitivity('公司有官司，律师在准备材料').categories,
          contains('法律'));
    });

    test('普通内容不标记敏感', () {
      expect(engine.scanSensitivity('我喜欢在周末去西湖边散步').flagged, isFalse);
    });
  });

  group('grounding 校验', () {
    test('原文定位不到的主张降为 low', () {
      final draft = _draft(summary: '我喜欢喝手冲咖啡');
      final confidence = engine.groundConfidence(
        draft.copyWith(rawText: '今天天气不错，适合出门走走'),
      );
      expect(confidence, MemoryConfidence.low);
    });

    test('仅助手回复佐证时最多 medium', () {
      final draft = _draft(summary: '我喜欢喝手冲咖啡');
      final confidence = engine.groundConfidence(
        draft.copyWith(rawText: '今天天气不错，适合出门走走'),
        assistantText: '我记得你喜欢喝手冲咖啡',
      );
      expect(confidence, MemoryConfidence.medium);
    });

    test('原文可定位时保持原置信度', () {
      final draft = _draft(summary: '我喜欢喝手冲咖啡');
      final confidence = engine.groundConfidence(
        draft.copyWith(rawText: '我喜欢喝手冲咖啡，每天早上都要来一杯'),
      );
      expect(confidence, MemoryConfidence.high);
    });
  });

  group('候选比较', () {
    test('完全重复 → merge', () {
      final draft = _draft(summary: '我喜欢在周末去西湖边散步');
      final decision = engine.compare(
        draft,
        [_existing('m1', '我喜欢在周末去西湖边散步')],
      );
      expect(decision.kind, CompareKind.merge);
      expect(decision.targetId, 'm1');
    });

    test('0.81 → update，0.82/0.83 → merge（阈值边界）', () {
      final existing = List.generate(100, (i) => 'k$i').join(' ');
      CompareDecision decide(int shared) {
        final draftTokens = <String>[
          ...List.generate(shared, (i) => 'k$i'),
          ...List.generate(100 - shared, (i) => 'n$i'),
        ];
        return engine.compare(
          _draft(summary: draftTokens.join(' ')),
          [_existing('m1', existing)],
        );
      }

      expect(decide(81).kind, CompareKind.update);
      expect(decide(82).kind, CompareKind.merge);
      expect(decide(83).kind, CompareKind.merge);
    });

    test('数值不同 → conflict', () {
      final draft = _draft(
        type: 'preference',
        summary: '我喜欢养猫，家里有两只，一只叫团子，一只叫年糕',
      );
      final decision = engine.compare(
        draft,
        [
          _existing(
            'm1',
            '我喜欢养猫，家里有三只，一只叫团子，一只叫年糕',
            type: 'preference',
          ),
        ],
      );
      expect(decision.kind, CompareKind.conflict);
      expect(decision.targetId, 'm1');
    });

    test('否定极性相反 → conflict', () {
      final draft = _draft(
        summary: '我很喜欢在早上喝咖啡，尤其是手冲，每天都要来一杯',
      );
      final decision = engine.compare(
        draft,
        [
          _existing(
            'm1',
            '我不喜欢在早上喝咖啡，尤其是手冲，每天都要来一杯',
          ),
        ],
      );
      expect(decision.kind, CompareKind.conflict);
    });

    test('不同类型/低重叠 → create', () {
      expect(
        engine.compare(_draft(summary: '我喜欢喝咖啡'),
            [_existing('m1', '项目进度卡在接口联调', type: 'project')]).kind,
        CompareKind.create,
      );
      expect(
        engine.compare(
            _draft(summary: '今天去爬山了'), [_existing('m1', '我喜欢喝咖啡')]).kind,
        CompareKind.create,
      );
    });

    test('被替代/归档的记忆不参与比较', () {
      final decision = engine.compare(
        _draft(summary: '我喜欢在周末去西湖边散步'),
        [_existing('m1', '我喜欢在周末去西湖边散步', status: 'superseded')],
      );
      expect(decision.kind, CompareKind.create);
    });

    test('自动保存门禁：仅 high + create/update + 无敏感', () {
      final draft = _draft(summary: '我喜欢喝咖啡');
      expect(
        MemoryEngine.canAutoActivate(
            draft, const CompareDecision(
                kind: CompareKind.create, overlap: 0, reason: '')),
        isTrue,
      );
      expect(
        MemoryEngine.canAutoActivate(
            draft.copyWith(confidence: MemoryConfidence.medium),
            const CompareDecision(
                kind: CompareKind.create, overlap: 0, reason: '')),
        isFalse,
      );
      expect(
        MemoryEngine.canAutoActivate(
            draft.copyWith(sensitiveCategories: const ['健康']),
            const CompareDecision(
                kind: CompareKind.create, overlap: 0, reason: '')),
        isFalse,
      );
      expect(
        MemoryEngine.canAutoActivate(
            draft,
            const CompareDecision(
                kind: CompareKind.conflict, overlap: 1, reason: '')),
        isFalse,
      );
    });
  });
}
