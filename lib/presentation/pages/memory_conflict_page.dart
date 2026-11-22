// 记忆冲突裁决（T5.4 / UI_PAGE_SPEC §D15）：双栏证据 + 保留 A/B/用户重写。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/memory_repository.dart';
import '../../domain/memory/memory_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class MemoryConflictPage extends StatefulWidget {
  const MemoryConflictPage({
    super.key,
    required this.memoryId,
    this.repository,
  });

  final String memoryId;
  final MemoryRepository? repository;

  @override
  State<MemoryConflictPage> createState() => _MemoryConflictPageState();
}

class _MemoryConflictPageState extends State<MemoryConflictPage> {
  late final MemoryRepository _repo =
      widget.repository ?? MemoryRepository(AppDb.instance);

  Memory? _a;
  Memory? _b;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = await _repo.getMemory(widget.memoryId);
    Memory? b;
    if (a != null && a.conflictsWith != null) {
      final ids = _decodeIds(a.conflictsWith);
      if (ids.isNotEmpty) b = await _repo.getMemory(ids.first);
    }
    if (!mounted) return;
    setState(() {
      _a = a;
      _b = b;
      _loading = false;
    });
  }

  Future<void> _keep(String side) async {
    try {
      await _repo.resolveConflict(widget.memoryId, keep: side);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('已裁决，落选版本转入历史'),
          behavior: SnackBarBehavior.floating,
        ));
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('裁决失败：$error')));
    }
  }

  Future<void> _manual() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('两个都不对，我来写'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(hintText: '写下正确的版本'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存并裁决'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    try {
      await _repo.resolveConflict(
        widget.memoryId,
        keep: 'manual',
        manualText: text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('裁决失败：$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final a = _a;
    final b = _b;
    return Scaffold(
      appBar: AppBar(title: const Text('冲突裁决')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (a == null || b == null)
              ? ListView(
                  padding: const EdgeInsets.all(16),
                  children: const [
                    MemoryEmptyCard(
                      title: '冲突已解决或对端记忆不存在',
                      subtitle: '落选版本会转入历史，可回看但不参与注入。',
                    ),
                  ],
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: semantic.warn.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(BubbleRadius.card),
                        border: Border.all(color: semantic.warn),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              size: 20, color: semantic.warnDeep),
                          const SizedBox(width: 9),
                          const Expanded(
                            child: Text('这条记忆存在两个版本',
                                style: TextStyle(
                                    fontSize: BubbleFontSize.bodySmall,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _sideCard('版本 A', a)),
                        const SizedBox(width: 8),
                        Expanded(child: _sideCard('版本 B', b)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _keep('a'),
                            child: const Text('保留 A'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _keep('b'),
                            child: const Text('保留 B'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: _manual,
                        style: TextButton.styleFrom(
                          foregroundColor: semantic.dangerDeep,
                          backgroundColor:
                              semantic.danger.withValues(alpha: 0.09),
                        ),
                        child: const Text('两个都不对，我来写'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const MemoryLockBar('落选版本转入历史（可回看不参与注入），操作留痕'),
                  ],
                ),
    );
  }

  Widget _sideCard(String label, Memory memory) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final typeColor = memoryTypeColor(context, memory.type);
    return Container(
      padding: const EdgeInsets.all(12),
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
              Text(label,
                  style: const TextStyle(
                      fontSize: BubbleFontSize.badge,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              MemoryBadge(
                text: '置信${MemoryConfidence.fromWire(memory.confidence).label}',
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            memory.summary,
            style: const TextStyle(
                fontSize: BubbleFontSize.secondary, height: 1.55),
          ),
          if ((memory.evidence ?? '').isNotEmpty) ...[
            const SizedBox(height: 7),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: semantic.surfaceAlt.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(BubbleRadius.badge),
              ),
              child: Text(
                '“${memory.evidence}”',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.65),
                  height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 7),
          Row(
            children: [
              Container(
                width: 7,
                height: 7,
                decoration:
                    BoxDecoration(shape: BoxShape.circle, color: typeColor),
              ),
              const SizedBox(width: 5),
              Text(
                MemoryType.labelOf(memory.type),
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            formatMemoryDate(memory.updatedAt),
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.38),
            ),
          ),
        ],
      ),
    );
  }

  static List<String> _decodeIds(String? raw) {
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const <String>[];
    }
  }
}
