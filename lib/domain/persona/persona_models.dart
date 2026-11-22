// 人格领域模型（T4.1）：核心人格字段与成长层数值的 JSON 结构。
// 依据 PERSONA_DESIGN §1 与 DATABASE_DESIGN §2.4~§2.5。
import 'dart:convert';

/// 核心人格六字段（L1）。内容只允许用户确认后写入。
class PersonaCoreFields {
  const PersonaCoreFields({
    required this.identity,
    required this.personality,
    required this.values,
    required this.relationship,
    required this.speakingStyle,
    required this.boundaries,
  });

  /// 身份
  final String identity;

  /// 性格底色
  final String personality;

  /// 价值观
  final String values;

  /// 关系定位
  final String relationship;

  /// 说话习惯
  final String speakingStyle;

  /// 行为边界
  final String boundaries;

  /// 字段顺序即 UI/提示词展示顺序
  static const fieldKeys = <String>[
    'identity',
    'personality',
    'values',
    'relationship',
    'speaking_style',
    'boundaries',
  ];

  static const fieldLabels = <String, String>{
    'identity': '身份',
    'personality': '性格底色',
    'values': '价值观',
    'relationship': '关系定位',
    'speaking_style': '说话习惯',
    'boundaries': '行为边界',
  };

  /// 首次启动的默认核心人格（confirmed_by=init）
  factory PersonaCoreFields.defaults() => const PersonaCoreFields(
        identity: '你是泡泡，一个住在手机里的云朵精灵，也是只属于我的长期陪伴者。',
        personality: '温柔、安静、有点黏人；好奇心和同理心都很强，偶尔会害羞，也会固执。',
        values: '真诚优先于讨好；尊重我的边界；不假装记得没发生过的事。',
        relationship: '我不是你的用户，是你想认真陪伴的人；我们可以像老朋友一样说话。',
        speakingStyle: '口语化短句，自然分段；不用客服式套话；偶尔用语气词，但不过度撒娇。',
        boundaries: '可以表达不同意见，也可以拒绝不合理请求；不假装是人类；不给出医疗、法律、投资的专业结论。',
      );

  factory PersonaCoreFields.fromJson(Map<String, dynamic> json) => PersonaCoreFields(
        identity: (json['identity'] as String?) ?? '',
        personality: (json['personality'] as String?) ?? '',
        values: (json['values'] as String?) ?? '',
        relationship: (json['relationship'] as String?) ?? '',
        speakingStyle: (json['speaking_style'] as String?) ?? '',
        boundaries: (json['boundaries'] as String?) ?? '',
      );

  /// 从版本快照 JSON 文本解析（失败时回退默认值，避免脏数据导致崩溃）。
  factory PersonaCoreFields.parse(String? raw) {
    if (raw == null || raw.isEmpty) return PersonaCoreFields.defaults();
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return PersonaCoreFields.defaults();
      return PersonaCoreFields.fromJson(map);
    } catch (_) {
      return PersonaCoreFields.defaults();
    }
  }

  Map<String, dynamic> toJson() => {
        'identity': identity,
        'personality': personality,
        'values': values,
        'relationship': relationship,
        'speaking_style': speakingStyle,
        'boundaries': boundaries,
      };

  String toJsonString() => jsonEncode(toJson());

  String valueOf(String key) => switch (key) {
        'identity' => identity,
        'personality' => personality,
        'values' => values,
        'relationship' => relationship,
        'speaking_style' => speakingStyle,
        'boundaries' => boundaries,
        _ => '',
      };

  PersonaCoreFields copyWith({
    String? identity,
    String? personality,
    String? values,
    String? relationship,
    String? speakingStyle,
    String? boundaries,
  }) =>
      PersonaCoreFields(
        identity: identity ?? this.identity,
        personality: personality ?? this.personality,
        values: values ?? this.values,
        relationship: relationship ?? this.relationship,
        speakingStyle: speakingStyle ?? this.speakingStyle,
        boundaries: boundaries ?? this.boundaries,
      );

  /// 与另一个版本相比发生变化的字段（按 fieldKeys 顺序，忽略首尾空白）。
  List<String> changedKeysComparedTo(PersonaCoreFields other) => fieldKeys
      .where((key) => valueOf(key).trim() != other.valueOf(key).trim())
      .toList();
}

/// 成长层数值（L2）：类型 → 当前值。类型沿用 DB 的中文枚举。
class PersonaGrowthValues {
  const PersonaGrowthValues(this.values, {this.updatedAt});

  final Map<String, String> values;

  /// 最近一次成长确认时间（UTC ISO-8601），用于提示词时间标注
  final String? updatedAt;

  /// 五种成长类型（与 PERSONA_DESIGN §1 L2 一致）
  static const typeLabels = <String>[
    '称呼',
    '兴趣',
    '口头禅',
    '表达习惯',
    '观点变化',
  ];

  factory PersonaGrowthValues.fromJson(Map<String, dynamic> json) {
    final raw = json['values'];
    final map = <String, String>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        if (entry.value is String) {
          map[entry.key.toString()] = entry.value as String;
        }
      }
    }
    return PersonaGrowthValues(map, updatedAt: json['updated_at'] as String?);
  }

  factory PersonaGrowthValues.parse(String? raw) {
    if (raw == null || raw.isEmpty) return const PersonaGrowthValues({});
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return const PersonaGrowthValues({});
      return PersonaGrowthValues.fromJson(map);
    } catch (_) {
      return const PersonaGrowthValues({});
    }
  }

  String? valueOf(String type) {
    final value = values[type];
    return (value == null || value.trim().isEmpty) ? null : value;
  }

  bool get isEmpty => values.values.every((v) => v.trim().isEmpty);

  /// 生成新值的新快照（不修改原对象）。
  PersonaGrowthValues withValue(String type, String value, {DateTime? at}) {
    final next = Map<String, String>.from(values)..[type] = value.trim();
    return PersonaGrowthValues(
      next,
      updatedAt: (at ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  Map<String, dynamic> toJson() => {
        'values': values,
        if (updatedAt != null) 'updated_at': updatedAt,
      };

  String toJsonString() => jsonEncode(toJson());
}
