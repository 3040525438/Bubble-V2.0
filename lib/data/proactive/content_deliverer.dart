// 统一内容投递器（T11.3）：post / diary / letter 由各自生成器真实落地，其余保持记录模式。
// 决策中心仍是唯一执行入口（FR-DEC-01/03），本文件只负责把已批准候选变成真实内容。
import '../../domain/diary/diary_models.dart';
import '../../domain/letter/letter_models.dart';
import '../../domain/post/post_models.dart';
import '../database/app_database.dart';
import '../diary/diary_generator.dart';
import '../letter/letter_generator.dart';
import '../post/post_generator.dart';
import '../proactive/proactive_decision_center.dart';

ProactiveDeliverer contentAwareDeliverer({
  PostGenerator? post,
  DiaryGenerator? diary,
  LetterGenerator? letter,
}) {
  return (candidate) async {
    try {
      switch (candidate.actionKind) {
        case 'post':
          if (post == null) return await recordOnlyDeliverer(candidate);
          return await _deliverPost(post, candidate);
        case 'diary':
          if (diary == null) return await recordOnlyDeliverer(candidate);
          return await _deliverDiary(diary, candidate);
        case 'letter':
          if (letter == null) return await recordOnlyDeliverer(candidate);
          return await _deliverLetter(letter, candidate);
        default:
          return await recordOnlyDeliverer(candidate);
      }
    } catch (error) {
      return ProactiveDelivery(note: '生成或保存失败：$error');
    }
  };
}

Future<ProactiveDelivery> _deliverPost(
  PostGenerator generator,
  ProactiveCandidate candidate,
) async {
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
  final preview = post.content.length > 24
      ? '${post.content.substring(0, 24)}…'
      : post.content;
  return ProactiveDelivery(
    deliverableType: 'post',
    deliverableId: post.id,
    note: '自主发布说说：$preview',
  );
}

Future<ProactiveDelivery> _deliverDiary(
  DiaryGenerator generator,
  ProactiveCandidate candidate,
) async {
  final now = generator.now;
  final existing = await generator.repository.listByDate(now);
  if (existing.isNotEmpty) {
    return const ProactiveDelivery(note: '今天已经有日记了，本轮跳过重复整理');
  }
  final draft = await generator.generate(date: now);
  final saved = await generator.save(draft, date: now);
  return ProactiveDelivery(
    deliverableType: 'diary',
    deliverableId: saved.id,
    note: draft.fromModel
        ? '整理了今天的日记：${DiaryRules.deriveTitle(saved.content)}'
        : '生成本地整理草稿：${DiaryRules.deriveTitle(saved.content)}',
  );
}

Future<ProactiveDelivery> _deliverLetter(
  LetterGenerator generator,
  ProactiveCandidate candidate,
) async {
  final canSend = await generator.repository.canBubbleSendNow();
  if (!canSend) {
    return const ProactiveDelivery(note: '距离上一封泡泡来信不足 7 天，本轮跳过');
  }
  final draft = await generator.generate();
  if (draft.fromModel) {
    final sent = await generator.repository.createAndSend(
      LetterDraft(
        direction: LetterDirection.bubbleToUser,
        content: draft.content,
        title: draft.title,
        relatedMemoryIds: draft.relatedMemoryIds,
        relatedExperienceIds: draft.relatedExperienceIds,
      ),
    );
    return ProactiveDelivery(
      deliverableType: 'letter',
      deliverableId: sent.id,
      note: '泡泡寄出了一封信：${sent.title ?? LetterRules.deriveTitle(sent.content)}',
    );
  }
  final saved = await generator.saveAsDraft(draft);
  return ProactiveDelivery(
    deliverableType: 'letter_draft',
    deliverableId: saved.id,
    note: '生成本地信件草稿，读过后由你决定是否寄出',
  );
}
