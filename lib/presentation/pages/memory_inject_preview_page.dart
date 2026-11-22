// 记忆注入预览（T5.4 / UI_PAGE_SPEC §D_星空卡）：常驻块与召回块实际渲染结果。
import 'package:flutter/material.dart';

import '../../data/database/db_provider.dart';
import '../../data/repositories/memory_repository.dart';
import '../../domain/memory/memory_context.dart';
import '../../domain/memory/memory_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class MemoryInjectPreviewPage extends StatefulWidget {
  const MemoryInjectPreviewPage({super.key, this.repository});

  final MemoryRepository? repository;

  @override
  State<MemoryInjectPreviewPage> createState() =>
      _MemoryInjectPreviewPageState();
}

class _MemoryInjectPreviewPageState extends State<MemoryInjectPreviewPage> {
  late final MemoryRepository _repo =
      widget.repository ?? MemoryRepository(AppDb.instance);
  final TextEditingController _queryController = TextEditingController();

  MemoryBlock _standing = MemoryBlock.empty;
  MemoryBlock _recall = MemoryBlock.empty;
  bool _loading = true;
  bool _recalling = false;

  @override
  void initState() {
    super.initState();
    _loadStanding();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _loadStanding() async {
    final standing = await _repo.standingBlock();
    if (!mounted) return;
    setState(() {
      _standing = standing;
      _loading = false;
    });
  }

  Future<void> _previewRecall() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() => _recalling = true);
    final recall = await _repo.recallBlock(query);
    if (!mounted) return;
    setState(() {
      _recall = recall;
      _recalling = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('注入预览')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
              children: [
                _starCard(
                  title: '泡泡此刻会带上这些 ✦',
                  subtitle: '常驻记忆 · 每条都标注类型、日期与置信度',
                  block: _standing,
                  budget: MemoryContextRenderer.defaultStandingBudget,
                ),
                const SizedBox(height: 12),
                Text(
                  '按需召回',
                  style: TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queryController,
                        decoration: const InputDecoration(
                          hintText: '输入一句你想问的话',
                        ),
                        onSubmitted: (_) => _previewRecall(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _recalling ? null : _previewRecall,
                      child: Text(_recalling ? '检索中' : '预览'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_recall.isEmpty)
                  const MemoryEmptyCard(
                    title: '这次没有可注入的召回记忆',
                    subtitle: '没有命中足够强的关键词，或相关记忆置信度过低。',
                  )
                else
                  _blockCard(_recall,
                      budget: MemoryContextRenderer.defaultRecallBudget),
                const SizedBox(height: 12),
                _whyCard(),
              ],
            ),
    );
  }

  Widget _starCard({
    required String title,
    required String subtitle,
    required MemoryBlock block,
    required int budget,
  }) {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            semantic.lavender.withValues(alpha: 0.30),
            semantic.bubbleUserB.withValues(alpha: 0.22),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: BubbleFontSize.cardTitle,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 10),
          if (block.isEmpty)
            const Text('还没有常驻记忆。置顶或高置信的记忆会出现在这里。',
                style: TextStyle(fontSize: BubbleFontSize.secondary))
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(BubbleRadius.badge),
              ),
              child: Text(
                block.text,
                style: const TextStyle(
                  fontSize: BubbleFontSize.badge,
                  height: 1.7,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            '${block.itemIds.length} 条 · 约 ${block.tokens}/$budget token',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _blockCard(MemoryBlock block, {required int budget}) {
    final semantic = context.bubbleColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            block.text,
            style:
                const TextStyle(fontSize: BubbleFontSize.badge, height: 1.7),
          ),
          const SizedBox(height: 8),
          Text(
            '${block.itemIds.length} 条 · 约 ${block.tokens}/$budget token',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _whyCard() {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('为什么是这几条',
              style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
            '· 常驻优先：置顶与约定/资料/偏好等稳定记忆优先进入常驻块\n'
            '· 话题相关：召回只取命中 ≥2 字关键词的记忆，单字命中不注入\n'
            '· 冲突不注入：待裁决记忆不会冒充现行事实\n'
            '· 实时变化：记忆一经修改，下一次注入就会换掉旧版本',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.75,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}
