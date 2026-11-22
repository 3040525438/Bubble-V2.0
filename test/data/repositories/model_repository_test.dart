// 模型仓储单测（T3.2）：种子模型、默认模型唯一性、Keychain 键名、用量聚合。
import 'package:bubble/data/database/app_database.dart';
import 'package:bubble/data/database/open_db.dart';
import 'package:bubble/data/repositories/model_repository.dart';
import 'package:bubble/domain/chat/chat_usage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_key_store.dart';

void main() {
  late AppDatabase db;
  late InMemoryKeyStore keyStore;
  late ModelRepository repo;

  setUp(() {
    db = AppDatabase(openInMemoryDatabase());
    keyStore = InMemoryKeyStore();
    repo = ModelRepository(db, keyStore: keyStore);
  });

  tearDown(() async => db.close());

  test('种子模型：幂等且为默认启用', () async {
    await repo.ensureSeed();
    await repo.ensureSeed();
    final models = await repo.listModels();
    expect(models.length, 1);
    expect(models.single.modelTag, 'deepseek-chat');
    expect(models.single.isDefault, 1);
    expect(models.single.enabled, 1);

    final defaultModel = await repo.defaultModel();
    expect(defaultModel!.id, models.single.id);
  });

  test('新增/更新模型并保证默认唯一', () async {
    await repo.ensureSeed();
    final secondId = await repo.saveModel(
      displayName: 'DeepSeek Reasoner',
      modelTag: 'deepseek-reasoner',
      baseUrl: 'https://api.deepseek.com',
      params: const ModelParams(temperature: 0.3, maxTokens: 4096),
      capabilities: const ModelCapabilities(reasoning: true),
      enabled: true,
      isDefault: true,
    );

    final models = await repo.listModels();
    expect(models.length, 2);
    expect(models.where((m) => m.isDefault == 1).length, 1);
    expect(models.firstWhere((m) => m.isDefault == 1).id, secondId);
    expect((await repo.defaultModel())!.id, secondId);

    final params = ModelParams.parse(
        (await repo.getModel(secondId))!.params);
    expect(params.temperature, 0.3);
    expect(params.maxTokens, 4096);
    expect(ModelCapabilities.parse(
            (await repo.getModel(secondId))!.capabilities)
        .reasoning, isTrue);
  });

  test('停用默认模型后 defaultModel 回退到其它启用模型', () async {
    await repo.ensureSeed();
    final seed = (await repo.listModels()).single;
    final secondId = await repo.saveModel(
      displayName: '备用',
      modelTag: 'deepseek-chat',
      baseUrl: 'https://api.deepseek.com',
      params: const ModelParams(),
      capabilities: const ModelCapabilities(),
      enabled: true,
      isDefault: false,
    );
    await repo.setEnabled(seed.id, false);
    expect((await repo.defaultModel())!.id, secondId);
  });

  test('API Key 只存键名且可读回/清除', () async {
    await repo.ensureSeed();
    final model = (await repo.listModels()).single;
    expect(await repo.readApiKey(model), isNull);

    await repo.saveApiKey(model.id, 'sk-abc123');
    final refreshed = (await repo.getModel(model.id))!;
    expect(refreshed.apiKeySecureKey, ModelRepository.apiKeySecureKeyOf(model.id));
    expect(await repo.readApiKey(refreshed), 'sk-abc123');
    // 明文不落库
    expect(refreshed.apiKeySecureKey, isNot(contains('sk-abc123')));
    expect(keyStore.values.values.single, 'sk-abc123');

    await repo.clearApiKey(model.id);
    expect(await repo.readApiKey((await repo.getModel(model.id))!), isNull);
    expect((await repo.getModel(model.id))!.apiKeySecureKey, isNull);
  });

  test('删除模型同时清除其 Key', () async {
    await repo.ensureSeed();
    final model = (await repo.listModels()).single;
    await repo.saveApiKey(model.id, 'sk-xyz');
    await repo.deleteModel(model.id);
    expect(await repo.listModels(), isEmpty);
    expect(keyStore.values, isEmpty);
  });

  test('用量按天/场景聚合，最近 7 天补零', () async {
    await repo.ensureSeed();
    final model = (await repo.listModels()).single;

    const usageA = ChatUsage(
        promptTokens: 100, completionTokens: 50, costEst: 0.01);
    const usageB = ChatUsage(
        promptTokens: 10, completionTokens: 5, costEst: 0.002);
    await repo.recordUsage(modelId: model.id, scene: 'chat', usage: usageA);
    await repo.recordUsage(modelId: model.id, scene: 'chat', usage: usageB);
    await repo.recordUsage(
        modelId: model.id, scene: 'thinking', usage: usageB);

    final week = await repo.usageLastDays(7);
    expect(week.length, 7);
    final today = week.last;
    expect(today.promptTokens, 120);
    expect(today.completionTokens, 60);
    expect(today.requests, 3);
    expect(today.cost, closeTo(0.014, 0.0001));
    expect(week.take(6).every((p) => p.requests == 0), isTrue);

    final month = await repo.usageThisMonth();
    expect(month.totalTokens, 180);

    final scenes = await repo.usageBySceneThisMonth();
    expect(scenes['chat'], 165);
    expect(scenes['thinking'], 15);
  });
}
