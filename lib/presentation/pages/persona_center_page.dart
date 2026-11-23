// 人格中心（T4.3/T4.4）：四层 seg（核心/成长/表达样本/成长记录）。
// 依据 UI_PAGE_SPEC §C7~§C11、PERSONA_DESIGN §1~§4。
// 核心人格只读展示 + 入口编辑；成长建议接受/编辑后接受/拒绝；样本 pin/软删；版本时间线与恢复。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/persona_repository.dart';
import '../../domain/persona/persona_models.dart';
import '../theme/bubble_colors.dart';

class PersonaCenterPage extends StatefulWidget {
  const PersonaCenterPage({super.key, this.repository});

  /// 测试注入用；为空时使用全局数据库
  final PersonaRepository? repository;

  @override
  State<PersonaCenterPage> createState() => _PersonaCenterPageState();
}

class _PersonaCenterPageState extends State<PersonaCenterPage> {
  late final PersonaRepository _repo =
      widget.repository ?? PersonaRepository(AppDb.instance);

  PersonaSnapshot? _snapshot;
  Object? _error;
  int _tab = 0;

  static const _tabLabels = ['核心', '成长', '表达样本', '成长记录'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await _repo.loadSnapshot();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 2400),
        ),
      );
  }

  Future<void> _openCoreEditor() async {
    await context.push('/persona/edit');
    if (!mounted) return;
    await _load();
  }

  Future<void> _accept(PersonaGrowthRecord record) async {
    try {
      await _repo.acceptGrowth(record.id);
      _toast('已接受「${record.growthType}」的变化');
      await _load();
    } catch (error) {
      _toast('操作失败：$error');
    }
  }

  Future<void> _acceptEdited(PersonaGrowthRecord record) async {
    final controller = TextEditingController(text: record.afterValue ?? '');
    final edited = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('编辑「${record.growthType}」后接受'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(hintText: '改成你更喜欢的表达'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('确认接受'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (edited == null) return;
    try {
      await _repo.acceptGrowth(record.id, editedAfterValue: edited);
      _toast('已按你的版本接受');
      await _load();
    } catch (error) {
      _toast('操作失败：$error');
    }
  }

  Future<void> _reject(PersonaGrowthRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('拒绝这条成长建议'),
        content: Text('「${record.growthType}」的建议会被标记为已拒绝并留痕，不影响当前人格。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: context.bubbleColors.dangerDeep,
            ),
            child: const Text('拒绝'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.rejectGrowth(record.id);
    _toast('已拒绝该建议');
    await _load();
  }

  Future<void> _restore(PersonaVersion version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('恢复 v${version.versionNo}'),
        content: const Text('恢复会生成一个内容相同的新版本，历史版本不会被覆盖。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('恢复此版本'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final created = await _repo.restoreVersion(version.id);
      _toast('已生成 v${created.versionNo}');
      await _load();
    } catch (error) {
      _toast('恢复失败：$error');
    }
  }

  Future<void> _togglePin(ExpressionSample sample) async {
    await _repo.setSamplePinned(sample.id, sample.pinned != 1);
    _toast(sample.pinned == 1 ? '已取消置顶' : '已置顶，会参与风格参照');
    await _load();
  }

  Future<void> _deleteSample(ExpressionSample sample) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除表达样本'),
        content: const Text('删除后不再参与人格组装，痕迹保留在库中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: context.bubbleColors.dangerDeep,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _repo.deleteSample(sample.id);
    _toast('已删除该样本');
    await _load();
  }

  Future<void> _collectFromChat() async {
    final messages = await _repo.recentAssistantMessages(limit: 20);
    if (!mounted) return;
    if (messages.isEmpty) {
      _toast('还没有可以沉淀的泡泡回复');
      return;
    }
    final picked = await showModalBottomSheet<Message>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          itemCount: messages.length,
          separatorBuilder: (_, _) => const Divider(height: 14),
          itemBuilder: (_, index) {
            final message = messages[index];
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                message.content.trim(),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: BubbleFontSize.bodySmall),
              ),
              subtitle: Text(_formatDateTime(message.createdAt)),
              onTap: () => Navigator.pop(sheetContext, message),
            );
          },
        ),
      ),
    );
    if (picked == null) return;
    await _repo.addSample(
      content: picked.content,
      contextNote: '从最近的对话里沉淀',
      pinned: true,
      relatedMessageId: picked.id,
    );
    _toast('已沉淀为新样本');
    await _load();
  }

  Future<void> _addManualSample() async {
    final contentController = TextEditingController();
    final noteController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加表达样本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: contentController,
              maxLines: 4,
              autofocus: true,
              decoration: const InputDecoration(hintText: '泡泡说过的一句代表性的话'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: noteController,
              decoration: const InputDecoration(hintText: '场景说明（可选）'),
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
    final content = contentController.text.trim();
    final note = noteController.text.trim();
    contentController.dispose();
    noteController.dispose();
    if (saved != true) return;
    if (content.isEmpty) {
      _toast('样本内容不能为空');
      return;
    }
    await _repo.addSample(
      content: content,
      contextNote: note.isEmpty ? null : note,
      pinned: true,
    );
    _toast('已添加样本');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(title: const Text('人格中心')),
      body: _error != null
          ? Center(child: Text('加载失败：$_error'))
          : snapshot == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
              children: [
                _layerSeg(),
                const SizedBox(height: 14),
                ..._tabBody(snapshot),
              ],
            ),
    );
  }

  Widget _layerSeg() {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt,
        borderRadius: BorderRadius.circular(BubbleRadius.button),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _tabLabels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _tab = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: _tab == i
                        ? Theme.of(context).colorScheme.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(BubbleRadius.badge),
                  ),
                  child: Text(
                    _tabLabels[i],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      fontWeight: _tab == i ? FontWeight.w700 : FontWeight.w500,
                      color: _tab == i
                          ? onSurface
                          : onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _tabBody(PersonaSnapshot snapshot) {
    switch (_tab) {
      case 1:
        return _growthTab(snapshot);
      case 2:
        return _samplesTab(snapshot);
      case 3:
        return _historyTab(snapshot);
      default:
        return _coreTab(snapshot);
    }
  }

  // ------------------------------------------------------------ 核心层

  List<Widget> _coreTab(PersonaSnapshot snapshot) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              '核心人格 · v${snapshot.coreVersionNo}',
              style: TextStyle(
                fontSize: BubbleFontSize.cardTitle,
                fontWeight: FontWeight.w700,
                color: onSurface,
              ),
            ),
          ),
          _Badge(
            text: '已确认',
            color: semantic.successDeep,
            background: semantic.success.withValues(alpha: 0.16),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(BubbleRadius.card),
          border: Border.all(color: semantic.stroke),
        ),
        child: Column(
          children: [
            for (final key in PersonaCoreFields.fieldKeys)
              _coreFieldRow(
                PersonaCoreFields.fieldLabels[key] ?? key,
                snapshot.core.valueOf(key),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      _lockBar('只有你能修改核心人格 · 泡泡只能提建议'),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              onPressed: _openCoreEditor,
              child: const Text('编辑核心人格'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              onPressed: () => setState(() => _tab = 3),
              child: const Text('版本历史'),
            ),
          ),
        ],
      ),
      if (snapshot.pendingGrowth.isNotEmpty) ...[
        const SizedBox(height: 14),
        _pendingHintCard(snapshot.pendingGrowth),
      ],
    ];
  }

  Widget _coreFieldRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: TextStyle(
              fontSize: BubbleFontSize.secondary,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.55),
            ),
          ),
        ),
        Expanded(
          child: Text(
            value.trim().isEmpty ? '未设置，点「编辑核心人格」补全' : value,
            style: TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              height: 1.55,
              color: value.trim().isEmpty
                  ? Theme.of(context).colorScheme.onSurface
                        .withValues(alpha: 0.38)
                  : null,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _pendingHintCard(List<PersonaGrowthRecord> pending) {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.lavender.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.lavender.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.auto_awesome_rounded,
            size: 20,
            color: semantic.lavenderDeep,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '泡泡提了 ${pending.length} 条成长建议，等你确认',
              style: const TextStyle(fontSize: BubbleFontSize.bodySmall),
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _tab = 1),
            child: const Text('查看'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 成长层

  List<Widget> _growthTab(PersonaSnapshot snapshot) {
    final semantic = context.bubbleColors;
    return [
      const SizedBox(height: 2),
      if (snapshot.pendingGrowth.isEmpty)
        _emptyCard('暂时没有待审的成长建议', '泡泡会在相处中提出称呼、兴趣、口头禅等变化建议。')
      else
        for (final record in snapshot.pendingGrowth) ...[
          _growthCard(record),
          const SizedBox(height: 10),
        ],
      const SizedBox(height: 4),
      _lockBar('成长建议只由泡泡提出 · 每次接受都会生成新版本'),
      if (snapshot.growth.isEmpty) ...[
        const SizedBox(height: 16),
        Text(
          '当前成长层',
          style: TextStyle(
            fontSize: BubbleFontSize.cardTitle,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        _emptyCard('成长层还是空的', '接受建议后，称呼、口头禅等会在这里生效。'),
      ] else ...[
        const SizedBox(height: 16),
        Text(
          '当前生效的成长层',
          style: TextStyle(
            fontSize: BubbleFontSize.cardTitle,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(BubbleRadius.card),
            border: Border.all(color: semantic.stroke),
          ),
          child: Column(
            children: [
              for (final type in PersonaGrowthValues.typeLabels)
                if (snapshot.growth.valueOf(type) != null)
                  _coreFieldRow(type, snapshot.growth.valueOf(type)!),
            ],
          ),
        ),
      ],
      if (snapshot.growthHistory.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          '已处理的建议',
          style: TextStyle(
            fontSize: BubbleFontSize.cardTitle,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        for (final record in snapshot.growthHistory.take(10))
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(
                children: [
                  _Badge(
                    text: record.growthType,
                    color: semantic.lavenderDeep,
                    background: semantic.lavender.withValues(alpha: 0.14),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      record.afterValue ?? record.beforeValue ?? '—',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: BubbleFontSize.secondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    record.status == 'confirmed' ? '已接受' : '已拒绝',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: record.status == 'confirmed'
                          ? semantic.successDeep
                          : Theme.of(context).colorScheme.onSurface
                                .withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ];
  }

  Widget _growthCard(PersonaGrowthRecord record) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.lavender.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.lavender.withValues(alpha: 0.75)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Badge(
                text: record.growthType,
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.18),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '成长建议',
                  style: TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _Badge(
                text: '待确认',
                color: semantic.warnDeep,
                background: semantic.warn.withValues(alpha: 0.16),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _diffColumn(
                  title: '现在',
                  value: record.beforeValue ?? '（暂无）',
                  background: semantic.surfaceAlt,
                  valueColor: onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _diffColumn(
                  title: '建议改为',
                  value: record.afterValue ?? '—',
                  background: semantic.success.withValues(alpha: 0.12),
                  valueColor: semantic.successDeep,
                ),
              ),
            ],
          ),
          if ((record.reason ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '原因：${record.reason}',
              style: TextStyle(
                fontSize: BubbleFontSize.secondary,
                color: onSurface.withValues(alpha: 0.6),
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _reject(record),
                style: TextButton.styleFrom(
                  foregroundColor: semantic.dangerDeep,
                ),
                child: const Text('拒绝'),
              ),
              TextButton(
                onPressed: () => _acceptEdited(record),
                child: const Text('编辑后接受'),
              ),
              FilledButton(
                onPressed: () => _accept(record),
                child: const Text('接受'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diffColumn({
    required String title,
    required String value,
    required Color background,
    required Color valueColor,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: TextStyle(
          fontSize: BubbleFontSize.badge,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
      const SizedBox(height: 4),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
        ),
        child: Text(
          value,
          style: TextStyle(
            fontSize: BubbleFontSize.secondary,
            color: valueColor,
            height: 1.5,
          ),
        ),
      ),
    ],
  );

  // ------------------------------------------------------------ 表达样本

  List<Widget> _samplesTab(PersonaSnapshot snapshot) {
    final semantic = context.bubbleColors;
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              '表达样本 · ${snapshot.samples.length} 条',
              style: TextStyle(
                fontSize: BubbleFontSize.cardTitle,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            '置顶样本参与组装（最多 6 条）',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: semantic.lavenderDeep,
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (snapshot.samples.isEmpty)
        _emptyCard('还没有表达样本', '从对话里挑一句你喜欢的表达，或者手动添加。')
      else
        for (final sample in snapshot.samples) ...[
          _sampleCard(sample),
          const SizedBox(height: 8),
        ],
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _addManualSample,
              child: const Text('手动添加'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton(
              onPressed: _collectFromChat,
              child: const Text('从最近的对话里沉淀'),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _sampleCard(ExpressionSample sample) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final pinned = sample.pinned == 1;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if ((sample.contextNote ?? '').isNotEmpty)
                  _Badge(
                    text: sample.contextNote!,
                    color: semantic.pinkDeep,
                    background: semantic.pink.withValues(alpha: 0.16),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: pinned ? '取消置顶' : '置顶',
                  onPressed: () => _togglePin(sample),
                  icon: Icon(
                    pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    size: 18,
                    color: pinned
                        ? semantic.lavenderDeep
                        : onSurface.withValues(alpha: 0.35),
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () => _deleteSample(sample),
                  icon: Icon(
                    Icons.delete_outline_rounded,
                    size: 18,
                    color: onSurface.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '“${sample.content.trim()}”',
                style: const TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  height: 1.6,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _formatDateTime(sample.createdAt),
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 成长记录与版本

  List<Widget> _historyTab(PersonaSnapshot snapshot) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return [
      Text(
        '版本时间线',
        style: TextStyle(
          fontSize: BubbleFontSize.cardTitle,
          fontWeight: FontWeight.w700,
          color: onSurface,
        ),
      ),
      const SizedBox(height: 10),
      for (final version in snapshot.versions)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 10),
                child: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: version.isActive == 1
                        ? semantic.success
                        : semantic.lavender,
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 10,
                  ),
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
                          Text(
                            'v${version.versionNo}',
                            style: const TextStyle(
                              fontSize: BubbleFontSize.cardTitle,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _Badge(
                            text: _layerLabel(version.layer),
                            color: semantic.lavenderDeep,
                            background: semantic.lavender.withValues(
                              alpha: 0.14,
                            ),
                          ),
                          if (version.isActive == 1) ...[
                            const SizedBox(width: 6),
                            _Badge(
                              text: '当前版本',
                              color: semantic.successDeep,
                              background: semantic.success.withValues(
                                alpha: 0.16,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        version.changeReason ?? '（无说明）',
                        style: const TextStyle(
                          fontSize: BubbleFontSize.secondary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _formatDateTime(version.createdAt),
                        style: TextStyle(
                          fontSize: BubbleFontSize.badge,
                          color: onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                      if (version.isActive != 1)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => _restore(version),
                            child: const Text('恢复此版本'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 4),
      _lockBar('全部修改留痕 · 恢复是新增版本而非覆盖'),
    ];
  }

  String _layerLabel(String layer) => switch (layer) {
    'core' => '核心层',
    'growth' => '成长层',
    'samples' => '样本层',
    _ => layer,
  };

  // ------------------------------------------------------------ 通用组件

  Widget _lockBar(String text) {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt,
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 15,
            color: semantic.lavenderDeep,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(String title, String subtitle) {
    final semantic = context.bubbleColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: Theme.of(context).colorScheme.onSurface
                  .withValues(alpha: 0.5),
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDateTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return iso;
    final local = parsed.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}

/// 小圆角徽章
class _Badge extends StatelessWidget {
  const _Badge({
    required this.text,
    required this.color,
    required this.background,
  });

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: BubbleFontSize.badge,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
