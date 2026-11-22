// 说说生成器（T10.2）：人格 + 记忆素材 + 去重约束；真实模型可注入，未配置时本地降级。
// 依据 AUTONOMOUS_SYSTEM §4、REQUIREMENTS FR-POST、UI_PAGE_SPEC §29。
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../domain/post/post_models.dart';
import '../database/app_database.dart';
import '../proactive/proactive_decision_center.dart';
import '../repositories/persona_repository.dart';
import '../repositories/post_repository.dart';

typedef PostModelCaller = Future<String?> Function(String prompt);

class PostGenerator {
  PostGenerator(
    this._db, {
    PostRepository? repository,
    PersonaRepository? personaRepository,
    PostModelCaller? caller,
    DateTime Function()? clock,
  }) : _repository = repository ?? PostRepository(_db, clock: clock),
       _persona = personaRepository ?? PersonaRepository(_db),
       _caller = caller;

  final AppDatabase _db;
  final PostRepository _repository;
  final PersonaRepository _persona;
  final PostModelCaller? _caller;

  PostRepository get repository => _repository;

  /// 生成一条说说草稿（预览，不落库）
  Future<PostGeneratedDraft> generate({
    required PostGenerationMode mode,
    String? topic,
    PostMood? mood,
  }) async {
    final personaPrompt = await _loadPersonaPrompt();
    final materials = await _loadMaterials();
    final recent = await _repository.recentContents(limit: 10);
    final request = PostGenerationRequest(
      mode: mode,
      topic: topic,
      mood: mood,
      personaPrompt: personaPrompt,
      materials: materials,
      recentContents: recent,
    );

    final caller = _caller;
    if (caller != null) {
      try {
        final prompt = PostRules.buildPrompt(request);
        var content = (await caller(prompt) ?? '').trim();
        if (content.isNotEmpty && content.length <= PostRules.maxLength) {
          var dedup = PostRules.dedup(content, recent);
          if (dedup.duplicate) {
            // 重复时再请求一次，明确要求换角度
            final retryPrompt =
                '$prompt\n\n注意：下面这条已经发过，不要重复它的主题与表达：\n'
                '${dedup.matchedContent ?? ''}\n请换一个完全不同的角度。';
            final retry = (await caller(retryPrompt) ?? '').trim();
            if (retry.isNotEmpty && retry.length <= PostRules.maxLength) {
              content = retry;
              dedup = PostRules.dedup(content, recent);
            }
          }
          return PostGeneratedDraft(
            content: content,
            origin: mode == PostGenerationMode.userTopic
                ? PostOrigin.userTopic
                : PostOrigin.autonomous,
            mood: mood ?? PostMood.daily,
            topic: (topic ?? '').trim().isEmpty ? null : topic!.trim(),
            fromModel: true,
            duplicateRisk: dedup.duplicate,
          );
        }
      } catch (error) {
        debugPrint('说说模型生成失败，回退本地降级：$error');
      }
    }

    final local = PostRules.localGenerate(request);
    final dedup = PostRules.dedup(local.content, recent);
    return PostGeneratedDraft(
      content: local.content,
      origin: local.origin,
      mood: local.mood,
      topic: local.topic,
      relatedMemoryIds: local.relatedMemoryIds,
      fromModel: false,
      duplicateRisk: dedup.duplicate,
    );
  }

  /// 发布生成结果
  Future<Post> publish(PostGeneratedDraft draft) {
    return _repository.createPost(
      PostDraft(
        content: draft.content,
        mood: draft.mood,
        topic: draft.topic,
        origin: draft.origin,
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

  /// 素材：活跃、非敏感、置信度非低的高重要度记忆（不编造未发生的经历）
  Future<List<PostMaterial>> _loadMaterials({int limit = 6}) async {
    final rows =
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
              ..limit(limit))
            .get();
    return rows
        .map(
          (row) => PostMaterial(
            id: row.id,
            title: row.title ?? '',
            summary: row.summary,
          ),
        )
        .toList();
  }
}

/// 决策中心投递器：post 类候选走生成器真实发布，其余保持记录模式。
ProactiveDeliverer postAwareDeliverer(PostGenerator generator) {
  return (candidate) async {
    if (candidate.actionKind != 'post') {
      return recordOnlyDeliverer(candidate);
    }
    final topic = (candidate.title ?? '').trim();
    final source = candidate.sourceKind ?? '';
    final mood = source == 'share_worthy' ? PostMood.thought : PostMood.daily;
    final draft = await generator.generate(
      mode: PostGenerationMode.autonomous,
      topic: topic.isEmpty ? null : topic,
      mood: mood,
    );
    if (draft.duplicateRisk) {
      return const ProactiveDelivery(note: '生成内容与最近说说过于相似，本轮跳过以避免重复表达');
    }
    final post = await generator.publish(draft);
    return ProactiveDelivery(
      deliverableType: 'post',
      deliverableId: post.id,
      note:
          '自主发布说说：${post.content.length > 24 ? '${post.content.substring(0, 24)}…' : post.content}',
    );
  };
}
