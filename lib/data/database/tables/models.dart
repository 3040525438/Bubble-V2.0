// 模型域：models / model_usage
// 依据 DATABASE_DESIGN §2.22~§2.23。API Key 不存库，models 只存 Keychain 键名。
import 'package:drift/drift.dart';

// 模型注册表（§2.22）
@DataClassName('ModelRecord')
class Models extends Table {
  TextColumn get id => text()();
  TextColumn get provider => text().withDefault(const Constant('deepseek')).check(
      const CustomExpression<bool>(
          "provider IN ('deepseek', 'openai_compatible', 'local_reserved')"))();
  TextColumn get displayName => text()();
  TextColumn get apiBaseUrl => text().nullable()();
  TextColumn get apiKeySecureKey => text().nullable()(); // Keychain 键名，不存明文
  TextColumn get modelTag => text()(); // 如 deepseek-chat
  TextColumn get params => text().nullable()(); // JSON：temperature 等
  TextColumn get capabilities => text().nullable()(); // JSON：vision/context/streaming
  IntColumn get enabled => integer().withDefault(const Constant(1))();
  IntColumn get isDefault => integer().withDefault(const Constant(0))();
  IntColumn get lastCheckedAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

// 用量统计（§2.23）：按天聚合 UNIQUE(model_id, scene, day)
@TableIndex(
    name: 'uq_model_usage_daily',
    columns: {#modelId, #scene, #day},
    unique: true)
@DataClassName('ModelUsage')
class ModelUsages extends Table {
  TextColumn get id => text()();
  TextColumn get modelId => text().references(Models, #id)();
  TextColumn get scene => text()(); // chat/memory_extract/thinking/proactive/...
  IntColumn get tokenPrompt => integer().withDefault(const Constant(0))();
  IntColumn get tokenCompletion => integer().withDefault(const Constant(0))();
  RealColumn get costEst => real().withDefault(const Constant(0))();
  IntColumn get requestCount => integer().withDefault(const Constant(0))();
  TextColumn get day => text()(); // yyyy-MM-dd（本地日历日）

  @override
  Set<Column> get primaryKey => {id};
}
