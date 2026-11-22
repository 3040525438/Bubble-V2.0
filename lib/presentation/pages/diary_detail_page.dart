// 日记详情（T11.1）：纸张质感、版本切换、关联胶囊、导出与软删除。
// 依据 UI_PAGE_SPEC §17、REQUIREMENTS FR-DIA-01。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/diary_repository.dart';
import '../../domain/diary/diary_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class DiaryDetailPage extends StatefulWidget {
  const DiaryDetailPage({super.key, required this.diaryId, this.repository});

  final String diaryId;
  final DiaryRepository? repository;

  @override
  State<DiaryDetailPage> createState() => _DiaryDetailPageState();
}

class _DiaryDetailPageState extends State<DiaryDetailPage> {
  late final DiaryRepository _repo =
      widget.repository ?? DiaryRepository(AppDb.instance);

  Diary? _diary;
  List<DiaryVersion> _versions = const <DiaryVersion>[];
  int? _versionIndex;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final diary = await _repo.getDiary(widget.diaryId);
    if (!mounted) return;
    setState(() {
      _diary = diary;
      _versions = DiaryRules.parseVersions(diary?.versions);
      _versionIndex = null;
      _loading = false;
    });
  }

  Future<void> _edit() async {
    final diary = _diary;
    if (diary == null) return;
    final controller = TextEditingController(text: diary.content);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑日记'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                minLines: 8,
                maxLines: 16,
                autofocus: true,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Text(
                '保存后旧内容会保留为一个版本，可以随时切换查看。',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: context.bubbleColors.lavenderDeep,
                ),
              ),
            ],
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
    controller.dispose();
    if (saved == null || saved.isEmpty) return;
    try {
      await _repo.updateDiary(diary.id, content: saved);
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _export() async {
    final diary = _diary;
    if (diary == null) return;
    final markdown = DiaryRules.exportMarkdown([
      DiaryExportEntry(
        dateKey: diary.entryDate,
        content: diary.content,
        origin: DiaryOrigin.fromWire(diary.origin),
      ),
    ], title: '泡泡日记 · ${diary.entryDate}');
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('已导出 Markdown 到剪贴板'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _delete() async {
    final diary = _diary;
    if (diary == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移到回收站？'),
        content: const Text('日记会保留 30 天，期间可以在数据中心恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.softDelete(diary.id);
    if (!mounted) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final diary = _diary;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final semantic = context.bubbleColors;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日记'),
        actions: [
          if (diary != null) ...[
            IconButton(
              tooltip: '导出',
              onPressed: _export,
              icon: const Icon(Icons.ios_share_rounded),
            ),
            IconButton(
              tooltip: '编辑',
              onPressed: _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '删除',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : diary == null
          ? const Center(child: Text('这篇日记不存在或已被删除'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
              children: [
                _paperCard(context, diary, onSurface, semantic),
                if (_versions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _versionCard(context, onSurface),
                ],
                const SizedBox(height: 14),
                _relatedSection(context, onSurface, diary),
              ],
            ),
    );
  }

  Widget _paperCard(
    BuildContext context,
    Diary diary,
    Color onSurface,
    BubbleSemanticColors semantic,
  ) {
    final viewingHistory = _versionIndex != null;
    final content = viewingHistory
        ? _versions[_versionIndex!].content
        : diary.content;
    final origin = viewingHistory
        ? _versions[_versionIndex!].origin
        : DiaryOrigin.fromWire(diary.origin);
    final versionLabel = viewingHistory
        ? 'v${_versionIndex! + 1}'
        : 'v${_versions.length + 1}';
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
        boxShadow: [
          BoxShadow(
            color: semantic.lavender.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  DiaryRules.displayDate(diary.entryDate),
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    fontWeight: FontWeight.w600,
                    color: onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              MemoryBadge(
                text: origin.label,
                color: origin == DiaryOrigin.manual
                    ? semantic.successDeep
                    : semantic.lavenderDeep,
                background:
                    (origin == DiaryOrigin.manual
                            ? semantic.success
                            : semantic.lavender)
                        .withValues(alpha: 0.16),
              ),
              const SizedBox(width: 6),
              MemoryBadge(
                text: versionLabel,
                color: onSurface.withValues(alpha: 0.55),
                background: semantic.surfaceAlt,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Divider(color: semantic.stroke, height: 1),
          const SizedBox(height: 14),
          Text(
            DiaryRules.deriveTitle(content),
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            content,
            style: TextStyle(
              fontSize: BubbleFontSize.body,
              height: 1.8,
              color: onSurface.withValues(alpha: 0.86),
            ),
          ),
          if (viewingHistory) ...[
            const SizedBox(height: 12),
            Text(
              '正在查看旧版本 $versionLabel（只读），切换回「当前版本」可继续编辑。',
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: semantic.warnDeep,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _versionCard(BuildContext context, Color onSurface) {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '版本记录',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  fontWeight: FontWeight.w700,
                  color: semantic.lavenderDeep,
                ),
              ),
              const SizedBox(width: 8),
              MemoryBadge(
                text: '共 ${_versions.length + 1} 个版本',
                color: onSurface.withValues(alpha: 0.55),
                background: Theme.of(context).colorScheme.surface,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '每次编辑都会保留旧内容，点按版本可切换查看。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _versions.length; i++)
                _versionChip(
                  context,
                  label: 'v${i + 1}',
                  selected: _versionIndex == i,
                  onTap: () => setState(() => _versionIndex = i),
                ),
              _versionChip(
                context,
                label: '当前 v${_versions.length + 1}',
                selected: _versionIndex == null,
                onTap: () => setState(() => _versionIndex = null),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _versionChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final semantic = context.bubbleColors;
    return InkWell(
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? semantic.lavender.withValues(alpha: 0.26)
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
          border: Border.all(
            color: selected ? semantic.lavenderDeep : semantic.stroke,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? semantic.lavenderDeep
                : Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }

  Widget _relatedSection(BuildContext context, Color onSurface, Diary diary) {
    final memories = DiaryRules.decodeIds(diary.relatedMemoryIds);
    final messages = DiaryRules.decodeIds(diary.relatedMessageIds);
    if (memories.isEmpty && messages.isEmpty) {
      return const SizedBox.shrink();
    }
    final semantic = context.bubbleColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (memories.isNotEmpty) ...[
          Text(
            '关联记忆',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              fontWeight: FontWeight.w700,
              color: semantic.lavenderDeep,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final id in memories)
                ActionChip(
                  label: Text(id.length > 14 ? '${id.substring(0, 14)}…' : id),
                  onPressed: () => context.push('/memory/detail/$id'),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        if (messages.isNotEmpty)
          MemoryBadge(
            text: '来自 ${messages.length} 条聊天',
            color: onSurface.withValues(alpha: 0.55),
            background: semantic.surfaceAlt,
          ),
      ],
    );
  }
}
