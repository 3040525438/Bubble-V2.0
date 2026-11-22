// 记忆详情（T5.4 / UI_PAGE_SPEC §D13）：正文、来源证据、关联记忆与版本历史。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/memory_repository.dart';
import '../../domain/memory/memory_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class MemoryDetailPage extends StatefulWidget {
  const MemoryDetailPage({
    super.key,
    required this.memoryId,
    this.repository,
  });

  final String memoryId;
  final MemoryRepository? repository;

  @override
  State<MemoryDetailPage> createState() => _MemoryDetailPageState();
}

class _MemoryDetailPageState extends State<MemoryDetailPage> {
  late final MemoryRepository _repo =
      widget.repository ?? MemoryRepository(AppDb.instance);

  Memory? _memory;
  List<MemoryVersion> _versions = const <MemoryVersion>[];
  List<MemoryRelationEntry> _relations = const <MemoryRelationEntry>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final memory = await _repo.getMemory(widget.memoryId);
    final versions = await _repo.versionsOf(widget.memoryId);
    final relations = await _repo.relationsOf(widget.memoryId);
    if (!mounted) return;
    setState(() {
      _memory = memory;
      _versions = versions;
      _relations = relations;
      _loading = false;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 2200),
      ));
  }

  Future<void> _togglePin() async {
    final memory = _memory;
    if (memory == null) return;
    await _repo.setPinned(memory.id, memory.pinned != 1);
    _toast(memory.pinned == 1 ? '已取消置顶' : '已置顶，优先进入常驻记忆');
    await _load();
  }

  Future<void> _toggleResident() async {
    final memory = _memory;
    if (memory == null) return;
    final next = memory.isResident != 1;
    await _repo.setResident(memory.id, next);
    _toast(next ? '已设为常驻记忆' : '已取消常驻');
    await _load();
  }

  Future<void> _archive() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('归档这条记忆'),
        content: const Text('归档只做标记，不会真正删除；之后可在数据中心清理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
                foregroundColor: context.bubbleColors.dangerDeep),
            child: const Text('归档'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.archiveMemory(widget.memoryId);
    _toast('已归档');
    await _load();
  }

  Future<void> _restore(MemoryVersion version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('恢复到 v${version.versionNo}'),
        content: const Text('恢复会基于该版本内容生成新版本，历史版本仍可回看。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.restoreVersion(widget.memoryId, version.id);
    _toast('已生成新版本');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final memory = _memory;
    return Scaffold(
      appBar: AppBar(
        title: const Text('记忆详情'),
        actions: [
          if (memory != null)
            IconButton(
              tooltip: memory.pinned == 1 ? '取消置顶' : '置顶',
              onPressed: _togglePin,
              icon: Icon(memory.pinned == 1
                  ? Icons.push_pin_rounded
                  : Icons.push_pin_outlined),
            ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'resident') _toggleResident();
              if (value == 'archive') _archive();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'resident',
                child: Text(memory?.isResident == 1 ? '取消常驻' : '设为常驻'),
              ),
              const PopupMenuItem(value: 'archive', child: Text('归档（不真删）')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : memory == null
              ? const Center(child: Text('这条记忆不存在或已被清理'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
                  children: [
                    if (memory.status == MemoryStatus.conflict.wire) ...[
                      _conflictBanner(memory),
                      const SizedBox(height: 10),
                    ],
                    _bodyCard(memory),
                    const SizedBox(height: 10),
                    if ((memory.evidence ?? '').trim().isNotEmpty) ...[
                      _sectionTitle('来源证据'),
                      const SizedBox(height: 6),
                      _evidenceCard(memory),
                      const SizedBox(height: 10),
                    ],
                    if (_relations.isNotEmpty) ...[
                      _sectionTitle('关联记忆'),
                      const SizedBox(height: 6),
                      _relationsCard(),
                      const SizedBox(height: 10),
                    ],
                    _sectionTitle('版本历史'),
                    const SizedBox(height: 6),
                    for (var i = 0; i < _versions.length; i++)
                      _versionRow(_versions[i], isLatest: i == 0),
                    const SizedBox(height: 8),
                    const MemoryLockBar('所有修改留痕 · 恢复是新增版本而非覆盖'),
                  ],
                ),
    );
  }

  Widget _conflictBanner(Memory memory) {
    final semantic = context.bubbleColors;
    return Material(
      color: semantic.warn.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: () async {
          await context.push('/memory/conflict/${memory.id}');
          if (mounted) await _load();
        },
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(BubbleRadius.card),
            border: Border.all(color: semantic.warn),
          ),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 20, color: semantic.warnDeep),
              const SizedBox(width: 9),
              const Expanded(
                child: Text('这条记忆存在两个版本，等待你裁决',
                    style: TextStyle(fontSize: BubbleFontSize.bodySmall)),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bodyCard(Memory memory) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final typeColor = memoryTypeColor(context, memory.type);
    final sensitive = memory.sensitivity != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
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
              Expanded(
                child: Text(
                  '${memory.pinned == 1 ? '★ ' : ''}${memory.title ?? memory.summary}',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: onSurface,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              MemoryBadge(
                text: MemoryType.labelOf(memory.type),
                color: typeColor,
                background: typeColor.withValues(alpha: 0.14),
              ),
              MemoryBadge(
                text: '置信${MemoryConfidence.fromWire(memory.confidence).label}',
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.13),
              ),
              MemoryBadge(
                text: MemoryStatus.fromWire(memory.status).label,
                color: semantic.successDeep,
                background: semantic.success.withValues(alpha: 0.13),
              ),
              if (memory.isResident == 1 || memory.pinned == 1)
                MemoryBadge(
                  text: '常驻',
                  color: semantic.pinkDeep,
                  background: semantic.pink.withValues(alpha: 0.14),
                ),
              if (sensitive)
                MemoryBadge(
                  text: '敏感信息',
                  color: semantic.warnDeep,
                  background: semantic.warn.withValues(alpha: 0.14),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            memory.summary,
            style: const TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              height: 1.7,
            ),
          ),
          if ((memory.body ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              memory.body!,
              style: TextStyle(
                fontSize: BubbleFontSize.secondary,
                height: 1.6,
                color: onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '创建于 ${formatMemoryDateTime(memory.createdAt)} · 更新于 ${formatMemoryDateTime(memory.updatedAt)}',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _evidenceCard(Memory memory) {
    final semantic = context.bubbleColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Text(
        '“${memory.evidence}”',
        style: const TextStyle(
          fontSize: BubbleFontSize.secondary,
          height: 1.6,
        ),
      ),
    );
  }

  Widget _relationsCard() {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Column(
        children: [
          for (final entry in _relations)
            InkWell(
              onTap: () => context.push('/memory/detail/${entry.other.id}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: memoryTypeColor(context, entry.other.type),
                      ),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '${_relationLabel(entry.relation.relationType)} · '
                        '${entry.other.title ?? entry.other.summary}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: BubbleFontSize.secondary),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 16, color: onSurface.withValues(alpha: 0.3)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _versionRow(MemoryVersion version, {required bool isLatest}) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 10),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isLatest ? semantic.success : semantic.lavender,
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(BubbleRadius.card),
                border: Border.all(color: semantic.stroke),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('v${version.versionNo}',
                                style: const TextStyle(
                                  fontSize: BubbleFontSize.bodySmall,
                                  fontWeight: FontWeight.w700,
                                )),
                            const SizedBox(width: 7),
                            MemoryBadge(
                              text: _changeLabel(version.changeKind),
                              color: semantic.lavenderDeep,
                              background:
                                  semantic.lavender.withValues(alpha: 0.13),
                            ),
                            if (isLatest) ...[
                              const SizedBox(width: 5),
                              MemoryBadge(
                                text: '当前',
                                color: semantic.successDeep,
                                background:
                                    semantic.success.withValues(alpha: 0.13),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          version.reason ?? '（无说明）',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: BubbleFontSize.badge,
                            color: onSurface.withValues(alpha: 0.6),
                          ),
                        ),
                        Text(
                          formatMemoryDateTime(version.createdAt),
                          style: TextStyle(
                            fontSize: BubbleFontSize.badge,
                            color: onSurface.withValues(alpha: 0.38),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!isLatest)
                    TextButton(
                      onPressed: () => _restore(version),
                      child: const Text('恢复'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(
        text,
        style: TextStyle(
          fontSize: BubbleFontSize.cardTitle,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      );

  static String _relationLabel(String type) => switch (type) {
        'supports' => '支持',
        'contradicts' => '矛盾',
        'caused_by' => '源于',
        _ => '相关',
      };

  static String _changeLabel(String kind) => switch (kind) {
        'create' => '创建',
        'merge' => '合并',
        'status' => '状态',
        'supersede' => '替代',
        _ => '更新',
      };
}
