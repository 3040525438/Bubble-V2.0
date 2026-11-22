// 反馈历史页（T14.6）：查看并撤销历史反馈。
// 依据 REQUIREMENTS FR-FBK-01/02、UI_PAGE_SPEC §28（说说详情反馈闭环）。
import 'package:flutter/material.dart';

import '../../data/database/db_provider.dart';
import '../../data/repositories/feedback_repository.dart';
import '../../domain/feedback/feedback_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class FeedbackHistoryPage extends StatefulWidget {
  const FeedbackHistoryPage({super.key, this.repository});

  final FeedbackRepository? repository;

  @override
  State<FeedbackHistoryPage> createState() => _FeedbackHistoryPageState();
}

class _FeedbackHistoryPageState extends State<FeedbackHistoryPage> {
  late final FeedbackRepository _repo =
      widget.repository ?? FeedbackRepository(AppDb.instance);

  List<FeedbackEntry> _entries = const [];
  FeedbackSummary _summary = FeedbackSummary.empty();
  FeedbackTargetKind? _filter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await _repo.recent(kind: _filter);
    final summary = await _repo.summary();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _summary = summary;
      _loading = false;
    });
  }

  Future<void> _revert(FeedbackEntry entry) async {
    try {
      await _repo.revert(entry.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('撤销失败：$e')));
      return;
    }
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已撤销该条反馈')));
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Scaffold(
      appBar: AppBar(title: const Text('反馈历史')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: semantic.surfaceAlt.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(BubbleRadius.card),
                ),
                child: Row(
                  children: [
                    _SummaryChip(label: '全部', value: _summary.total),
                    const SizedBox(width: 8),
                    _SummaryChip(label: '生效', value: _summary.active),
                    const SizedBox(width: 8),
                    _SummaryChip(label: '已撤销', value: _summary.reverted),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 42,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                children: [
                  _FilterChip(
                    label: '全部',
                    active: _filter == null,
                    onTap: () {
                      setState(() => _filter = null);
                      _reload();
                    },
                  ),
                  for (final kind in FeedbackTargetKind.values)
                    _FilterChip(
                      label: kind.label,
                      active: _filter == kind,
                      onTap: () {
                        setState(() => _filter = kind);
                        _reload();
                      },
                    ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _entries.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: MemoryEmptyCard(
                        title: '还没有反馈记录',
                        subtitle: '在说说详情等处给泡泡反馈后，会出现在这里并可撤销',
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: _entries.length,
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _FeedbackCard(
                            entry: entry,
                            onRevert: entry.isReverted
                                ? null
                                : () => _revert(entry),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              fontSize: BubbleFontSize.profileName,
              fontWeight: FontWeight.w800,
              color: semantic.lavenderDeep,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? semantic.lavender.withValues(alpha: 0.22)
                : semantic.surfaceAlt,
            borderRadius: BorderRadius.circular(BubbleRadius.badge),
            border: Border.all(
              color: active ? semantic.lavender : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active
                  ? semantic.lavenderDeep
                  : Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.65),
            ),
          ),
        ),
      ),
    );
  }
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.entry, this.onRevert});

  final FeedbackEntry entry;
  final VoidCallback? onRevert;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final verdictColor = switch (entry.verdict) {
      FeedbackVerdict.like => semantic.successDeep,
      FeedbackVerdict.dislike => semantic.dangerDeep,
      FeedbackVerdict.adjust => semantic.lavenderDeep,
      FeedbackVerdict.correct => semantic.warnDeep,
    };
    final time = entry.createdAtTime;
    return Opacity(
      opacity: entry.isReverted ? 0.55 : 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: semantic.surfaceAlt.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(BubbleRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                MemoryBadge(
                  text: entry.targetKind.label,
                  color: semantic.lavenderDeep,
                  background: semantic.lavender.withValues(alpha: 0.18),
                ),
                const SizedBox(width: 6),
                MemoryBadge(
                  text: entry.verdict.label,
                  color: verdictColor,
                  background: verdictColor.withValues(alpha: 0.14),
                ),
                const Spacer(),
                if (entry.isReverted)
                  MemoryBadge(
                    text: '已撤销',
                    color: semantic.dangerDeep,
                    background: semantic.danger.withValues(alpha: 0.14),
                  ),
              ],
            ),
            if (entry.note != null && entry.note!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                entry.note!,
                style: const TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    time == null
                        ? entry.createdAt
                        : '${_fmt(time)} · 目标 ${entry.targetId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                if (onRevert != null)
                  TextButton(
                    key: Key('revert-${entry.id}'),
                    onPressed: onRevert,
                    child: const Text('撤销'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
