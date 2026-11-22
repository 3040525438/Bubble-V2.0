// 泡泡写信生成器（T11.2）：共同经历 + 记忆素材、7 天冷却、未配置模型时本地草稿。
// 依据 REQUIREMENTS FR-LET-01、UI_PAGE_SPEC §18/§19/§34。
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../domain/letter/letter_models.dart';
import '../database/app_database.dart';
import '../repositories/letter_repository.dart';
import '../repositories/persona_repository.dart';

typedef LetterModelCaller = Future<String?> Function(String prompt);

class LetterGenerator {
  LetterGenerator(
    this._db, {
    LetterRepository? repository,
    PersonaRepository? personaRepository,
    LetterModelCaller? caller,
    DateTime Function()? clock,
  }) : _repository = repository ?? LetterRepository(_db, clock: clock),
       _persona = personaRepository ?? PersonaRepository(_db),
       _caller = caller,
       _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final LetterRepository _repository;
  final PersonaRepository _persona;
  final LetterModelCaller? _caller;
  final DateTime Function() _clock;

  LetterRepository get repository => _repository;

  DateTime _now() => _clock();

  /// 生成一封泡泡来信（预览，不落库）；冷却中抛出 StateError
  Future<LetterGeneratedDraft> generate() async {
    final last = await _repository.lastBubbleSentAtMs();
    final nowMs = _now().millisecondsSinceEpoch;
    if (!LetterRules.canBubbleSend(lastSentAtMs: last, nowMs: nowMs)) {
      final nextAt = LetterRules.nextBubbleSendAtMs(last!);
      throw StateError(
        '泡泡的信至少间隔 ${LetterRules.cooldownDays} 天，'
        '${LetterRules.cooldownLabel(nextAt)}之后才能再写',
      );
    }

    final materials = await _loadMaterials();
    final personaPrompt = await _loadPersonaPrompt();
    final recent = await _repository.recentContents(limit: 3);

    final caller = _caller;
    if (caller != null) {
      try {
        final prompt = LetterRules.buildComposePrompt(
          materials: materials,
          personaPrompt: personaPrompt,
          recentLetters: recent,
        );
        final content = (await caller(prompt) ?? '').trim();
        if (content.isNotEmpty && content.length <= LetterRules.maxLength) {
          return LetterGeneratedDraft(
            content: content,
            fromModel: true,
            title: LetterRules.deriveTitle(content),
            relatedMemoryIds: _idsOf(materials, 'memory'),
            relatedExperienceIds: _idsOf(materials, 'experience'),
          );
        }
      } catch (error) {
        debugPrint('信件模型生成失败，回退本地草稿：$error');
      }
    }

    return LetterRules.localCompose(
      materials: materials,
      personaPrompt: personaPrompt,
    );
  }

  /// 保存为草稿（泡泡来信先落草稿，用户读过后再决定是否寄出）
  Future<Letter> saveAsDraft(LetterGeneratedDraft draft) {
    return _repository.createDraft(
      LetterDraft(
        direction: LetterDirection.bubbleToUser,
        content: draft.content,
        title: draft.title,
        relatedMemoryIds: draft.relatedMemoryIds,
        relatedExperienceIds: draft.relatedExperienceIds,
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

  /// 素材：最近共同经历 + 活跃非敏感记忆
  Future<List<LetterMaterial>> _loadMaterials() async {
    final materials = <LetterMaterial>[];
    final experiences =
        await (_db.select(_db.sharedExperiences)
              ..where((t) => t.deletedAt.isNull())
              ..orderBy([
                (t) => OrderingTerm.desc(t.importance),
                (t) => OrderingTerm.desc(t.occurredAt),
              ])
              ..limit(3))
            .get();
    for (final experience in experiences) {
      materials.add(
        LetterMaterial(
          id: experience.id,
          title: experience.name,
          summary: experience.eventContent,
          kind: 'experience',
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
      materials.add(
        LetterMaterial(
          id: memory.id,
          title: memory.title ?? '',
          summary: memory.summary,
        ),
      );
    }
    return materials;
  }

  static List<String> _idsOf(List<LetterMaterial> materials, String kind) {
    return materials
        .where((material) => material.kind == kind)
        .map((material) => material.id)
        .toList();
  }
}
