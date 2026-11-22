// 信件列表（T11.2）：全部/来自泡泡/我写的/草稿、状态徽章与「让泡泡写一封」。
// 依据 UI_PAGE_SPEC §18、REQUIREMENTS FR-LET-01。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/letter/letter_generator.dart';
import '../../data/repositories/letter_repository.dart';
import '../../domain/letter/letter_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class LettersPage extends StatefulWidget {
  const LettersPage({super.key, this.repository, this.generator});

  final LetterRepository? repository;
  final LetterGenerator? generator;

  @override
  State<LettersPage> createState() => _LettersPageState();
}

class _LettersPageState extends State<LettersPage> {
  late final LetterRepository _repo =
      widget.repository ?? LetterRepository(AppDb.instance);
  late final LetterGenerator _generator =
      widget.generator ?? LetterGenerator(AppDb.instance, repository: _repo);

  LetterFilter _filter = LetterFilter.all;
  List<Letter> _rows = const <Letter>[];
  bool _loading = true;
  bool _writing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final rows = await _repo.listLetters(filter: _filter);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _askBubbleWrite() async {
    if (_writing) return;
    setState(() => _writing = true);
    try {
      final draft = await _generator.generate();
      final saved = await _generator.saveAsDraft(draft);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              draft.fromModel
                  ? '泡泡写好了一封信，已放进草稿，读过后可以寄出'
                  : '本地草稿已放进信件，读过后可以修改或寄出',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      await context.push('/letters/${saved.id}');
      await _reload();
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('写信失败：$error')));
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text('信件'),
        actions: [
          TextButton.icon(
            key: const ValueKey('letter-compose'),
            onPressed: () async {
              final created = await context.push<bool>('/letters/write');
              if (created == true) await _reload();
            },
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('写一封信'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final filter in LetterFilter.values)
                  _filterChip(context, onSurface, filter),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _filter == LetterFilter.drafts
                        ? '草稿只有你能看到，寄出后才会出现在「已寄出」里。'
                        : '信只保存在本地；泡泡主动写信至少间隔 7 天。',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: onSurface.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('letter-ask-bubble'),
                  onPressed: _writing ? null : _askBubbleWrite,
                  icon: _writing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_rounded, size: 16),
                  label: const Text('让泡泡写'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_rows.isEmpty)
              MemoryEmptyCard(
                title: _filter == LetterFilter.all ? '还没有信' : '这里还没有信',
                subtitle: _filter == LetterFilter.all
                    ? '你可以给泡泡写一封信，也可以让她在想起什么的时候给你写信。'
                    : '切换上面的筛选，看看其他信件。',
              )
            else
              for (final row in _rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _LetterCard(
                    letter: row,
                    onTap: () async {
                      await context.push('/letters/${row.id}');
                      await _reload();
                    },
                  ),
                ),
            const SizedBox(height: 8),
            Text(
              '删除的信会保留 30 天，之后可在数据中心恢复或清理。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(
    BuildContext context,
    Color onSurface,
    LetterFilter filter,
  ) {
    final semantic = context.bubbleColors;
    final selected = _filter == filter;
    return InkWell(
      key: ValueKey('letter-filter-${filter.name}'),
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: () {
        setState(() => _filter = filter);
        _reload();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? semantic.pink.withValues(alpha: 0.32)
              : semantic.surfaceAlt.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
          border: Border.all(
            color: selected ? semantic.pinkDeep : Colors.transparent,
          ),
        ),
        child: Text(
          filter.label,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? semantic.pinkDeep : onSurface,
          ),
        ),
      ),
    );
  }
}

class _LetterCard extends StatelessWidget {
  const _LetterCard({required this.letter, required this.onTap});

  final Letter letter;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final direction = LetterDirection.fromWire(letter.direction);
    final state = LetterState.fromWire(letter.state);
    final title = (letter.title ?? '').trim().isEmpty
        ? LetterRules.deriveTitle(letter.content)
        : letter.title!.trim();
    final summary = letter.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    final card = Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(context),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: BubbleFontSize.cardTitle,
                              fontWeight: FontWeight.w700,
                              color: onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        MemoryBadge(
                          text: state.label,
                          color: state.isDraft
                              ? semantic.warnDeep
                              : semantic.successDeep,
                          background:
                              (state.isDraft ? semantic.warn : semantic.success)
                                  .withValues(alpha: 0.16),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${direction.routeLabel} · $summary',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        height: 1.5,
                        color: onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return state.isDraft ? Opacity(opacity: 0.75, child: card) : card;
  }

  Widget _avatar(BuildContext context) {
    final semantic = context.bubbleColors;
    final fromBubble = LetterDirection.fromWire(letter.direction).isFromBubble;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: fromBubble
              ? [semantic.lavender, semantic.bubbleUserA]
              : [semantic.pink, semantic.pinkDeep],
        ),
      ),
      child: Icon(
        fromBubble ? Icons.cloud_rounded : Icons.person_rounded,
        size: 21,
        color: Colors.white,
      ),
    );
  }
}
