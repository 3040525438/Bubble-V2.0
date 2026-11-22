// 后台任务日志页（T13.6，FR-IOS-07）：无 Mac 环境下的真机取证通道。
// 日志仅存本机 SQLite，导出的文本写到应用文档目录；不做任何上传。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/background_task_log_repository.dart';
import '../theme/bubble_colors.dart';

typedef LogExporter = Future<String> Function(String text, DateTime now);

class BackgroundLogsPage extends StatefulWidget {
  const BackgroundLogsPage({
    super.key,
    this.repository,
    this.exporter,
    this.clock,
  });

  final BackgroundTaskLogRepository? repository;
  final LogExporter? exporter;
  final DateTime Function()? clock;

  @override
  State<BackgroundLogsPage> createState() => _BackgroundLogsPageState();
}

class _BackgroundLogsPageState extends State<BackgroundLogsPage> {
  late final BackgroundTaskLogRepository _repo =
      widget.repository ?? BackgroundTaskLogRepository(AppDb.instance);
  DateTime Function() get _clock => widget.clock ?? DateTime.now;

  bool _loading = true;
  bool _busy = false;
  List<BackgroundTaskLog> _logs = const [];

  static const _eventLabels = <String, String>{
    'submit': '提交后台任务',
    'submit_skipped': '跳过后台任务',
    'submit_failed': '提交失败',
    'start': '任务开始',
    'finish': '任务完成',
    'finish_meta': '任务耗时',
    'fail': '任务失败',
    'expired': '超时中断',
    'complete': '结束任务',
    'complete_failed': '结束任务失败',
    'notify_scheduled': '安排提醒',
    'notify_skipped': '跳过提醒',
    'notify_failed': '提醒失败',
    'notify_cancelled': '取消提醒',
    'notify_expired': '提醒过期',
    'notify_rescheduled': '提醒重排',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final logs = await _repo.recent(limit: 200);
    if (!mounted) return;
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final text = await _repo.exportText(limit: 500);
      final exporter = widget.exporter ?? _defaultExport;
      final path = await exporter(text, _clock());
      if (!mounted) return;
      _toast('日志已导出：$path');
    } catch (error) {
      if (!mounted) return;
      _toast('导出失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _defaultExport(String text, DateTime now) async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final file = File('${dir.path}/bg_task_logs_$stamp.txt');
    await file.writeAsString(text);
    return file.path;
  }

  Future<void> _purge() async {
    setState(() => _busy = true);
    final removed = await _repo.purgeExpired(now: _clock());
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(removed > 0 ? '已清理 $removed 条 90 天前日志' : '没有需要清理的旧日志');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 1800),
        ),
      );
  }

  String _formatTime(int? ms) {
    if (ms == null) return '—';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.month.toString().padLeft(2, '0')}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '后台任务日志',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            key: const ValueKey('bg-logs-export'),
            tooltip: '导出日志',
            onPressed: _busy ? null : _export,
            icon: const Icon(Icons.ios_share_rounded),
          ),
          IconButton(
            tooltip: '清理 90 天前日志',
            onPressed: _busy ? null : _purge,
            icon: const Icon(Icons.cleaning_services_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
          ? _empty(onSurface)
          : ListView.separated(
              key: const ValueKey('bg-logs-list'),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              itemCount: _logs.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                if (index == _logs.length) return _footnote(onSurface);
                return _logTile(context, _logs[index], onSurface);
              },
            ),
    );
  }

  Widget _empty(Color onSurface) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 44,
              color: onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 10),
            Text(
              '还没有后台任务日志',
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                fontWeight: FontWeight.w600,
                color: onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '只有 iOS 真机在系统允许时执行后台任务才会产生记录。'
              '这里同时记录通知安排结果，方便排查「为什么没提醒」。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                height: 1.6,
                color: onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logTile(
    BuildContext context,
    BackgroundTaskLog log,
    Color onSurface,
  ) {
    final semantic = context.bubbleColors;
    final event = log.event ?? 'unknown';
    final isFailure = event.contains('fail') || event == 'expired';
    final color = isFailure ? semantic.dangerDeep : semantic.lavenderDeep;
    final label = _eventLabels[event] ?? event;
    final payload = (log.payload ?? '').trim();
    final preview = payload.length > 90
        ? '${payload.substring(0, 90)}…'
        : payload;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(BubbleRadius.badge),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              if (log.taskType != null && log.taskType!.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  log.taskType!,
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
              const Spacer(),
              Text(
                _formatTime(log.startedAt),
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
          if (preview.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              preview,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                height: 1.5,
                color: onSurface.withValues(alpha: 0.55),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _footnote(Color onSurface) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        '日志仅保存在本机，最多保留 90 天；导出为文本文件，方便在无 Mac 环境取证。',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: BubbleFontSize.badge,
          height: 1.6,
          color: onSurface.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}
