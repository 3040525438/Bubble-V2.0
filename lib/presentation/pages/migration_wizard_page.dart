// 迁移与导入向导页（T14.6）：五步（备份/预演/导入/对账/验证）+ 回滚。
// 依据 UI_PAGE_SPEC §26、MIGRATION_PLAN §2/§3；源只读、API Key 不迁移、失败如实报告。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/migration/astrbot_import_service.dart';
import '../../data/migration/astrbot_source.dart';
import '../../data/migration/migration_source_picker.dart';
import '../../domain/migration/migration_models.dart';
import '../app/router.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class MigrationWizardPage extends StatefulWidget {
  const MigrationWizardPage({
    super.key,
    this.serviceFactory,
    this.picker,
    this.initialSourcePath = '',
  });

  /// 测试注入：按源路径创建导入服务。
  final AstrBotImportService Function(String rootPath)? serviceFactory;

  /// 测试注入：来源选择器（默认系统文件选择）。
  final MigrationSourcePicker? picker;
  final String initialSourcePath;

  @override
  State<MigrationWizardPage> createState() => _MigrationWizardPageState();
}

class _MigrationWizardPageState extends State<MigrationWizardPage> {
  late final TextEditingController _path = TextEditingController(
    text: widget.initialSourcePath,
  );
  late final MigrationSourcePicker _picker =
      widget.picker ?? FilePickerMigrationSourcePicker();

  AstrBotImportService? _service;
  MigrationDryRun? _dryRun;
  ImportBatchResult? _batch;
  ReconcileReport? _reconcile;
  RollbackResult? _rollback;

  bool _busy = false;
  bool _overwrite = true;
  int _stepDone = 0;
  int _stepTotal = 0;
  String _phase = '';

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  AstrBotImportService _ensureService() {
    final existing = _service;
    if (existing != null) return existing;
    final rootPath = _path.text.trim();
    if (rootPath.isEmpty) throw StateError('请先填写 AstrBot 源目录');
    final service =
        widget.serviceFactory?.call(rootPath) ??
        AstrBotImportService(
          AppDb.instance,
          source: AstrBotSource(rootPath: rootPath),
        );
    _service = service;
    return service;
  }

  /// 通过系统选择器选择来源，成功后自动预演。
  Future<void> _pickSource(
    Future<PickedMigrationSource?> Function() pick, {
    required String failureHint,
  }) async {
    if (_busy) return;
    PickedMigrationSource? picked;
    try {
      picked = await pick();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('$failureHint：$e')));
      return;
    }
    final source = picked;
    if (source == null || !mounted) return;
    setState(() {
      _path.text = source.rootPath;
      _service = null;
      _dryRun = null;
      _batch = null;
      _reconcile = null;
      _rollback = null;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            source.fromArchive
                ? '已解压「${source.label}」，正在预演'
                : '已选择「${source.label}」，正在预演',
          ),
        ),
      );
    await _runDryRun();
  }

  Future<void> _runDryRun() async {
    if (_busy) return;
    setState(() => _busy = true);
    MigrationDryRun? dryRun;
    String? error;
    try {
      _service = null;
      dryRun = await _ensureService().dryRun(overwrite: _overwrite);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _dryRun = dryRun;
      _batch = null;
      _reconcile = null;
      _rollback = null;
    });
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('预演失败：$error')));
    }
  }

  Future<void> _runImport() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _stepDone = 0;
      _stepTotal = 9;
      _phase = '准备';
    });
    ImportBatchResult? batch;
    String? error;
    try {
      batch = await _ensureService().run(
        overwrite: _overwrite,
        onProgress: (done, total, phase) {
          if (!mounted) return;
          setState(() {
            _stepDone = done;
            _stepTotal = total;
            _phase = phase;
          });
        },
      );
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _batch = batch;
    });
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$error')));
    }
  }

  Future<void> _runReconcile() async {
    final batch = _batch;
    if (batch == null || _busy) return;
    setState(() => _busy = true);
    ReconcileReport? report;
    try {
      report = await _ensureService().reconcile(batch.batchId);
    } catch (_) {
      report = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _reconcile = report;
    });
  }

  Future<void> _runRollback() async {
    final batch = _batch;
    if (batch == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('回滚本批次'),
        content: const Text('将按迁移记录反查目标数据并整批软删（人格版本为硬删）。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-rollback'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('回滚'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _busy = true);
    RollbackResult? result;
    try {
      result = await _ensureService().rollback(batch.batchId);
    } catch (_) {
      result = null;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _rollback = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final dryRun = _dryRun;
    final batch = _batch;
    return Scaffold(
      appBar: AppBar(title: const Text('迁移与导入向导')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    semantic.lavender.withValues(alpha: 0.26),
                    semantic.bubbleUserA.withValues(alpha: 0.16),
                  ],
                ),
                borderRadius: BorderRadius.circular(BubbleRadius.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'AstrBot 迁移向导',
                        style: TextStyle(
                          fontSize: BubbleFontSize.cardTitle,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      MemoryBadge(
                        text: '源只读',
                        color: semantic.successDeep,
                        background: semantic.success.withValues(alpha: 0.18),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('migration-source-path'),
                    controller: _path,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      hintText: 'AstrBot 数据目录（例如 …/astrbot）',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          BubbleRadius.button,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('migration-pick-archive'),
                          onPressed: _busy
                              ? null
                              : () => _pickSource(
                                  _picker.pickArchive,
                                  failureHint: '选择压缩包失败',
                                ),
                          icon: const Icon(Icons.folder_zip_outlined, size: 18),
                          label: const Text('选择 .zip 压缩包'),
                        ),
                      ),
                      if (_picker.supportsDirectory) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('migration-pick-directory'),
                            onPressed: _busy
                                ? null
                                : () => _pickSource(
                                    _picker.pickDirectory,
                                    failureHint: '选择文件夹失败',
                                  ),
                            icon: const Icon(
                              Icons.folder_open_rounded,
                              size: 18,
                            ),
                            label: const Text('选择文件夹'),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'iOS / Android 请选择 .zip 压缩包；桌面版可直接选择文件夹。'
                    '压缩包会解压到临时目录，源文件不会被修改。',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      height: 1.4,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 10),
                  _StepBadges(
                    done: [
                      batch != null || _busy,
                      dryRun != null || _busy,
                      batch != null,
                      _reconcile != null,
                      _reconcile?.ok ?? false,
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // 覆盖开关：重复导入时用源数据更新此前的导入内容（聊天消息永不改写）
            SwitchListTile(
              key: const Key('migration-overwrite'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _overwrite,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _overwrite = value),
              title: const Text('覆盖此前导入的同源内容'),
              subtitle: Text(
                '开启后，重复导入会按源内容更新已存在的聊天消息 / 说说 / 日记 / 信件 / 记忆 / 人格提示词；'
                '你手写的日记不会被改写。关闭则只补缺失项。',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  height: 1.4,
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.5),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const Key('migration-dry-run'),
                    onPressed: _busy ? null : _runDryRun,
                    child: const Text('① 预演'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    key: const Key('migration-run'),
                    onPressed: _busy || dryRun == null ? null : _runImport,
                    child: const Text('② 开始导入'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _stepTotal == 0 ? null : _stepDone / _stepTotal,
              ),
              const SizedBox(height: 6),
              Text(
                '$_phase（$_stepDone/$_stepTotal）',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: Theme.of(context).colorScheme.onSurface
                      .withValues(alpha: 0.55),
                ),
              ),
            ],
            if (dryRun != null) ...[
              const SizedBox(height: 16),
              _SectionTitle('预演报告'),
              if (!dryRun.sourceAvailable)
                const MemoryEmptyCard(
                  title: '源目录不可读',
                  subtitle: '请检查路径是否存在，且当前系统可访问',
                )
              else
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: semantic.surfaceAlt.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(BubbleRadius.card),
                  ),
                  child: Column(
                    children: [
                      for (final entry in dryRun.entries)
                        _DryRunRow(entry: entry),
                      const SizedBox(height: 8),
                      const MemoryLockBar('API Key 一律不迁移；人格冲突需人工选择'),
                    ],
                  ),
                ),
            ],
            if (batch != null) ...[
              const SizedBox(height: 16),
              _SectionTitle('导入结果'),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: semantic.surfaceAlt.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(BubbleRadius.card),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '批次 ${batch.batchId}',
                      style: const TextStyle(
                        fontSize: BubbleFontSize.bodySmall,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '导入 ${batch.importedTotal} 条 · 跳过 ${batch.skippedTotal} 条 · '
                      '失败 ${batch.failed} 条',
                      style: const TextStyle(fontSize: BubbleFontSize.badge),
                    ),
                    for (final entry in batch.imported.entries)
                      Text(
                        '${entry.key.label}：+${entry.value}'
                        '${batch.skipped[entry.key] == null ? '' : ' / 跳过 ${batch.skipped[entry.key]}'}',
                        style: TextStyle(
                          fontSize: BubbleFontSize.badge,
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    if (batch.needsManual.values.any((v) => v > 0)) ...[
                      const SizedBox(height: 6),
                      Text(
                        '需人工选择：${batch.needsManual.entries.where((e) => e.value > 0).map((e) => '${e.key.label} ${e.value}').join(' / ')}',
                        style: TextStyle(
                          fontSize: BubbleFontSize.badge,
                          color: semantic.warnDeep,
                        ),
                      ),
                      if ((batch.needsManual[MigrationCategory.persona] ?? 0) >
                          0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '人格已导入为「未激活版本」，不会覆盖你现有的核心人格。'
                          '前往人格中心 → 版本历史，点「恢复此版本」即可生效。',
                          style: TextStyle(
                            fontSize: BubbleFontSize.badge,
                            height: 1.5,
                            color: Theme.of(context).colorScheme.onSurface
                                .withValues(alpha: 0.55),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: const Key('migration-go-persona'),
                            onPressed: () => context.go(AppRoutes.persona),
                            child: const Text('去人格中心'),
                          ),
                        ),
                      ],
                    ],
                    if (batch.errors.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        batch.errors.first,
                        style: TextStyle(
                          fontSize: BubbleFontSize.badge,
                          color: semantic.dangerDeep,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton(
                          key: const Key('migration-reconcile'),
                          onPressed: _busy ? null : _runReconcile,
                          child: const Text('查看对账'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          key: const Key('migration-rollback'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: semantic.dangerDeep,
                          ),
                          onPressed: _busy ? null : _runRollback,
                          child: const Text('回滚本批次'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            if (_reconcile != null) ...[
              const SizedBox(height: 16),
              _SectionTitle('对账报告'),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_reconcile!.ok ? semantic.success : semantic.danger)
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(BubbleRadius.card),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _reconcile!.ok ? '三向对账通过' : '对账存在差异',
                      style: TextStyle(
                        fontSize: BubbleFontSize.bodySmall,
                        fontWeight: FontWeight.w700,
                        color: _reconcile!.ok
                            ? semantic.successDeep
                            : semantic.dangerDeep,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final row in _reconcile!.rows)
                      Text(
                        '${row.category.label}：记录 ${row.recordCount} / 目标 ${row.targetCount}'
                        '${row.matched ? ' ✓' : ' ✗'}',
                        style: const TextStyle(fontSize: BubbleFontSize.badge),
                      ),
                  ],
                ),
              ),
            ],
            if (_rollback != null) ...[
              const SizedBox(height: 16),
              _SectionTitle('回滚结果'),
              MemoryLockBar(
                _rollback!.ok
                    ? '已回滚 ${_rollback!.affectedRecords} 条记录'
                          '（软删 ${_rollback!.softDeleted} / 硬删 ${_rollback!.hardDeleted}）'
                    : '回滚未执行：${_rollback!.error}',
              ),
            ],
            const SizedBox(height: 16),
            const MemoryLockBar('导入数据带「导入」标记，可按来源筛选与纠错；AstrBot 不再是运行依赖'),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: BubbleFontSize.bodySmall,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurface
              .withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _StepBadges extends StatelessWidget {
  const _StepBadges({required this.done});

  final List<bool> done;

  static const _labels = ['备份', '预演', '导入', '对账', '验证'];

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < _labels.length; i++)
          MemoryBadge(
            text: '${_labels[i]}${done[i] ? ' ✓' : ''}',
            color: done[i] ? semantic.successDeep : semantic.lavenderDeep,
            background: (done[i] ? semantic.success : semantic.lavender)
                .withValues(alpha: 0.16),
          ),
      ],
    );
  }
}

class _DryRunRow extends StatelessWidget {
  const _DryRunRow({required this.entry});

  final MigrationDryRunEntry entry;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.category.label,
                  style: const TextStyle(
                    fontSize: BubbleFontSize.bodySmall,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '源 ${entry.sourceCount} · 可导入 ${entry.importable}',
                style: const TextStyle(fontSize: BubbleFontSize.badge),
              ),
              if (entry.needsManual > 0) ...[
                const SizedBox(width: 6),
                MemoryBadge(
                  text: '需人工 ${entry.needsManual}',
                  color: semantic.warnDeep,
                  background: semantic.warn.withValues(alpha: 0.18),
                ),
              ],
            ],
          ),
          if (entry.note != null && entry.note!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                entry.note!,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
