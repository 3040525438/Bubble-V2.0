// 说说领域规则单测（T10.1/T10.2）：校验、去重、提示词、本地降级。
import 'package:bubble/domain/post/post_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('草稿校验', () {
    test('合法草稿通过', () {
      expect(
        PostRules.validateDraft(const PostDraft(content: '今天想你了')),
        isNull,
      );
    });

    test('空内容与超长被拒绝', () {
      expect(
        PostRules.validateDraft(const PostDraft(content: '   ')),
        '说说内容不能为空',
      );
      expect(
        PostRules.validateDraft(PostDraft(content: '很' * 501)),
        '说说不超过 500 字',
      );
    });

    test('指定主题生成必须填主题', () {
      expect(
        PostRules.validateDraft(
          const PostDraft(content: '内容', origin: PostOrigin.userTopic),
        ),
        '指定主题生成需要填写主题',
      );
      expect(
        PostRules.validateDraft(
          const PostDraft(
            content: '内容',
            origin: PostOrigin.userTopic,
            topic: '下雨天',
          ),
        ),
        isNull,
      );
    });
  });

  group('去重', () {
    test('相同内容判定重复', () {
      final result = PostRules.dedup('今天想你了', ['今天想你了']);
      expect(result.duplicate, isTrue);
      expect(result.maxSimilarity, 1.0);
      expect(result.matchedContent, '今天想你了');
    });

    test('完全不同内容不判重复', () {
      final result = PostRules.dedup('今天想你了', ['明天要下雨记得带伞']);
      expect(result.duplicate, isFalse);
      expect(result.maxSimilarity, lessThan(0.2));
    });

    test('空历史与空内容安全', () {
      expect(PostRules.dedup('今天想你了', const []).duplicate, isFalse);
      expect(PostRules.dedup('', ['今天想你了']).duplicate, isFalse);
    });
  });

  group('提示词', () {
    test('包含人格、素材、最近说说与主题', () {
      final prompt = PostRules.buildPrompt(
        const PostGenerationRequest(
          mode: PostGenerationMode.userTopic,
          topic: '下雨天',
          mood: PostMood.mood,
          personaPrompt: '温柔、安静，说话慢一点',
          materials: [
            PostMaterial(id: 'm1', title: '西湖看雪', summary: '那天看到第一场雪'),
          ],
          recentContents: ['今天想你了'],
        ),
      );
      expect(prompt, contains('温柔、安静'));
      expect(prompt, contains('西湖看雪'));
      expect(prompt, contains('今天想你了'));
      expect(prompt, contains('下雨天'));
      expect(prompt, contains('心情：心情'));
      expect(prompt, contains('不要编造'));
    });

    test('无人格时给出默认约束', () {
      final prompt = PostRules.buildPrompt(
        const PostGenerationRequest(mode: PostGenerationMode.autonomous),
      );
      expect(prompt, contains('温柔、真诚'));
      expect(prompt, contains('主题：从上面的记忆里自然想起一件小事'));
    });
  });

  group('本地降级生成', () {
    test('有素材时引用素材并标注非模型', () {
      final draft = PostRules.localGenerate(
        const PostGenerationRequest(
          mode: PostGenerationMode.autonomous,
          mood: PostMood.thought,
          personaPrompt: '温柔',
          materials: [
            PostMaterial(id: 'm1', title: '西湖看雪', summary: '那天我们在湖边看雪'),
          ],
        ),
      );
      expect(draft.content, contains('西湖看雪'));
      expect(draft.fromModel, isFalse);
      expect(draft.origin, PostOrigin.autonomous);
      expect(draft.mood, PostMood.thought);
      expect(draft.relatedMemoryIds, ['m1']);
      expect(draft.content, contains('慢慢来'));
    });

    test('指定主题生成标注 user_topic', () {
      final draft = PostRules.localGenerate(
        const PostGenerationRequest(
          mode: PostGenerationMode.userTopic,
          topic: '下雨天',
          personaPrompt: '调皮',
        ),
      );
      expect(draft.origin, PostOrigin.userTopic);
      expect(draft.topic, '下雨天');
      expect(draft.content, contains('下雨天'));
      expect(draft.content, contains('等你有空'));
    });

    test('无素材无主题也能生成自然的兜底句', () {
      final draft = PostRules.localGenerate(
        const PostGenerationRequest(mode: PostGenerationMode.autonomous),
      );
      expect(draft.content, contains('想和你说说话'));
      expect(draft.relatedMemoryIds, isEmpty);
    });
  });

  test('草稿 JSON 往返保留心情与来源', () {
    const draft = PostDraft(
      content: '今天想你了',
      mood: PostMood.mood,
      topic: '想你',
      origin: PostOrigin.userTopic,
      relatedMemoryIds: ['m1'],
    );
    final restored = PostDraft.fromJson(draft.toJson())!;
    expect(restored.content, '今天想你了');
    expect(restored.mood, PostMood.mood);
    expect(restored.origin, PostOrigin.userTopic);
    expect(restored.topic, '想你');
    expect(restored.relatedMemoryIds, ['m1']);
  });
}
