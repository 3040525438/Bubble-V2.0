// 记忆收件箱（T5.4 / UI_PAGE_SPEC §D14）：候选接受 / 编辑后接受 / 拒绝。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/memory_repository.dart';
import '../../domain/memory/memory_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class MemoryInboxPage extends StatefulWidget {
  const MemoryInboxPage({super.key, this.repository});

  final MemoryRepository? repository;

  @override
  State<MemoryInboxPage> createState() => _MemoryInboxPageState();
}

class _MemoryInboxPageState extends State<MemoryInboxPage> {
  late final MemoryRepository _repo =
      widget.repository ?? MemoryRepository(AppDb.instance);

  List<MemoryCandidate> _candidates = const <MemoryCandidate>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _repo.listCandidates();
    if (!mounted) return;
    setState(() {
      _candidates = rows;
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
        duration: const Duration(milliseconds: 2000),
      ));
  }

  Future<void> _accept(MemoryCandidate candidate, {bool edit = false}) async {
    String? title;
    String? summary;
    if (edit) {
      final titleController =
          TextEditingController(text: candidate.proposedTitle ?? '');
      final summaryController =
          TextEditingController(text: candidate.proposedSummary);
      final saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('编辑后接受'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: summaryController,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '记忆内容'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      title = titleController.text.trim();
      summary = summaryController.text.trim();
      titleController.dispose();
      summaryController.dispose();
      if (saved != true) return;
    }
    try {
      await _repo.acceptCandidate(
        candidate.id,
        editedTitle: title,
        editedSummary: summary,
      );
      _toast('已收下这条记忆');
      await _load();
    } catch (error) {
      _toast('操作失败：$error');
    }
  }

  Future<void> _reject(MemoryCandidate candidate) async {
    await _repo.rejectCandidate(candidate.id);
    _toast('已拒绝');
    await _load();
  }

  Future<void> _acceptAll() async {
    final count = await _repo.acceptAllCandidates();
    _toast('已收下 $count 条记忆');
    await _load();
  }

  Future<void> _rejectAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('全部拒绝'),
        content: Text('${_candidates.length} 条候选都会被标记为拒绝并留痕。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
                foregroundColor: context.bubbleColors.dangerDeep),
            child: const Text('全部拒绝'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final count = await _repo.rejectAllCandidates();
    _toast('已拒绝 $count 条');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记忆收件箱')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
              children: [
                if (_candidates.isEmpty)
                  MemoryEmptyCard(
                    title: '没有待确认的记忆',
                    subtitle: '未经你确认的候选不会进入常驻记忆。',
                  )
                else ...[
                  Text(
                    '${_candidates.length} 条候选等你确认',
                    style: TextStyle(
                      fontSize: BubbleFontSize.cardTitle,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final candidate in _candidates) ...[
                    _candidateCard(candidate),
                    const SizedBox(height: 9),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _rejectAll,
                          child: const Text('全部拒绝'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: _acceptAll,
                          child: const Text('全部接受'),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                const MemoryLockBar('泡泡只提候选 · 写入记忆必须经过你或高置信策略'),
              ],
            ),
    );
  }

  Widget _candidateCard(MemoryCandidate candidate) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final typeColor = memoryTypeColor(context, candidate.proposedType);
    final flags = _decodeFlags(candidate.scanFlags);
    final sensitive = (flags['sensitive'] as List?)?.isNotEmpty == true;
    final secretNote = flags['secret'] as String?;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
      decoration: BoxDecoration(
        color: semantic.lavender.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.lavender.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  candidate.proposedTitle ?? candidate.proposedSummary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    fontWeight: FontWeight.w600,
                    color: onSurface,
                  ),
                ),
              ),
              MemoryBadge(
                text: MemoryType.labelOf(candidate.proposedType),
                color: typeColor,
                background: typeColor.withValues(alpha: 0.15),
              ),
              const SizedBox(width: 5),
              MemoryBadge(
                text: '置信${MemoryConfidence.fromWire(candidate.confidence).label}',
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.15),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            candidate.proposedSummary,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              height: 1.55,
            ),
          ),
          if ((candidate.groundingNote ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '证据：“${candidate.groundingNote}”',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Wrap(
            spacing: 5,
            runSpacing: 4,
            children: [
              if (sensitive)
                MemoryBadge(
                  text: '敏感内容 · 需确认',
                  color: semantic.warnDeep,
                  background: semantic.warn.withValues(alpha: 0.16),
                ),
              if ((secretNote ?? '').isNotEmpty)
                MemoryBadge(
                  text: '已扫描机密',
                  color: semantic.dangerDeep,
                  background: semantic.danger.withValues(alpha: 0.13),
                ),
              MemoryBadge(
                text: _compareLabel(candidate.compareResult),
                color: semantic.lavenderDeep,
                background: semantic.surfaceAlt,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _reject(candidate),
                style: TextButton.styleFrom(
                    foregroundColor: semantic.dangerDeep),
                child: const Text('拒绝'),
              ),
              TextButton(
                onPressed: () => _accept(candidate, edit: true),
                child: const Text('编辑后接受'),
              ),
              FilledButton(
                onPressed: () => _accept(candidate),
                child: const Text('接受'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Map<String, dynamic> _decodeFlags(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static String _compareLabel(String? wire) {
    final kind = CompareKind.fromWire(wire);
    if (kind == CompareKind.create) return '新记忆';
    return kind.label;
  }
}
