// 全局搜索页（T14.6）：六域分区检索 + 命中词高亮 + 锚点跳转。
// 依据 UI_PAGE_SPEC §20、REQUIREMENTS FR-MISC-03。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/search/global_search_repository.dart';
import '../../domain/search/search_models.dart';
import '../../domain/search/tokenizer.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class GlobalSearchPage extends StatefulWidget {
  const GlobalSearchPage({super.key, this.repository});

  final GlobalSearchRepository? repository;

  @override
  State<GlobalSearchPage> createState() => _GlobalSearchPageState();
}

class _GlobalSearchPageState extends State<GlobalSearchPage> {
  late final GlobalSearchRepository _repo =
      widget.repository ?? GlobalSearchRepository(AppDb.instance);
  final TextEditingController _controller = TextEditingController();

  GlobalSearchResult? _result;
  bool _searching = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() => _result = null);
      return;
    }
    setState(() => _searching = true);
    final result = await _repo.search(query);
    if (!mounted) return;
    setState(() {
      _result = result;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('全局搜索')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: semantic.surfaceAlt,
                  borderRadius: BorderRadius.circular(BubbleRadius.inputBar),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      size: 20,
                      color: semantic.lavenderDeep,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const Key('global-search-field'),
                        controller: _controller,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration: const InputDecoration(
                          hintText: '搜索聊天 / 记忆 / 说说 / 日记·信件·经历',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    if (result != null && result.total > 0)
                      MemoryBadge(
                        text: '${result.total} 条',
                        color: semantic.lavenderDeep,
                        background: semantic.lavender.withValues(alpha: 0.18),
                      ),
                    IconButton(
                      key: const Key('global-search-submit'),
                      onPressed: _search,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                    ),
                  ],
                ),
              ),
            ),
            if (_searching)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Expanded(child: _buildBody(result)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(GlobalSearchResult? result) {
    if (result == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: MemoryEmptyCard(
          title: '输入关键词开始搜索',
          subtitle: '搜索覆盖聊天、记忆、说说、日记、信件、经历与图片 OCR',
        ),
      );
    }
    if (result.total == 0) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: MemoryEmptyCard(
          title: '没有找到匹配内容',
          subtitle: '试试更短的关键词，或检查是否已导入数据',
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (result.indexWasEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: MemoryLockBar('索引为空，已完成一次全量重建'),
          ),
        for (final section in result.sections)
          _SectionCard(section: section, query: result.query),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section, required this.query});

  final SearchSectionResult section;
  final String query;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final terms = tokenize(query).where((t) => t.trim().isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
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
                Text(
                  section.section.label,
                  style: const TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                MemoryBadge(
                  text: '${section.count}',
                  color: semantic.lavenderDeep,
                  background: semantic.lavender.withValues(alpha: 0.18),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final hit in section.hits) _HitRow(hit: hit, terms: terms),
          ],
        ),
      ),
    );
  }
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.terms});

  final SearchHit hit;
  final List<String> terms;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final spans = highlightSpans(hit.snippet, terms);
    return InkWell(
      key: Key('search-hit-${hit.domain.wire}-${hit.docId}'),
      onTap: hit.anchorPath.isEmpty ? null : () => context.push(hit.anchorPath),
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 6,
              height: 6,
              margin: const EdgeInsets.only(top: 7, right: 8),
              decoration: BoxDecoration(
                color: semantic.lavender,
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hit.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: BubbleFontSize.bodySmall,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  RichText(
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        height: 1.5,
                        color: onSurface.withValues(alpha: 0.62),
                      ),
                      children: [
                        for (final span in spans)
                          TextSpan(
                            text: span.text,
                            style: span.hit
                                ? TextStyle(
                                    color: semantic.bubbleUserA,
                                    fontWeight: FontWeight.w700,
                                  )
                                : null,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (hit.anchorPath.isNotEmpty)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: onSurface.withValues(alpha: 0.35),
              ),
          ],
        ),
      ),
    );
  }
}
