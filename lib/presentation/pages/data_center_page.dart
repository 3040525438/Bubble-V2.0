// 数据中心页（T14.6）：状态卡 + 维护操作卡组 + 危险区。
// 依据 UI_PAGE_SPEC §25、§38；数据操作均以服务层结果反馈，不假装成功。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../data/backup/export_service.dart';
import '../../data/data_center/data_center_service.dart';
import '../../data/database/db_provider.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class DataCenterPage extends StatefulWidget {
  const DataCenterPage({super.key, this.service, this.exporter});

  final DataCenterService? service;
  final ExportService? exporter;

  @override
  State<DataCenterPage> createState() => _DataCenterPageState();
}

class _DataCenterPageState extends State<DataCenterPage> {
  late final DataCenterService _service =
      widget.service ?? DataCenterService(AppDb.instance);
  late final ExportService _exporter =
      widget.exporter ?? ExportService(AppDb.instance);

  DataCenterStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final status = await _service.loadStatus();
    if (!mounted) return;
    setState(() => _status = status);
  }

  Future<void> _runMaintenance(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    String message;
    try {
      message = await action();
    } catch (e) {
      message = '操作失败：$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    await _reload();
  }

  Future<void> _checkIntegrity() => _runMaintenance(() async {
    final integrity = await _service.runIntegrityCheck();
    if (integrity.isHealthy) return '完整性检查通过：数据库、附件与索引均正常';
    final parts = <String>[
      if (!integrity.dbHealthy) '数据库异常',
      if (integrity.orphanFiles.isNotEmpty)
        '孤立附件 ${integrity.orphanFiles.length}',
      if (integrity.missingRecordIds.isNotEmpty)
        '附件缺失 ${integrity.missingRecordIds.length}',
      if (!integrity.indexConsistent) '记忆索引不一致',
    ];
    return '检查发现：${parts.join(' / ')}';
  });

  Future<void> _rebuildIndexes() => _runMaintenance(() async {
    final result = await _service.rebuildIndexes();
    return '索引已重建：记忆 ${result.memoryDocs} 篇 / 搜索词 ${result.contentTerms} 条';
  });

  Future<void> _cleanupOrphans() => _runMaintenance(() async {
    final deleted = await _service.cleanupOrphanFiles();
    return deleted == 0 ? '没有需要清理的孤立附件' : '已清理孤立附件 $deleted 个';
  });

  Future<void> _exportAll() => _runMaintenance(() async {
    final json = await _exporter.exportJson();
    final markdown = await _exporter.exportMarkdown();
    final paths = [...json.paths, ...markdown.paths];
    if (paths.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: paths.join('\n')));
    }
    return '已导出 ${paths.length} 个文件（路径已复制）：${paths.first}';
  });

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final status = _status;
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据中心'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (status == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else ...[
              _StatusCard(status: status),
              const SizedBox(height: 14),
              const _SectionLabel('维护操作'),
              _MaintenanceCard(
                children: [
                  _ActionRow(
                    icon: Icons.backup_rounded,
                    color: semantic.lavender,
                    title: '备份与恢复',
                    subtitle: '目录包备份 · sha256 校验 · 覆盖恢复',
                    onTap: () => context.push('/data/backup'),
                  ),
                  _ActionRow(
                    icon: Icons.file_download_outlined,
                    color: semantic.success,
                    title: '导出数据',
                    subtitle: 'JSON 全量 + Markdown 分域（导出目录）',
                    onTap: _busy ? null : _exportAll,
                  ),
                  _ActionRow(
                    icon: Icons.move_to_inbox_rounded,
                    color: semantic.pinkDeep,
                    title: '迁移与导入向导',
                    subtitle: 'AstrBot 只读迁移 · 预演 · 对账 · 回滚',
                    onTap: () => context.push('/data/migration'),
                  ),
                  _ActionRow(
                    icon: Icons.fact_check_outlined,
                    color: semantic.mist,
                    title: '完整性检查',
                    subtitle: '数据库 quick_check + 附件 + 索引',
                    onTap: _busy ? null : _checkIntegrity,
                  ),
                  _ActionRow(
                    icon: Icons.manage_search_rounded,
                    color: semantic.lavenderDeep,
                    title: '重建索引',
                    subtitle: '记忆索引 + 全局搜索倒排（派生数据）',
                    onTap: _busy ? null : _rebuildIndexes,
                  ),
                  _ActionRow(
                    icon: Icons.cleaning_services_outlined,
                    color: semantic.warn,
                    title: '清理孤立附件',
                    subtitle: '删除磁盘上无数据库记录的文件',
                    onTap: _busy ? null : _cleanupOrphans,
                  ),
                  _ActionRow(
                    icon: Icons.receipt_long_outlined,
                    color: semantic.bubbleUserA,
                    title: '反馈历史',
                    subtitle: '查看并撤销你给过泡泡的反馈',
                    onTap: () => context.push('/data/feedback'),
                  ),
                  _ActionRow(
                    icon: Icons.article_outlined,
                    color: semantic.successDeep,
                    title: '后台任务日志',
                    subtitle: '通知与后台刷新调试日志',
                    onTap: () => context.push('/settings/bg-logs'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const _SectionLabel('危险区', danger: true),
              _DangerCard(onTap: () => context.push('/data/delete')),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.danger = false});

  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: BubbleFontSize.bodySmall,
          fontWeight: FontWeight.w700,
          color: danger
              ? semantic.dangerDeep
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final DataCenterStatus status;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final lastBackup = status.lastBackup;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        children: [
          _StatusRow(
            label: '数据库',
            value: status.dbHealthy
                ? '正常 · schema v${status.schemaVersion}'
                : '异常',
            ok: status.dbHealthy,
          ),
          _StatusRow(
            label: '孤立附件',
            value: status.orphanFiles == 0 ? '无' : '${status.orphanFiles} 个',
            ok: status.orphanFiles == 0,
          ),
          _StatusRow(
            label: '附件缺失',
            value: status.missingFiles == 0 ? '无' : '${status.missingFiles} 条',
            ok: status.missingFiles == 0,
          ),
          _StatusRow(
            label: '记忆索引',
            value: status.indexConsistent ? '一致' : '需重建',
            ok: status.indexConsistent,
          ),
          _StatusRow(
            label: '最近备份',
            value: lastBackup == null
                ? '还没有备份'
                : '${lastBackup.kind.label} · ${_fmt(lastBackup.createdAt)}',
            ok: lastBackup != null,
          ),
          _StatusRow(
            label: '收件箱待确认',
            value: '${status.pendingMemoryCount} 条',
            ok: status.pendingMemoryCount == 0,
          ),
          _StatusRow(
            label: '存储占用',
            value:
                '附件 ${_bytes(status.attachmentBytes)} · 内容 ${status.totalRows} 行',
            ok: true,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in status.keyCounts.entries)
                MemoryBadge(
                  text: '${entry.key} ${entry.value}',
                  color: semantic.lavenderDeep,
                  background: semantic.surfaceAlt,
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

  static String _bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.label,
    required this.value,
    required this.ok,
  });

  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            size: 15,
            color: ok ? semantic.successDeep : semantic.warnDeep,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                color: onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: BubbleFontSize.badge,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MaintenanceCard extends StatelessWidget {
  const _MaintenanceCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Container(
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(children: children),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(BubbleRadius.badge),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: BubbleFontSize.bodySmall,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: onSurface.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

class _DangerCard extends StatelessWidget {
  const _DangerCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return InkWell(
      key: const Key('data-center-delete-all'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: semantic.danger.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(BubbleRadius.card),
          border: Border.all(color: semantic.danger.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(
              Icons.delete_forever_rounded,
              size: 22,
              color: semantic.dangerDeep,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '删除全部数据',
                    style: TextStyle(
                      fontSize: BubbleFontSize.bodySmall,
                      fontWeight: FontWeight.w700,
                      color: semantic.dangerDeep,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '三重门确认 · 不影响已导出的文件与备份包',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: semantic.dangerDeep.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: semantic.dangerDeep,
            ),
          ],
        ),
      ),
    );
  }
}
