// 人格仓储（T4.2）：核心人格版本门禁、成长建议审批、表达样本、版本恢复。
// 依据 DATABASE_DESIGN §2.4~§2.7、PERSONA_DESIGN §3~§4 与 REQUIREMENTS FR-PER-01~05。
//
// 门禁铁律：core 层版本只允许 confirmedBy=user（首次建库 init 除外）；
// 模型侧只能通过 proposeGrowth 提建议，永远无法直接改写核心人格。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/persona/persona_assembler.dart';
import '../../domain/persona/persona_models.dart';
import '../database/app_database.dart';

/// 人格中心一次性读取的聚合快照（UI 渲染用）
class PersonaSnapshot {
  const PersonaSnapshot({
    required this.profile,
    required this.coreVersion,
    required this.core,
    required this.growth,
    required this.pendingGrowth,
    required this.growthHistory,
    required this.samples,
    required this.versions,
  });

  final PersonaProfile profile;
  final PersonaVersion? coreVersion;
  final PersonaCoreFields core;
  final PersonaGrowthValues growth;
  final List<PersonaGrowthRecord> pendingGrowth;
  final List<PersonaGrowthRecord> growthHistory;
  final List<ExpressionSample> samples;
  final List<PersonaVersion> versions;

  int get coreVersionNo => coreVersion?.versionNo ?? 0;
}

class PersonaRepository {
  PersonaRepository(this._db);

  final AppDatabase _db;
  static const _uuid = Uuid();

  /// 人格主档案固定单行 id
  static const profileId = 'persona_default';

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  // ------------------------------------------------------------ 初始化

  /// 首次建库：写入默认核心人格（v1, confirmed_by=init）与空成长层（v2）。
  Future<void> ensureSeed() async {
    final existing = await _db.select(_db.personaProfiles).getSingleOrNull();
    if (existing != null) return;
    await _db.transaction(() async {
      final now = _nowIso();
      final core = PersonaCoreFields.defaults();
      final coreVersion = await _createVersion(
        layer: 'core',
        content: core.toJsonString(),
        confirmedBy: 'init',
        reason: '首次创建核心人格',
        initial: true,
        createdAt: now,
      );
      await _createVersion(
        layer: 'growth',
        content: const PersonaGrowthValues({}).toJsonString(),
        confirmedBy: 'init',
        reason: '首次创建成长层',
        initial: true,
        createdAt: now,
      );
      await _db.into(_db.personaProfiles).insert(PersonaProfilesCompanion.insert(
            id: profileId,
            name: const Value('泡泡'),
            intro: const Value('正在学着更懂你一点。'),
            activeVersionId: Value(coreVersion.id),
            interests: const Value('[]'),
            updatedAt: now,
          ));
    });
    await rebuildPromptSnapshot();
  }

  // ------------------------------------------------------------ 读取

  Future<PersonaProfile> profile() async {
    await ensureSeed();
    return (_db.select(_db.personaProfiles)
          ..where((t) => t.id.equals(profileId)))
        .getSingle();
  }

  Future<List<PersonaVersion>> versions({String? layer}) {
    final query = _db.select(_db.personaVersions);
    if (layer != null) {
      query.where((t) => t.layer.equals(layer));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.versionNo)]);
    return query.get();
  }

  Future<PersonaVersion?> getVersion(String id) =>
      (_db.select(_db.personaVersions)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  Future<PersonaVersion?> activeVersion(String layer) =>
      (_db.select(_db.personaVersions)
            ..where((t) => t.layer.equals(layer) & t.isActive.equals(1))
            ..orderBy([(t) => OrderingTerm.desc(t.versionNo)])
            ..limit(1))
          .getSingleOrNull();

  Future<PersonaCoreFields> coreFields() async {
    final version = await activeVersion('core');
    return PersonaCoreFields.parse(version?.content);
  }

  Future<PersonaGrowthValues> growthValues() async {
    final version = await activeVersion('growth');
    return PersonaGrowthValues.parse(version?.content);
  }

  Future<List<PersonaGrowthRecord>> pendingGrowth() =>
      (_db.select(_db.personaGrowthRecords)
            ..where((t) => t.status.equals('proposed'))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<int> pendingGrowthCount() async {
    final query = _db.selectOnly(_db.personaGrowthRecords)
      ..addColumns([_db.personaGrowthRecords.id.count()])
      ..where(_db.personaGrowthRecords.status.equals('proposed'));
    final row = await query.getSingle();
    return row.read(_db.personaGrowthRecords.id.count()) ?? 0;
  }

  Future<List<PersonaGrowthRecord>> growthRecords() =>
      (_db.select(_db.personaGrowthRecords)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .get();

  Future<PersonaGrowthRecord?> getGrowthRecord(String id) =>
      (_db.select(_db.personaGrowthRecords)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// 人格中心聚合快照
  Future<PersonaSnapshot> loadSnapshot() async {
    await ensureSeed();
    final profileRow = await profile();
    final coreVersion = await activeVersion('core');
    final allVersions = await versions();
    final pending = await pendingGrowth();
    final history = (await growthRecords())
        .where((r) => r.status != 'proposed')
        .toList();
    final samples = await listSamples();
    return PersonaSnapshot(
      profile: profileRow,
      coreVersion: coreVersion,
      core: PersonaCoreFields.parse(coreVersion?.content),
      growth: await growthValues(),
      pendingGrowth: pending,
      growthHistory: history,
      samples: samples,
      versions: allVersions,
    );
  }

  // ------------------------------------------------------------ 核心人格（仅用户）

  /// 保存核心人格：必须传入 userConfirmed=true（UI 逐项确认后调用）。
  /// 生成新版本，不覆盖历史版本（FR-PER-04）。
  Future<PersonaVersion> saveCore(
    PersonaCoreFields fields, {
    String? reason,
    bool userConfirmed = false,
  }) async {
    if (!userConfirmed) {
      throw StateError('核心人格修改必须经用户逐项确认');
    }
    late PersonaVersion created;
    await _db.transaction(() async {
      created = await _createVersion(
        layer: 'core',
        content: fields.toJsonString(),
        confirmedBy: 'user',
        reason: reason ?? '用户编辑核心人格',
        userConfirmed: true,
      );
    });
    await rebuildPromptSnapshot();
    return created;
  }

  /// 恢复历史版本 = 生成一个内容相同的新版本（不覆盖历史）。
  Future<PersonaVersion> restoreVersion(String versionId) async {
    final source = await getVersion(versionId);
    if (source == null) throw StateError('版本不存在：$versionId');
    late PersonaVersion created;
    await _db.transaction(() async {
      created = await _createVersion(
        layer: source.layer,
        content: source.content,
        confirmedBy: 'user',
        reason: '恢复 v${source.versionNo}',
        userConfirmed: true,
      );
    });
    await rebuildPromptSnapshot();
    return created;
  }

  // ------------------------------------------------------------ 成长层（模型提议）

  /// 模型/规则提出成长建议：只写 proposed 记录，不产生任何版本。
  Future<String> proposeGrowth({
    required String growthType,
    String? beforeValue,
    String? afterValue,
    String? reason,
    String? relatedExperienceId,
    String? relatedMemoryIds,
  }) async {
    final active = await activeVersion('growth') ?? await _ensureGrowthBaseline();
    final id = _uuid.v4();
    await _db.into(_db.personaGrowthRecords).insert(
          PersonaGrowthRecordsCompanion.insert(
            id: id,
            versionId: active.id,
            growthType: growthType,
            beforeValue: Value(beforeValue),
            afterValue: Value(afterValue),
            reason: Value(reason),
            relatedExperienceId: Value(relatedExperienceId),
            relatedMemoryIds: Value(relatedMemoryIds),
            status: const Value('proposed'),
            createdAt: _nowIso(),
          ),
        );
    return id;
  }

  /// 用户接受成长建议：仅改 L2，生成新成长版本。
  /// [editedAfterValue] 非空表示「编辑后接受」。
  Future<PersonaVersion> acceptGrowth(
    String recordId, {
    String? editedAfterValue,
  }) async {
    late PersonaVersion created;
    await _db.transaction(() async {
      final record = await getGrowthRecord(recordId);
      if (record == null) throw StateError('成长记录不存在：$recordId');
      if (record.status != 'proposed') throw StateError('该建议已处理');
      final after = (editedAfterValue ?? record.afterValue ?? '').trim();
      if (after.isEmpty) throw StateError('成长建议缺少新值');
      final values = await growthValues();
      created = await _createVersion(
        layer: 'growth',
        content: values.withValue(record.growthType, after).toJsonString(),
        confirmedBy: 'user',
        reason: '接受成长建议：${record.growthType}',
        userConfirmed: true,
      );
      await (_db.update(_db.personaGrowthRecords)
            ..where((t) => t.id.equals(recordId)))
          .write(PersonaGrowthRecordsCompanion(
        versionId: Value(created.id),
        afterValue: Value(after),
        status: const Value('confirmed'),
        confirmedAt: Value(_nowIso()),
      ));
    });
    await rebuildPromptSnapshot();
    return created;
  }

  /// 拒绝成长建议：留痕，状态置 reverted（DB 允许的终态），不产生版本。
  Future<void> rejectGrowth(String recordId) async {
    final record = await getGrowthRecord(recordId);
    if (record == null) throw StateError('成长记录不存在：$recordId');
    if (record.status != 'proposed') return;
    await (_db.update(_db.personaGrowthRecords)
          ..where((t) => t.id.equals(recordId)))
        .write(PersonaGrowthRecordsCompanion(
      status: const Value('reverted'),
      confirmedAt: Value(_nowIso()),
    ));
  }

  // ------------------------------------------------------------ 表达样本

  Future<List<ExpressionSample>> listSamples({bool includeDeleted = false}) {
    final query = _db.select(_db.expressionSamples);
    if (!includeDeleted) {
      query.where((t) => t.deletedAt.isNull());
    }
    query.orderBy([
      (t) => OrderingTerm.desc(t.pinned),
      (t) => OrderingTerm.desc(t.createdAt),
    ]);
    return query.get();
  }

  Future<String> addSample({
    required String content,
    String? contextNote,
    bool pinned = false,
    String? relatedMessageId,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw ArgumentError('表达样本不能为空');
    final id = _uuid.v4();
    await _db.into(_db.expressionSamples).insert(ExpressionSamplesCompanion.insert(
          id: id,
          content: text,
          contextNote: Value(contextNote),
          pinned: Value(pinned ? 1 : 0),
          relatedMessageId: Value(relatedMessageId),
          createdAt: _nowIso(),
        ));
    await rebuildPromptSnapshot();
    return id;
  }

  Future<void> setSamplePinned(String id, bool pinned) async {
    await (_db.update(_db.expressionSamples)..where((t) => t.id.equals(id)))
        .write(ExpressionSamplesCompanion(pinned: Value(pinned ? 1 : 0)));
    await rebuildPromptSnapshot();
  }

  /// 软删（保留痕迹，可从数据中心清理）
  Future<void> deleteSample(String id) async {
    await (_db.update(_db.expressionSamples)..where((t) => t.id.equals(id)))
        .write(ExpressionSamplesCompanion(deletedAt: Value(_nowIso())));
    await rebuildPromptSnapshot();
  }

  /// 最近可沉淀为样本的助手回复（已发送、未删除、非空）
  Future<List<Message>> recentAssistantMessages({int limit = 20}) async {
    final rows = await (_db.select(_db.messages)
          ..where((t) =>
              t.role.equals('assistant') &
              t.status.equals('sent') &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(limit))
        .get();
    return rows.where((m) => m.content.trim().isNotEmpty).toList();
  }

  // ------------------------------------------------------------ 提示词快照

  /// 重新组装 system 提示词并写入 persona_profiles.core_system_prompt（可追溯）。
  Future<String> rebuildPromptSnapshot() async {
    final coreVersion = await activeVersion('core');
    final core = PersonaCoreFields.parse(coreVersion?.content);
    final growth = await growthValues();
    final samples = (await listSamples())
        .where((s) => s.pinned == 1)
        .map((s) => s.content)
        .toList();
    final prompt = PersonaAssembler.build(
      core: core,
      coreVersionNo: coreVersion?.versionNo ?? 0,
      growth: growth,
      samples: samples,
    );
    await (_db.update(_db.personaProfiles)
          ..where((t) => t.id.equals(profileId)))
        .write(PersonaProfilesCompanion(
      coreSystemPrompt: Value(prompt),
      updatedAt: Value(_nowIso()),
    ));
    return prompt;
  }

  // ------------------------------------------------------------ 内部

  /// 创建版本并激活；core 层门禁在此统一收口。
  Future<PersonaVersion> _createVersion({
    required String layer,
    required String content,
    required String confirmedBy,
    String? reason,
    bool userConfirmed = false,
    bool initial = false,
    String? createdAt,
  }) async {
    if (layer == 'core' && !initial) {
      if (confirmedBy != 'user' || !userConfirmed) {
        throw StateError('核心人格只能由用户确认后写入');
      }
    }
    final latest = await (_db.select(_db.personaVersions)
          ..orderBy([(t) => OrderingTerm.desc(t.versionNo)])
          ..limit(1))
        .getSingleOrNull();
    final nextNo = (latest?.versionNo ?? 0) + 1;
    final id = _uuid.v4();
    final now = createdAt ?? _nowIso();
    await _db.customUpdate(
      'UPDATE persona_versions SET is_active = 0 WHERE layer = ? AND is_active = 1',
      variables: [Variable(layer)],
      updates: {_db.personaVersions},
    );
    await _db.into(_db.personaVersions).insert(PersonaVersionsCompanion.insert(
          id: id,
          versionNo: nextNo,
          layer: layer,
          content: content,
          changeReason: Value(reason),
          confirmedBy: Value(confirmedBy),
          isActive: const Value(1),
          createdAt: now,
        ));
    if (layer == 'core') {
      await (_db.update(_db.personaProfiles)
            ..where((t) => t.id.equals(profileId)))
          .write(PersonaProfilesCompanion(
        activeVersionId: Value(id),
        updatedAt: Value(now),
      ));
    }
    return PersonaVersion(
      id: id,
      versionNo: nextNo,
      layer: layer,
      content: content,
      changeReason: reason,
      confirmedBy: confirmedBy,
      isActive: 1,
      createdAt: now,
    );
  }

  Future<PersonaVersion> _ensureGrowthBaseline() async {
    final existing = await activeVersion('growth');
    if (existing != null) return existing;
    return _createVersion(
      layer: 'growth',
      content: const PersonaGrowthValues({}).toJsonString(),
      confirmedBy: 'init',
      reason: '成长层基线',
      initial: true,
    );
  }

  /// 仅调试/统计用：解析当前快照 JSON（测试断言辅助）
  static Map<String, dynamic> decodeJson(String raw) =>
      jsonDecode(raw) as Map<String, dynamic>;
}
