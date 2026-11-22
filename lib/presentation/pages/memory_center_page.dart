// 记忆总览（T5.4 / UI_PAGE_SPEC §D12）：计数徽章、搜索、类型筛选与记忆卡。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/memory_repository.dart';
import '../../domain/memory/memory_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class MemoryCenterPage extends StatefulWidget {
  const MemoryCenterPage({super.key, this.repository});

  /// 测试注入用；为空时使用全局数据库
  final MemoryRepository? repository;

  @override
  State<MemoryCenterPage> createState() => _MemoryCenterPageState();
}

class _MemoryCenterPageState extends State<MemoryCenterPage> {
  late final MemoryRepository _repo =
      widget.repository ?? MemoryRepository(AppDb.instance);
  final TextEditingController _searchController = TextEditingController();

  MemoryCounts _counts = const MemoryCounts(
      inbox: 0, conflicts: 0, resident: 0, active: 0, total: 0);
  List<Memory> _memories = const <Memory>[];
  String? _type;
  String _query = '';
  bool _loading = true;
  Object? _error;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = ++_loadToken;
    try {
      final counts = await _repo.counts();
      final memories = await _repo.listMemories(
        type: _type,
        query: _query.isEmpty ? null : _query,
      );
      if (!mounted || token != _loadToken) return;
      setState(() {
        _counts = counts;
        _memories = memories;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _openMemory(Memory memory) async {
    final path = memory.status == MemoryStatus.conflict.wire
        ? '/memory/conflict/${memory.id}'
        : '/memory/detail/${memory.id}';
    await context.push(path);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆中心'),
        actions: [
          IconButton(
            tooltip: '注入预览',
            onPressed: () async {
              await context.push('/memory/inject');
              if (mounted) await _load();
            },
            icon: const Icon(Icons.visibility_outlined),
          ),
          _InboxAction(
            count: _counts.inbox,
            onTap: () async {
              await context.push('/memory/inbox');
              if (mounted) await _load();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _error != null
          ? Center(child: Text('加载失败：$_error'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
                children: [
                  _countsRow(),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '搜索泡泡记得的事',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                                _load();
                              },
                            ),
                    ),
                    onChanged: (value) {
                      setState(() => _query = value.trim());
                      _load();
                    },
                  ),
                  const SizedBox(height: 10),
                  MemoryTypeFilter(
                    selected: _type,
                    onSelected: (type) {
                      setState(() => _type = type);
                      _load();
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_memories.isEmpty)
                    MemoryEmptyCard(
                      title: _query.isEmpty ? '还没有记住什么' : '没有找到相关记忆',
                      subtitle: _query.isEmpty
                          ? '聊一会儿，泡泡会把值得记住的事提给你确认。'
                          : '换个关键词，或清除类型筛选再试。',
                    )
                  else
                    for (final memory in _memories) ...[
                      _memoryCard(memory),
                      const SizedBox(height: 9),
                    ],
                  const SizedBox(height: 8),
                  const MemoryLockBar('待确认候选不会进入常驻记忆 · 冲突记忆不参与注入'),
                ],
              ),
            ),
    );
  }

  Widget _countsRow() {
    return Row(
      children: [
        Expanded(
          child: _countCard(
            label: '收件箱',
            value: _counts.inbox,
            color: context.bubbleColors.lavenderDeep,
            onTap: () async {
              await context.push('/memory/inbox');
              if (mounted) await _load();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _countCard(
            label: '待裁决',
            value: _counts.conflicts,
            color: context.bubbleColors.warnDeep,
            onTap: null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _countCard(
            label: '常驻',
            value: _counts.resident,
            color: context.bubbleColors.successDeep,
            onTap: null,
          ),
        ),
      ],
    );
  }

  Widget _countCard({
    required String label,
    required int value,
    required Color color,
    required VoidCallback? onTap,
  }) {
    final semantic = context.bubbleColors;
    return Material(
      color: semantic.surfaceAlt.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.55),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _memoryCard(Memory memory) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final conflict = memory.status == MemoryStatus.conflict.wire;
    final pinned = memory.pinned == 1;
    final typeColor = memoryTypeColor(context, memory.type);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: () => _openMemory(memory),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BubbleRadius.card),
            border: Border.all(
              color: conflict
                  ? semantic.warn
                  : semantic.stroke.withValues(alpha: 0.8),
              width: conflict ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: typeColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${pinned ? '★ ' : ''}${memory.title ?? memory.summary}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: BubbleFontSize.cardTitle,
                        fontWeight: FontWeight.w600,
                        color: onSurface,
                      ),
                    ),
                  ),
                  if (conflict)
                    MemoryBadge(
                      text: '待裁决',
                      color: semantic.warnDeep,
                      background: semantic.warn.withValues(alpha: 0.18),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                memory.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: BubbleFontSize.secondary,
                  color: onSurface.withValues(alpha: 0.62),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  MemoryBadge(
                    text: MemoryType.labelOf(memory.type),
                    color: typeColor,
                    background: typeColor.withValues(alpha: 0.14),
                  ),
                  const SizedBox(width: 6),
                  MemoryBadge(
                    text: '置信${MemoryConfidence.fromWire(memory.confidence).label}',
                    color: semantic.lavenderDeep,
                    background: semantic.lavender.withValues(alpha: 0.13),
                  ),
                  if (memory.isResident == 1 || pinned) ...[
                    const SizedBox(width: 6),
                    MemoryBadge(
                      text: '常驻',
                      color: semantic.successDeep,
                      background: semantic.success.withValues(alpha: 0.14),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    formatMemoryDate(memory.updatedAt),
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InboxAction extends StatelessWidget {
  const _InboxAction({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        IconButton(
          tooltip: '记忆收件箱',
          onPressed: onTap,
          icon: const Icon(Icons.inbox_outlined),
        ),
        if (count > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: context.bubbleColors.pinkDeep,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
