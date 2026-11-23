// 共同经历时间线（T9.1，Tab3）：垂直时间轴、重要程度、双视角徽章与回顾计数。
// 依据 UI_PAGE_SPEC §3、REQUIREMENTS FR-EXP；历史事实不可修改，回顾记录只追加。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/experience_repository.dart';
import '../../domain/experience/experience_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key, this.repository});

  final ExperienceRepository? repository;

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  late final ExperienceRepository _repo =
      widget.repository ?? ExperienceRepository(AppDb.instance);

  List<SharedExperience> _items = const <SharedExperience>[];
  bool _loading = true;
  bool _discovering = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await _repo.listExperiences();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _discover() async {
    if (_discovering) return;
    setState(() => _discovering = true);
    try {
      final fromMemory = await _repo.nominateFromMemories();
      final fromThinking = await _repo.nominateFromThinking();
      final nominations = <ExperienceNomination>[
        ...fromMemory,
        ...fromThinking,
      ];
      if (!mounted) return;
      setState(() => _discovering = false);
      if (nominations.isEmpty) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('暂时没有发现新的候选经历'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return;
      }
      final selected = await showModalBottomSheet<List<ExperienceNomination>>(
        context: context,
        showDragHandle: true,
        builder: (context) => _NominationSheet(nominations: nominations),
      );
      if (selected == null || selected.isEmpty) return;
      for (final nomination in selected) {
        await _repo.createFromNomination(nomination);
      }
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              selected.length == 1
                  ? '已写进时间线，之后可以补充双视角与回顾'
                  : '已把 ${selected.length} 条候选写进时间线',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } catch (error) {
      if (!mounted) return;
      setState(() => _discovering = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('发现候选失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final semantic = context.bubbleColors;
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
        children: [
          Row(
            children: [
              Text(
                '共同经历',
                style: TextStyle(
                  fontSize: BubbleFontSize.pageTitle,
                  fontWeight: FontWeight.w700,
                  color: onSurface,
                ),
              ),
              const SizedBox(width: 8),
              MemoryBadge(
                text: '${_items.length}',
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.2),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _discovering ? null : _discover,
                icon: _discovering
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome_rounded, size: 16),
                label: const Text('从记忆里发现'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '一起发生过的事、当时的两份视角，以及后来每一次回看。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 40),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_items.isEmpty)
            const MemoryEmptyCard(
              title: '时间线还是空的',
              subtitle:
                  '聊到共同经历、重要事件时，泡泡会在这里留下候选。'
                  '你也可以从已有记忆里发现值得记住的片段。',
            )
          else
            for (var i = 0; i < _items.length; i++)
              _timelineRow(
                context,
                onSurface,
                _items[i],
                isLast: i == _items.length - 1,
              ),
        ],
      ),
    );
  }

  Widget _timelineRow(
    BuildContext context,
    Color onSurface,
    SharedExperience experience, {
    required bool isLast,
  }) {
    final semantic = context.bubbleColors;
    final reviews = ExperienceRules.parseReviewLog(experience.reviewLog);
    final important = experience.importance >= 80;
    final emotional =
        (experience.userPerspective ?? '').isNotEmpty ||
        (experience.bubblePerspective ?? '').isNotEmpty;
    final dotColor = important
        ? semantic.lavenderDeep
        : (emotional ? semantic.pinkDeep : semantic.bubbleUserA);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(
                  width: 11,
                  height: 11,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: dotColor,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: dotColor.withValues(alpha: 0.35),
                      width: 3,
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(child: Container(width: 2, color: semantic.stroke)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(BubbleRadius.card),
                child: InkWell(
                  borderRadius: BorderRadius.circular(BubbleRadius.card),
                  onTap: () => context.push('/experience/${experience.id}'),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                experience.name,
                                style: TextStyle(
                                  fontSize: BubbleFontSize.cardTitle,
                                  fontWeight: FontWeight.w700,
                                  color: onSurface,
                                ),
                              ),
                            ),
                            Text(
                              _stars(experience.importance),
                              style: TextStyle(
                                fontSize: BubbleFontSize.badge,
                                color: semantic.warnDeep,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatDate(experience.occurredAt),
                          style: TextStyle(
                            fontSize: BubbleFontSize.badge,
                            color: onSurface.withValues(alpha: 0.45),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          experience.eventContent,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: BubbleFontSize.bodySmall,
                            height: 1.6,
                            color: onSurface.withValues(alpha: 0.75),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            if ((experience.userPerspective ?? '').isNotEmpty)
                              MemoryBadge(
                                text: '你的视角',
                                color: semantic.bubbleUserA,
                                background: semantic.bubbleUserA.withValues(
                                  alpha: 0.15,
                                ),
                              ),
                            if ((experience.bubblePerspective ?? '').isNotEmpty)
                              MemoryBadge(
                                text: '泡泡的视角',
                                color: semantic.lavenderDeep,
                                background: semantic.lavender.withValues(
                                  alpha: 0.2,
                                ),
                              ),
                            if (reviews.isNotEmpty)
                              MemoryBadge(
                                text: '回顾 ${reviews.length} 次',
                                color: onSurface.withValues(alpha: 0.6),
                                background: semantic.surfaceAlt,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _stars(int importance) {
    if (importance >= 80) return '★★★';
    if (importance >= 60) return '★★';
    return '★';
  }

  String _formatDate(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${local.year}年${local.month.toString().padLeft(2, '0')}月'
        '${local.day.toString().padLeft(2, '0')}日';
  }
}

class _NominationSheet extends StatelessWidget {
  const _NominationSheet({required this.nominations});

  final List<ExperienceNomination> nominations;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '可以记下的片段',
              style: TextStyle(
                fontSize: BubbleFontSize.cardTitle,
                fontWeight: FontWeight.w700,
                color: onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '泡泡只提出候选，确认后才会写进时间线。',
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: nominations.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final nomination = nominations[index];
                  return Material(
                    color: context.bubbleColors.surfaceAlt.withValues(
                      alpha: 0.55,
                    ),
                    borderRadius: BorderRadius.circular(BubbleRadius.badge),
                    child: ListTile(
                      title: Text(nomination.suggestedName),
                      subtitle: Text(
                        nomination.reason,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.add_circle_outline_rounded),
                      onTap: () => Navigator.of(context).pop([nomination]),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(List.of(nominations)),
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: Text('全部加入（${nominations.length}）'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
