// 记忆提取流水线（T5.1 配套 / FR-MEM-07 成本控制）：延迟批处理，不每条消息调模型。
// 流程：轮次结束 → 入缓冲（持久化到 app_settings，防丢）→ 满足触发条件才批量处理：
//   ① 缓冲 ≥6 轮 ② 距上次处理 ≥30 分钟 ③ 会话结束 ④ 用户手动
// 本阶段为纯规则路径（零成本）；LLM 提取默认关闭（llm_extraction_enabled=0）。
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/memory/memory_engine.dart';
import '../database/app_database.dart';
import 'memory_repository.dart';

/// 缓冲中的一轮对话
class BufferedTurn {
  const BufferedTurn({
    required this.sessionId,
    required this.userText,
    required this.assistantText,
    required this.createdAtMs,
  });

  final String sessionId;
  final String userText;
  final String assistantText;
  final int createdAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sessionId': sessionId,
        'userText': userText,
        'assistantText': assistantText,
        'createdAtMs': createdAtMs,
      };

  static BufferedTurn? fromJson(Map<String, dynamic> json) {
    final userText = json['userText'] as String? ?? '';
    if (userText.isEmpty) return null;
    return BufferedTurn(
      sessionId: json['sessionId'] as String? ?? '',
      userText: userText,
      assistantText: json['assistantText'] as String? ?? '',
      createdAtMs: json['createdAtMs'] as int? ?? 0,
    );
  }
}

/// 批量处理结果
class BatchOutcome {
  const BatchOutcome({
    required this.processedTurns,
    required this.drafts,
    required this.autoApplied,
    required this.pending,
    required this.secretRejected,
  });

  final int processedTurns;
  final int drafts;
  final int autoApplied;
  final int pending;
  final int secretRejected;

  static const empty = BatchOutcome(
    processedTurns: 0,
    drafts: 0,
    autoApplied: 0,
    pending: 0,
    secretRejected: 0,
  );
}

class MemoryIngestPipeline {
  MemoryIngestPipeline(
    this._db,
    this._repository, {
    this.engine = const MemoryEngine(),
    this.now,
  });

  final AppDatabase _db;
  final MemoryRepository _repository;
  final MemoryEngine engine;

  /// 可注入时钟（测试用）
  final DateTime Function()? now;

  static const bufferKey = 'memory_ingest_buffer';
  static const lastRunKey = 'memory_ingest_last_run';
  static const llmEnabledKey = 'llm_extraction_enabled';

  /// 触发阈值
  static const int turnThreshold = 6;
  static const Duration interval = Duration(minutes: 30);

  /// 批次内最多合并处理的轮数（对齐 LLM 批量 ≤8 轮）
  static const int maxTurnsPerBatch = 8;

  DateTime get _now => (now ?? DateTime.now)().toUtc();

  // ------------------------------------------------------------ 缓冲

  Future<List<BufferedTurn>> bufferedTurns() async {
    final row = await (_db.select(_db.appSettings)
          ..where((t) => t.key.equals(bufferKey)))
        .getSingleOrNull();
    final raw = row?.value;
    if (raw == null || raw.isEmpty) return const <BufferedTurn>[];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list
          .map(BufferedTurn.fromJson)
          .whereType<BufferedTurn>()
          .toList();
    } catch (_) {
      return const <BufferedTurn>[];
    }
  }

  /// 轮次结束：写入缓冲（不立即提取）
  Future<void> bufferTurn({
    required String sessionId,
    required String userText,
    String assistantText = '',
  }) async {
    if (userText.trim().isEmpty) return;
    final turns = <BufferedTurn>[...await bufferedTurns()];
    turns.add(BufferedTurn(
      sessionId: sessionId,
      userText: userText,
      assistantText: assistantText,
      createdAtMs: _now.millisecondsSinceEpoch,
    ));
    await _writeBuffer(turns);
  }

  /// 是否应触发批量处理。
  Future<bool> shouldProcess({bool sessionEnded = false, bool manual = false}) async {
    if (manual || sessionEnded) return true;
    final turns = await bufferedTurns();
    if (turns.length >= turnThreshold) return true;
    if (turns.isEmpty) return false;
    final last = await _lastRun();
    if (last == null) return false;
    return _now.difference(last) >= interval;
  }

  /// 批量处理缓冲：本地噪声/信号粗筛 → 比较 → 候选落库（零模型调用）。
  Future<BatchOutcome> process({
    bool force = false,
  }) async {
    if (!force && !await shouldProcess()) return BatchOutcome.empty;
    final turns = await bufferedTurns();
    if (turns.isEmpty) {
      await _markRun();
      return BatchOutcome.empty;
    }
    final batch = turns.take(maxTurnsPerBatch).toList();
    var drafts = 0;
    var autoApplied = 0;
    var pending = 0;
    var secretRejected = 0;
    for (final turn in batch) {
      final draft = engine.extract(turn.userText, assistantText: turn.assistantText);
      if (draft == null) continue;
      drafts++;
      final result = await _repository.ingestDraft(
        draft,
        sessionId: turn.sessionId,
        assistantText: turn.assistantText,
      );
      if (result.secretRejected) {
        secretRejected++;
      } else if (result.autoApplied) {
        autoApplied++;
      } else {
        pending++;
      }
    }
    await _writeBuffer(turns.skip(batch.length).toList());
    await _markRun();
    return BatchOutcome(
      processedTurns: batch.length,
      drafts: drafts,
      autoApplied: autoApplied,
      pending: pending,
      secretRejected: secretRejected,
    );
  }

  /// 手动提取单条文本（用户“记住：…”入口）
  Future<IngestResult?> extractNow(String text, {String sessionId = 'manual'}) async {
    final draft = engine.extract(text);
    if (draft == null) return null;
    return _repository.ingestDraft(draft, sessionId: sessionId);
  }

  /// LLM 提取开关（默认关闭，仅用户主动开启）
  Future<bool> llmExtractionEnabled() async {
    final row = await (_db.select(_db.appSettings)
          ..where((t) => t.key.equals(llmEnabledKey)))
        .getSingleOrNull();
    return (row?.value ?? '0') == '1';
  }

  Future<void> setLlmExtractionEnabled(bool enabled) async {
    await _db.into(_db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: llmEnabledKey,
            value: Value(enabled ? '1' : '0'),
            updatedAt: _now.toIso8601String(),
          ),
        );
  }

  // ------------------------------------------------------------ 内部

  Future<DateTime?> _lastRun() async {
    final row = await (_db.select(_db.appSettings)
          ..where((t) => t.key.equals(lastRunKey)))
        .getSingleOrNull();
    final raw = row?.value;
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  Future<void> _markRun() async {
    await _db.into(_db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: lastRunKey,
            value: Value(_now.toIso8601String()),
            updatedAt: _now.toIso8601String(),
          ),
        );
  }

  Future<void> _writeBuffer(List<BufferedTurn> turns) async {
    final value = jsonEncode(turns.map((t) => t.toJson()).toList());
    await _db.into(_db.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: bufferKey,
            value: Value(value),
            updatedAt: _now.toIso8601String(),
          ),
        );
  }
}
