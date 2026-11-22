// 人格提示词组装器（T4.2）：四层人格 → 一次模型调用的 system 提示词。
// 依据 PERSONA_DESIGN §2：核心块最前（利于前缀缓存）、成长块带时间、样本仅作风格参照，
// 反模板化约束固定写入核心块末尾。
import 'persona_models.dart';

class PersonaAssembler {
  const PersonaAssembler._();

  /// 反模板化约束（FR-PER-03）：固定段，随核心人格块一起注入。
  static const antiTemplateRules = <String>[
    '禁止客服腔：不要说“作为AI助手，我……”“很高兴为你服务”这类话。',
    '回复日常闲聊时不要用列表腔，不要机械总结或复述我的问题。',
    '自然分段，允许口语、幽默和停顿；可以有不同意见，也可以拒绝不合理请求。',
    '下面的表达样本只用来参照语气和风格，不要照抄原句。',
  ];

  /// 组装系统提示词。
  ///
  /// - [core] 核心人格六字段
  /// - [coreVersionNo] 核心人格版本号（展示为 vN）
  /// - [growth] 成长层当前值
  /// - [samples] 表达样本（按重要度排序，最多取 [maxSamples] 条）
  /// - [sceneNote] 当前场景块（阶段 6 由 ContextBuilder 注入，可为空）
  static String build({
    required PersonaCoreFields core,
    required int coreVersionNo,
    PersonaGrowthValues growth = const PersonaGrowthValues({}),
    List<String> samples = const [],
    String? sceneNote,
    int maxSamples = 6,
  }) {
    final blocks = <String>[
      _coreBlock(core, coreVersionNo),
      if (!growth.isEmpty) _growthBlock(growth),
      _samplesBlock(samples, maxSamples),
      if (sceneNote != null && sceneNote.trim().isNotEmpty)
        '【当前场景】\n${sceneNote.trim()}',
    ];
    return blocks.join('\n\n');
  }

  static String _coreBlock(PersonaCoreFields core, int versionNo) {
    final fields = StringBuffer();
    for (final key in PersonaCoreFields.fieldKeys) {
      fields.writeln('${PersonaCoreFields.fieldLabels[key]}：${core.valueOf(key).trim()}');
    }
    final rules = antiTemplateRules.map((r) => '- $r').join('\n');
    return '【核心人格 v$versionNo】\n$fields'
        '【表达约束】\n$rules';
  }

  static String _growthBlock(PersonaGrowthValues growth) {
    final lines = StringBuffer();
    for (final type in PersonaGrowthValues.typeLabels) {
      final value = growth.valueOf(type);
      if (value != null) lines.writeln('- $type：$value');
    }
    final date = _formatDate(growth.updatedAt);
    final annotation = date == null ? '' : '（成长信息更新于 $date）\n';
    return '【成长人格】\n$annotation$lines';
  }

  static String _samplesBlock(List<String> samples, int maxSamples) {
    final usable = samples
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .take(maxSamples)
        .toList();
    if (usable.isEmpty) {
      return '【表达风格参照】\n（暂无表达样本，按核心人格自然表达即可。）';
    }
    final lines = usable.map((s) => '- “${_truncate(s, 120)}”').join('\n');
    return '【表达风格参照（只参照语气，不照抄原句）】\n$lines';
  }

  static String _truncate(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  static String? _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return null;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }
}
