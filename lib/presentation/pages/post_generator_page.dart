// 说说生成器（T10.2）：自主生成 / 指定主题，预览可改，重复风险提示后再发布。
// 依据 UI_PAGE_SPEC §29、AUTONOMOUS_SYSTEM §4。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/post/post_generator.dart';
import '../../domain/post/post_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class PostGeneratorPage extends StatefulWidget {
  const PostGeneratorPage({super.key, this.generator});

  final PostGenerator? generator;

  @override
  State<PostGeneratorPage> createState() => _PostGeneratorPageState();
}

class _PostGeneratorPageState extends State<PostGeneratorPage> {
  late final PostGenerator _generator =
      widget.generator ?? PostGenerator(AppDb.instance);

  final TextEditingController _topicController = TextEditingController();
  final TextEditingController _previewController = TextEditingController();

  PostGenerationMode _mode = PostGenerationMode.autonomous;
  PostMood _mood = PostMood.daily;
  PostGeneratedDraft? _draft;
  bool _generating = false;
  bool _publishing = false;
  String? _error;

  @override
  void dispose() {
    _topicController.dispose();
    _previewController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_generating) return;
    final topic = _topicController.text.trim();
    if (_mode == PostGenerationMode.userTopic && topic.isEmpty) {
      setState(() => _error = '先写一个主题，再让泡泡按主题生成');
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final draft = await _generator.generate(
        mode: _mode,
        topic: topic.isEmpty ? null : topic,
        mood: _mood,
      );
      if (!mounted) return;
      _previewController.text = draft.content;
      setState(() {
        _draft = draft;
        _generating = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _error = '生成失败：$error';
      });
    }
  }

  Future<void> _publish() async {
    final draft = _draft;
    if (draft == null || _publishing) return;
    final content = _previewController.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '说说内容不能为空');
      return;
    }
    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      await _generator.publish(
        PostGeneratedDraft(
          content: content,
          origin: draft.origin,
          mood: _mood,
          topic: draft.topic,
          relatedMemoryIds: draft.relatedMemoryIds,
          fromModel: draft.fromModel,
          duplicateRisk: draft.duplicateRisk,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('已发布到说说'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      context.pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = '发布失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(title: const Text('写一篇说说')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
        children: [
          _modeCard(context, onSurface),
          const SizedBox(height: 14),
          if (_mode == PostGenerationMode.userTopic) ...[
            TextField(
              controller: _topicController,
              decoration: const InputDecoration(
                labelText: '主题',
                hintText: '例如：今天想聊聊下雨天',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            '心情基调',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              fontWeight: FontWeight.w700,
              color: context.bubbleColors.lavenderDeep,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final mood in PostMood.values)
                _moodChip(context, mood, onSurface),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _generating ? null : _generate,
            icon: _generating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(
              _generating
                  ? '正在写…'
                  : (_mode == PostGenerationMode.autonomous ? '生成一篇' : '按主题生成'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: context.bubbleColors.dangerDeep,
              ),
            ),
          ],
          if (_draft != null) ...[
            const SizedBox(height: 18),
            _previewCard(context, onSurface),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: _publishing ? null : _publish,
              child: Text(_publishing ? '发布中…' : '发布这篇'),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            '先预览再发布 · 正文可以逐字修改 · 发布时会标记生成方式。'
            '未配置模型时显示的是本地草稿，不会冒充模型生成的内容。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.5,
              color: onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeCard(BuildContext context, Color onSurface) {
    return Row(
      children: [
        Expanded(
          child: _modeTile(
            context,
            onSurface,
            mode: PostGenerationMode.autonomous,
            icon: Icons.auto_awesome_rounded,
            title: '自主生成',
            subtitle: '从记忆里自然想起一件小事',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _modeTile(
            context,
            onSurface,
            mode: PostGenerationMode.userTopic,
            icon: Icons.edit_note_rounded,
            title: '指定主题',
            subtitle: '给她一个主题与心情',
          ),
        ),
      ],
    );
  }

  Widget _modeTile(
    BuildContext context,
    Color onSurface, {
    required PostGenerationMode mode,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final semantic = context.bubbleColors;
    final selected = _mode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      onTap: () => setState(() => _mode = mode),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? semantic.lavender.withValues(alpha: 0.18)
              : semantic.surfaceAlt.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(BubbleRadius.card),
          border: Border.all(
            color: selected ? semantic.lavenderDeep : Colors.transparent,
            width: selected ? 1.5 : 0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: semantic.lavenderDeep),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                fontWeight: FontWeight.w700,
                color: onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                height: 1.4,
                color: onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moodChip(BuildContext context, PostMood mood, Color onSurface) {
    final semantic = context.bubbleColors;
    final selected = _mood == mood;
    return InkWell(
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: () => setState(() => _mood = mood),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? semantic.pink.withValues(alpha: 0.35)
              : semantic.surfaceAlt.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
        ),
        child: Text(
          mood.label,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: onSurface,
          ),
        ),
      ),
    );
  }

  Widget _previewCard(BuildContext context, Color onSurface) {
    final draft = _draft!;
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MemoryBadge(
                text: draft.fromModel ? '模型生成' : '本地草稿',
                color: draft.fromModel
                    ? semantic.successDeep
                    : semantic.warnDeep,
                background: (draft.fromModel ? semantic.success : semantic.warn)
                    .withValues(alpha: 0.15),
              ),
              const SizedBox(width: 6),
              MemoryBadge(
                text: draft.origin.label,
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.18),
              ),
              if (draft.duplicateRisk) ...[
                const SizedBox(width: 6),
                MemoryBadge(
                  text: '可能重复',
                  color: semantic.dangerDeep,
                  background: semantic.danger.withValues(alpha: 0.15),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          if (draft.duplicateRisk)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '这条和最近发过的说说有点像。可以改一改再发，或者换一个主题重新生成。',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  height: 1.5,
                  color: semantic.dangerDeep,
                ),
              ),
            ),
          TextField(
            controller: _previewController,
            minLines: 4,
            maxLines: 10,
            style: TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              height: 1.7,
              color: onSurface.withValues(alpha: 0.85),
            ),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '说说正文',
            ),
          ),
        ],
      ),
    );
  }
}
