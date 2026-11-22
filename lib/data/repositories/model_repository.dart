// 模型仓储（T3.2）：模型注册/启停/默认、Keychain API Key、用量记账与聚合。
// 依据 DATABASE_DESIGN §2.22~§2.23 与 REQUIREMENTS FR-MDL-01/03。
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/chat/chat_usage.dart';
import '../../data/api/deepseek_client.dart';
import '../database/app_database.dart';
import '../security/secure_key_store.dart';

/// 模型能力（capabilities JSON，FR-MDL-02）
class ModelCapabilities {
  const ModelCapabilities({
    this.streaming = true,
    this.reasoning = false,
    this.vision = false,
    this.contextLength = 65536,
  });

  final bool streaming;
  final bool reasoning;
  final bool vision;
  final int contextLength;

  static ModelCapabilities parse(String? json) {
    if (json == null || json.isEmpty) return const ModelCapabilities();
    try {
      final map = jsonDecode(json);
      if (map is! Map<String, dynamic>) return const ModelCapabilities();
      return ModelCapabilities(
        streaming: map['streaming'] as bool? ?? true,
        reasoning: map['reasoning'] as bool? ?? false,
        vision: map['vision'] as bool? ?? false,
        contextLength: (map['context_length'] as num?)?.toInt() ?? 65536,
      );
    } catch (_) {
      return const ModelCapabilities();
    }
  }

  String get contextLabel => contextLength >= 1024
      ? '${(contextLength / 1024).round()}K'
      : '$contextLength';
}

/// 模型生成参数
class ModelParams {
  const ModelParams({this.temperature = 0.7, this.maxTokens = 2048});

  final double temperature;
  final int maxTokens;

  static ModelParams parse(String? json) {
    if (json == null || json.isEmpty) return const ModelParams();
    try {
      final map = jsonDecode(json);
      if (map is! Map<String, dynamic>) return const ModelParams();
      return ModelParams(
        temperature: (map['temperature'] as num?)?.toDouble() ?? 0.7,
        maxTokens: (map['max_tokens'] as num?)?.toInt() ?? 2048,
      );
    } catch (_) {
      return const ModelParams();
    }
  }

  String toJson() =>
      jsonEncode({'temperature': temperature, 'max_tokens': maxTokens});
}

/// 按天用量聚合点
class DailyUsage {
  const DailyUsage({
    required this.day,
    required this.promptTokens,
    required this.completionTokens,
    required this.cost,
    required this.requests,
  });

  final String day;
  final int promptTokens;
  final int completionTokens;
  final double cost;
  final int requests;

  int get totalTokens => promptTokens + completionTokens;
}

class ModelRepository {
  ModelRepository(this._db, {SecureKeyStore? keyStore})
      : _keyStore = keyStore ?? KeychainKeyStore();

  final AppDatabase _db;
  final SecureKeyStore _keyStore;
  static const _uuid = Uuid();

  static String apiKeySecureKeyOf(String modelId) => 'bubble.model.apiKey.$modelId';

  Stream<List<ModelRecord>> watchModels() =>
      (_db.select(_db.models)..orderBy([(t) => OrderingTerm.desc(t.isDefault)]))
          .watch();

  Future<List<ModelRecord>> listModels() =>
      (_db.select(_db.models)..orderBy([(t) => OrderingTerm.desc(t.isDefault)]))
          .get();

  /// 首次启动种子：默认 DeepSeek 模型（未配置 Key 前聊天会回退开发回声并提示）。
  Future<void> ensureSeed() async {
    final existing = await _db.select(_db.models).get();
    if (existing.isNotEmpty) return;
    await _db.into(_db.models).insert(ModelsCompanion.insert(
          id: 'deepseek_default',
          provider: const Value('deepseek'),
          displayName: 'DeepSeek',
          modelTag: kDeepSeekDefaultModelTag,
          apiBaseUrl: const Value(kDeepSeekDefaultBaseUrl),
          capabilities: const Value(
              '{"streaming":true,"reasoning":false,"vision":false,"context_length":65536}'),
          params: Value(const ModelParams().toJson()),
          enabled: const Value(1),
          isDefault: const Value(1),
        ));
  }

  /// 当前启用的默认模型（is_default 优先，其次任一启用模型）
  Future<ModelRecord?> defaultModel() async {
    final rows = await (_db.select(_db.models)
          ..where((t) => t.enabled.equals(1))
          ..orderBy([
            (t) => OrderingTerm.desc(t.isDefault),
            (t) => OrderingTerm.asc(t.displayName),
          ]))
        .get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<ModelRecord?> getModel(String id) =>
      (_db.select(_db.models)..where((t) => t.id.equals(id)))
          .getSingleOrNull();

  /// 保存模型（id 为空则新建）
  Future<String> saveModel({
    String? id,
    required String displayName,
    required String modelTag,
    required String baseUrl,
    required ModelParams params,
    required ModelCapabilities capabilities,
    required bool enabled,
    required bool isDefault,
  }) async {
    final modelId = id ?? _uuid.v4();
    await _db.transaction(() async {
      if (isDefault) {
        await _db.customUpdate(
          'UPDATE models SET is_default = 0 WHERE id != ?',
          variables: [Variable(modelId)],
          updates: {_db.models},
        );
      }
      if (id == null) {
        await _db.into(_db.models).insert(ModelsCompanion.insert(
              id: modelId,
              provider: const Value('deepseek'),
              displayName: displayName,
              modelTag: modelTag,
              apiBaseUrl: Value(baseUrl),
              params: Value(params.toJson()),
              capabilities: Value(jsonEncode({
                'streaming': capabilities.streaming,
                'reasoning': capabilities.reasoning,
                'vision': capabilities.vision,
                'context_length': capabilities.contextLength,
              })),
              enabled: Value(enabled ? 1 : 0),
              isDefault: Value(isDefault ? 1 : 0),
            ));
      } else {
        await (_db.update(_db.models)..where((t) => t.id.equals(id))).write(
          ModelsCompanion(
            displayName: Value(displayName),
            modelTag: Value(modelTag),
            apiBaseUrl: Value(baseUrl),
            params: Value(params.toJson()),
            capabilities: Value(jsonEncode({
              'streaming': capabilities.streaming,
              'reasoning': capabilities.reasoning,
              'vision': capabilities.vision,
              'context_length': capabilities.contextLength,
            })),
            enabled: Value(enabled ? 1 : 0),
            isDefault: Value(isDefault ? 1 : 0),
            lastCheckedAt: Value(DateTime.now().millisecondsSinceEpoch),
          ),
        );
      }
    });
    return modelId;
  }

  Future<void> setEnabled(String id, bool enabled) async {
    await (_db.update(_db.models)..where((t) => t.id.equals(id)))
        .write(ModelsCompanion(enabled: Value(enabled ? 1 : 0)));
  }

  Future<void> setDefault(String id) async {
    await _db.transaction(() async {
      await _db.customUpdate('UPDATE models SET is_default = 0',
          updates: {_db.models});
      await (_db.update(_db.models)..where((t) => t.id.equals(id)))
          .write(const ModelsCompanion(isDefault: Value(1)));
    });
  }

  Future<void> deleteModel(String id) async {
    final model = await getModel(id);
    if (model?.apiKeySecureKey != null) {
      await _keyStore.delete(model!.apiKeySecureKey!);
    }
    await (_db.delete(_db.models)..where((t) => t.id.equals(id))).go();
  }

  // ------------------------------------------------------------ API Key

  Future<String?> readApiKey(ModelRecord model) async {
    final keyName = model.apiKeySecureKey;
    if (keyName == null || keyName.isEmpty) return null;
    final value = await _keyStore.read(keyName);
    return (value == null || value.isEmpty) ? null : value;
  }

  Future<void> saveApiKey(String modelId, String apiKey) async {
    final keyName = apiKeySecureKeyOf(modelId);
    await _keyStore.write(keyName, apiKey.trim());
    await (_db.update(_db.models)..where((t) => t.id.equals(modelId)))
        .write(ModelsCompanion(apiKeySecureKey: Value(keyName)));
  }

  Future<void> clearApiKey(String modelId) async {
    final keyName = apiKeySecureKeyOf(modelId);
    await _keyStore.delete(keyName);
    await (_db.update(_db.models)..where((t) => t.id.equals(modelId)))
        .write(const ModelsCompanion(apiKeySecureKey: Value(null)));
  }

  // ------------------------------------------------------------ 用量

  static String dayKey(DateTime time) {
    final local = time.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  /// 记录一次调用（按 模型×场景×天 聚合，UNIQUE 约束下 upsert）
  Future<void> recordUsage({
    required String modelId,
    required String scene,
    required ChatUsage usage,
  }) async {
    final day = dayKey(DateTime.now());
    await _db.transaction(() async {
      final existing = await (_db.select(_db.modelUsages)
            ..where((t) =>
                t.modelId.equals(modelId) &
                t.scene.equals(scene) &
                t.day.equals(day)))
          .getSingleOrNull();
      if (existing == null) {
        await _db.into(_db.modelUsages).insert(ModelUsagesCompanion.insert(
              id: _uuid.v4(),
              modelId: modelId,
              scene: scene,
              day: day,
              tokenPrompt: Value(usage.promptTokens),
              tokenCompletion: Value(usage.completionTokens),
              costEst: Value(usage.costEst),
              requestCount: const Value(1),
            ));
      } else {
        await (_db.update(_db.modelUsages)..where((t) => t.id.equals(existing.id)))
            .write(ModelUsagesCompanion(
          tokenPrompt: Value(existing.tokenPrompt + usage.promptTokens),
          tokenCompletion: Value(existing.tokenCompletion + usage.completionTokens),
          costEst: Value(existing.costEst + usage.costEst),
          requestCount: Value(existing.requestCount + 1),
        ));
      }
    });
  }

  /// 最近 [days] 天按天聚合（缺失日期补零，供周柱状图）
  Future<List<DailyUsage>> usageLastDays(int days) async {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day)
        .subtract(Duration(days: days - 1));
    final rows = await (_db.select(_db.modelUsages)
          ..where((t) => t.day.isBiggerOrEqualValue(dayKey(start))))
        .get();
    final byDay = <String, DailyUsage>{};
    for (final row in rows) {
      final prev = byDay[row.day];
      byDay[row.day] = DailyUsage(
        day: row.day,
        promptTokens: (prev?.promptTokens ?? 0) + row.tokenPrompt,
        completionTokens: (prev?.completionTokens ?? 0) + row.tokenCompletion,
        cost: (prev?.cost ?? 0) + row.costEst,
        requests: (prev?.requests ?? 0) + row.requestCount,
      );
    }
    final points = <DailyUsage>[];
    for (var i = 0; i < days; i++) {
      final key = dayKey(start.add(Duration(days: i)));
      points.add(byDay[key] ??
          DailyUsage(
            day: key,
            promptTokens: 0,
            completionTokens: 0,
            cost: 0,
            requests: 0,
          ));
    }
    return points;
  }

  /// 本月汇总
  Future<DailyUsage> usageThisMonth() async {
    final now = DateTime.now();
    final startKey = dayKey(DateTime(now.year, now.month, 1));
    final rows = await (_db.select(_db.modelUsages)
          ..where((t) => t.day.isBiggerOrEqualValue(startKey)))
        .get();
    var prompt = 0, completion = 0, requests = 0;
    var cost = 0.0;
    for (final row in rows) {
      prompt += row.tokenPrompt;
      completion += row.tokenCompletion;
      requests += row.requestCount;
      cost += row.costEst;
    }
    return DailyUsage(
      day: startKey,
      promptTokens: prompt,
      completionTokens: completion,
      cost: cost,
      requests: requests,
    );
  }

  /// 按场景汇总（本月）
  Future<Map<String, int>> usageBySceneThisMonth() async {
    final now = DateTime.now();
    final startKey = dayKey(DateTime(now.year, now.month, 1));
    final rows = await (_db.select(_db.modelUsages)
          ..where((t) => t.day.isBiggerOrEqualValue(startKey)))
        .get();
    final result = <String, int>{};
    for (final row in rows) {
      result[row.scene] =
          (result[row.scene] ?? 0) + row.tokenPrompt + row.tokenCompletion;
    }
    return result;
  }
}
