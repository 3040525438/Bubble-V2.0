// 共同经历详情（T9.1）：历史事实只读、双视角可补、回顾记录只追加。
// 依据 UI_PAGE_SPEC §3、REQUIREMENTS FR-EXP-03。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/experience_repository.dart';
import '../../domain/experience/experience_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class ExperienceDetailPage extends StatefulWidget {
  const ExperienceDetailPage({
    super.key,
    required this.experienceId,
    this.repository,
  });

  final String experienceId;
  final ExperienceRepository? repository;

  @override
  State<ExperienceDetailPage> createState() => _ExperienceDetailPageState();
}

class _ExperienceDetailPageState extends State<ExperienceDetailPage> {
  late final ExperienceRepository _repo =
      widget.repository ?? ExperienceRepository(AppDb.instance);

  SharedExperience? _experience;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final experience = await _repo.getExperience(widget.experienceId);
    if (!mounted) return;
    setState(() {
      _experience = experience;
      _loading = false;
    });
  }

  Future<void> _editPerspective({required bool isUser}) async {
    final experience = _experience;
    if (experience == null) return;
    final current = isUser
        ? experience.userPerspective ?? ''
        : experience.bubblePerspective ?? '';
    final controller = TextEditingController(text: current);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isUser ? '你的视角' : '泡泡的视角'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '当时你是怎么想的？',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    await _repo.updatePerspectives(
      experience.id,
      userPerspective: isUser ? saved : null,
      bubblePerspective: isUser ? null : saved,
    );
    await _reload();
  }

  Future<void> _appendReview({required String author}) async {
    final experience = _experience;
    if (experience == null) return;
    final controller = TextEditingController();
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(author == 'user' ? '我来补一条回顾' : '泡泡补一条回顾'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '后来又想起这段经历时……',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('追加'),
          ),
        ],
      ),
    );
    if (saved == null || saved.isEmpty) return;
    try {
      await _repo.appendReview(
        experience.id,
        ExperienceReviewEntry(
          atMs: DateTime.now().millisecondsSinceEpoch,
          content: saved,
          author: author,
        ),
      );
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('追加失败：$error')));
    }
  }

  Future<void> _delete() async {
    final experience = _experience;
    if (experience == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从时间线移除？'),
        content: const Text('只是移出时间线，关联的记忆不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.softDelete(experience.id);
    if (!mounted) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final experience = _experience;
    return Scaffold(
      appBar: AppBar(
        title: const Text('共同经历'),
        actions: [
          IconButton(
            tooltip: '从时间线移除',
            onPressed: experience == null ? null : _delete,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : experience == null
          ? const Center(child: Text('这段经历不存在或已被移除'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
              children: [
                _factCard(context, onSurface, experience),
                const SizedBox(height: 14),
                _perspectiveSection(context, onSurface, experience),
                const SizedBox(height: 14),
                _reviewSection(context, onSurface, experience),
                if (experience.relatedMemoryIds != null) ...[
                  const SizedBox(height: 14),
                  _relatedSection(context, onSurface, experience),
                ],
              ],
            ),
    );
  }

  Widget _factCard(
    BuildContext context,
    Color onSurface,
    SharedExperience experience,
  ) {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            semantic.lavender.withValues(alpha: 0.3),
            semantic.mist.withValues(alpha: 0.25),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            experience.name,
            style: TextStyle(
              fontSize: BubbleFontSize.cardTitle,
              fontWeight: FontWeight.w800,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _formatDate(experience.occurredAt),
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            experience.eventContent,
            style: TextStyle(
              fontSize: BubbleFontSize.body,
              height: 1.75,
              color: onSurface.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 12),
          const MemoryLockBar(ExperienceRules.factLockNote),
        ],
      ),
    );
  }

  Widget _perspectiveSection(
    BuildContext context,
    Color onSurface,
    SharedExperience experience,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, '两种视角'),
        const SizedBox(height: 8),
        _perspectiveCard(
          context,
          onSurface,
          title: '你的视角',
          icon: Icons.person_outline_rounded,
          content: experience.userPerspective,
          onEdit: () => _editPerspective(isUser: true),
        ),
        const SizedBox(height: 8),
        _perspectiveCard(
          context,
          onSurface,
          title: '泡泡的视角',
          icon: Icons.cloud_outlined,
          content: experience.bubblePerspective,
          onEdit: () => _editPerspective(isUser: false),
        ),
      ],
    );
  }

  Widget _perspectiveCard(
    BuildContext context,
    Color onSurface, {
    required String title,
    required IconData icon,
    required String? content,
    required VoidCallback onEdit,
  }) {
    final semantic = context.bubbleColors;
    final text = (content ?? '').trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
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
              Icon(icon, size: 17, color: semantic.lavenderDeep),
              const SizedBox(width: 6),
              Text(
                title,
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w700,
                  color: onSurface,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: onEdit,
                child: Text(text.isEmpty ? '补充' : '编辑'),
              ),
            ],
          ),
          if (text.isEmpty)
            Text(
              '还没有写下这个视角',
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.4),
              ),
            )
          else
            Text(
              text,
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                height: 1.65,
                color: onSurface.withValues(alpha: 0.78),
              ),
            ),
        ],
      ),
    );
  }

  Widget _reviewSection(
    BuildContext context,
    Color onSurface,
    SharedExperience experience,
  ) {
    final reviews = ExperienceRules.parseReviewLog(experience.reviewLog);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionTitle(context, '回顾记录（${reviews.length}）'),
            const Spacer(),
            TextButton(
              onPressed: () => _appendReview(author: 'user'),
              child: const Text('我来补'),
            ),
            TextButton(
              onPressed: () => _appendReview(author: 'bubble'),
              child: const Text('泡泡补'),
            ),
          ],
        ),
        if (reviews.isEmpty)
          Text(
            '还没有回顾。回顾记录只会追加，不会覆盖之前的内容。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.45),
            ),
          )
        else
          for (final review in reviews) ...[
            _reviewRow(context, onSurface, review),
            const SizedBox(height: 6),
          ],
      ],
    );
  }

  Widget _reviewRow(
    BuildContext context,
    Color onSurface,
    ExperienceReviewEntry review,
  ) {
    final semantic = context.bubbleColors;
    final isUser = review.author == 'user';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isUser
            ? semantic.bubbleUserA.withValues(alpha: 0.1)
            : semantic.lavender.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MemoryBadge(
                text: review.authorLabel,
                color: isUser ? semantic.bubbleUserA : semantic.lavenderDeep,
                background: Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDateTime(review.atMs),
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            review.content,
            style: TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              height: 1.6,
              color: onSurface.withValues(alpha: 0.78),
            ),
          ),
        ],
      ),
    );
  }

  Widget _relatedSection(
    BuildContext context,
    Color onSurface,
    SharedExperience experience,
  ) {
    final ids = (experience.relatedMemoryIds ?? '')
        .replaceAll(RegExp(r'[\[\]"]'), '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (ids.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(context, '关联记忆'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final id in ids)
              ActionChip(
                label: Text(id.length > 14 ? '${id.substring(0, 14)}…' : id),
                onPressed: () => context.push('/memory/detail/$id'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: BubbleFontSize.bodySmall,
        fontWeight: FontWeight.w700,
        color: context.bubbleColors.lavenderDeep,
      ),
    );
  }

  String _formatDate(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${local.year}年${local.month.toString().padLeft(2, '0')}月'
        '${local.day.toString().padLeft(2, '0')}日';
  }

  String _formatDateTime(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${_formatDate(ms)} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
