// 日记整理器（T11.1）：当天聊天 + 记忆素材，真实模型可注入，未配置时本地整理。
// 依据 REQUIREMENTS FR-DIA-01、UI_PAGE_SPEC §16/§17。
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../domain/diary/diary_models.dart';
import '../database/app_database.dart';
import '../repositories/diary_repository.dart';
import '../repositories/persona_repository.dart';

typedef DiaryModelCaller = Future<String?> Function(String prompt);

class DiaryGenerator {
  DiaryGenerator(
    this._db, {
    DiaryRepository? repository,
    PersonaRepository? personaRepository,
    DiaryModelCaller? caller,
    DateTime Function()? clock,
  }) : _repository = repository ?? DiaryRepository(_db, clock: clock),
       _persona = personaRepository ?? PersonaRepository(_db),
       _caller = caller,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DiaryRepository _repository;
  final PersonaRepository _persona;
  final DiaryModelCaller? _caller;
  final DateTime Function() _clock;

  DiaryRepository get repository => _repository;

  /// 当前时间（便于决策投递器沿用同一时钟）
  DateTime get now => _now();

  DateTime _now() => _clock();

  /// 整理某一天的日记（预览，不落库）
  Future<DiaryGeneratedDraft> generate({DateTime? date}) async {
    final day = date ?? _now();
    final materials = await _loadMaterials(day);
    final personaPrompt = await _loadPersonaPrompt();
    final dateKey = DiaryRules.dateKey(day);

    final caller = _caller;
    if (caller != null) {
      try {
        final prompt = DiaryRules.buildOrganizePrompt(
          dateKey: dateKey,
          materials: materials,
          personaPrompt: personaPrompt,
        );
        final content = (await caller(prompt) ?? '').trim();
        if (content.isNotEmpty && content.length <= DiaryRules.maxLength) {
          return DiaryGeneratedDraft(
            content: content,
            fromModel: true,
            relatedMessageIds: _idsOf(materials, 'message'),
            relatedMemoryIds: _idsOf(materials, 'memory'),
          );
        }
      } catch (error) {
        debugPrint('日记模型整理失败，回退本地整理：$error');
      }
    }

    return DiaryRules.localOrganize(dateKey: dateKey, materials: materials);
  }

  /// 保存整理结果（默认 AI 整理来源）
  Future<Diary> save(
    DiaryGeneratedDraft draft, {
    DateTime? date,
    DiaryOrigin origin = DiaryOrigin.aiOrganized,
  }) {
    return _repository.createDiary(
      DiaryDraft(
        entryDate: date ?? _now(),
        content: draft.content,
        origin: origin,
        relatedMessageIds: draft.relatedMessageIds,
        relatedMemoryIds: draft.relatedMemoryIds,
      ),
    );
  }

  Future<String> _loadPersonaPrompt() async {
    try {
      final profile = await _persona.profile();
      final prompt = profile.coreSystemPrompt ?? '';
      if (prompt.trim().isNotEmpty) return prompt;
      return await _persona.rebuildPromptSnapshot();
    } catch (_) {
      return '';
    }
  }

  /// 当天消息（按本地日期过滤）+ 活跃记忆
  Future<List<DiaryMaterial>> _loadMaterials(DateTime day) async {
    final messages =
        await (_db.select(_db.messages)
              ..where(
                (t) =>
                    t.deletedAt.isNull() &
                    t.status.equals('sent') &
                    t.role.isIn(const ['user', 'assistant']),
              )
              ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
              ..limit(300))
            .get();

    final materials = <DiaryMaterial>[];
    for (final message in messages) {
      final at = DateTime.tryParse(message.createdAt)?.toLocal();
      if (at == null) continue;
      if (at.year != day.year || at.month != day.month || at.day != day.day) {
        continue;
      }
      final content = message.content.trim();
      if (content.isEmpty) continue;
      final speaker = message.role == 'user' ? '你' : '泡泡';
      materials.add(
        DiaryMaterial(
          id: message.id,
          content: '$speaker：${_trim(content, 200)}',
          kind: 'message',
          timeLabel:
              '${at.hour.toString().padLeft(2, '0')}:'
              '${at.minute.toString().padLeft(2, '0')}',
        ),
      );
    }

    final memories =
        await (_db.select(_db.memories)
              ..where(
                (t) =>
                    t.deletedAt.isNull() &
                    t.status.equals('active') &
                    t.confidence.equals('low').not() &
                    t.sensitivity.isNull(),
              )
              ..orderBy([
                (t) => OrderingTerm.desc(t.importance),
                (t) => OrderingTerm.desc(t.updatedAt),
              ])
              ..limit(3))
            .get();
    for (final memory in memories) {
      final summary = memory.summary.trim();
      if (summary.isEmpty) continue;
      materials.add(
        DiaryMaterial(
          id: memory.id,
          content: _trim(summary, 120),
          kind: 'memory',
        ),
      );
    }
    return materials;
  }

  static List<String> _idsOf(List<DiaryMaterial> materials, String kind) {
    return materials
        .where((material) => material.kind == kind)
        .map((material) => material.id)
        .toList();
  }

  static String _trim(String text, int max) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= max) return cleaned;
    return '${cleaned.substring(0, max)}…';
  }
}
