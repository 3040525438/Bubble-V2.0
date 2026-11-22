// 恢复备份页（T14.6）：三步卡（选备份 → sha256 校验 → 对账恢复）。
// 依据 UI_PAGE_SPEC §37、DATABASE_DESIGN §2.28；恢复前自动先备份当前数据。
import 'package:flutter/material.dart';

import '../../data/backup/backup_service.dart';
import '../../data/database/db_provider.dart';
import '../../domain/backup/backup_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class BackupRestorePage extends StatefulWidget {
  const BackupRestorePage({super.key, this.service});

  final BackupService? service;

  @override
  State<BackupRestorePage> createState() => _BackupRestorePageState();
}

class _BackupRestorePageState extends State<BackupRestorePage> {
  late final BackupService _service =
      widget.service ?? BackupService(AppDb.instance);

  List<BackupArtifact> _backups = const [];
  BackupArtifact? _selected;
  BackupVerification? _verification;
  bool _busy = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final backups = await _service.listBackups();
    if (!mounted) return;
    setState(() {
      _backups = backups;
      _loading = false;
    });
  }

  Future<void> _createBackup() async {
    if (_busy) return;
    setState(() => _busy = true);
    String message;
    try {
      final backup = await _service.createBackup();
      message = '备份完成：${backup.totalRows} 行 · ${_sha(backup.sha256)}';
    } catch (e) {
      message = '备份失败：$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    await _reload();
  }

  Future<void> _verify(BackupArtifact artifact) async {
    setState(() {
      _selected = artifact;
      _verification = null;
      _busy = true;
    });
    final verification = await _service.verify(artifact);
    if (!mounted) return;
    setState(() {
      _verification = verification;
      _busy = false;
    });
  }

  Future<void> _restore(BackupArtifact artifact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认恢复备份'),
        content: const Text(
          '恢复将覆盖当前全部数据。\n'
          '系统会先自动备份当前数据，校验失败会中止且不修改数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-restore'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _busy = true);
    String message;
    try {
      final result = await _service.restore(artifact);
      message = result.ok
          ? '已恢复 ${result.restoredTables} 表 / ${result.restoredRows} 行'
                '（恢复前已自动备份）'
          : '恢复中止：${result.error}（当前数据未修改）';
    } catch (e) {
      message = '恢复失败：$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Scaffold(
      appBar: AppBar(title: const Text('备份与恢复')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    semantic.lavender.withValues(alpha: 0.24),
                    semantic.mist.withValues(alpha: 0.2),
                  ],
                ),
                borderRadius: BorderRadius.circular(BubbleRadius.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '目录包备份 · 校验后可恢复',
                    style: TextStyle(
                      fontSize: BubbleFontSize.cardTitle,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '备份包含内容表与附件副本；sha256 校验通过后才能恢复。'
                    '恢复前会自动先备份当前数据。',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const Key('create-backup'),
                    onPressed: _busy ? null : _createBackup,
                    icon: const Icon(Icons.backup_rounded, size: 18),
                    label: const Text('立即备份'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            if (_selected != null && _verification != null) ...[
              _VerifyCard(artifact: _selected!, verification: _verification!),
              const SizedBox(height: 14),
            ],
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_backups.isEmpty)
              const MemoryEmptyCard(
                title: '还没有备份',
                subtitle: '点「立即备份」创建第一份目录包备份',
              )
            else
              for (final artifact in _backups)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _BackupCard(
                    artifact: artifact,
                    busy: _busy,
                    onVerify: () => _verify(artifact),
                    onRestore: () => _restore(artifact),
                  ),
                ),
            const SizedBox(height: 8),
            const MemoryLockBar('备份目录：应用文档目录 / Backups；恢复不覆盖审计日志与迁移记录'),
          ],
        ),
      ),
    );
  }

  static String _sha(String? sha) {
    if (sha == null || sha.isEmpty) return '无 sha256';
    return sha.length <= 12 ? sha : '${sha.substring(0, 12)}…';
  }
}

class _BackupCard extends StatelessWidget {
  const _BackupCard({
    required this.artifact,
    required this.busy,
    required this.onVerify,
    required this.onRestore,
  });

  final BackupArtifact artifact;
  final bool busy;
  final VoidCallback onVerify;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
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
              MemoryBadge(
                text: artifact.kind.label,
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.18),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _fmt(artifact.createdAt),
                  style: const TextStyle(
                    fontSize: BubbleFontSize.bodySmall,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (artifact.isCorrupt)
                MemoryBadge(
                  text: '损坏',
                  color: semantic.dangerDeep,
                  background: semantic.danger.withValues(alpha: 0.16),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${artifact.totalRows} 行 · ${_size(artifact.sizeBytes)} · '
            '${_short(artifact.sha256)}',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            artifact.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.4),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton(
                key: Key('verify-${artifact.id}'),
                onPressed: busy ? null : onVerify,
                child: const Text('校验'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                key: Key('restore-${artifact.id}'),
                onPressed: busy ? null : onRestore,
                child: const Text('恢复'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  static String _size(int? bytes) {
    if (bytes == null) return '未知大小';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  static String _short(String? sha) {
    if (sha == null || sha.isEmpty) return '无 sha256';
    return sha.length <= 12 ? sha : '${sha.substring(0, 12)}…';
  }
}

class _VerifyCard extends StatelessWidget {
  const _VerifyCard({required this.artifact, required this.verification});

  final BackupArtifact artifact;
  final BackupVerification verification;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final ok = verification.ok;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: (ok ? semantic.success : semantic.danger).withValues(
          alpha: 0.08,
        ),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(
          color: (ok ? semantic.success : semantic.danger).withValues(
            alpha: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok ? Icons.verified_rounded : Icons.error_outline_rounded,
                size: 18,
                color: ok ? semantic.successDeep : semantic.dangerDeep,
              ),
              const SizedBox(width: 8),
              Text(
                ok ? '校验通过' : '校验未通过',
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w700,
                  color: ok ? semantic.successDeep : semantic.dangerDeep,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _line('sha256 一致', verification.sha256Matched ? '是' : '否'),
          _line('逐表行数对账', verification.countsMatched ? '一致' : '不一致'),
          _line('schema 版本', '${artifact.dbSchemaVersion ?? '?'}'),
          if (verification.error != null) ...[
            const SizedBox(height: 6),
            Text(
              verification.error!,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: semantic.dangerDeep,
              ),
            ),
          ],
          if (!verification.countsMatched) ...[
            const SizedBox(height: 6),
            Text(
              verification.countDiffs.entries
                  .take(6)
                  .map((e) => '${e.key} ${e.value > 0 ? '+' : ''}${e.value}')
                  .join(' · '),
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: BubbleFontSize.badge),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: BubbleFontSize.badge,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
