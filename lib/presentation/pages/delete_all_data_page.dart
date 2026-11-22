// 删除全部数据页（T14.6）：三重门（范围清单 / 确认短语 / 独立备份勾选）。
// 依据 UI_PAGE_SPEC §38、SECURITY_AND_PRIVACY 审计要求。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/data_center/data_center_service.dart';
import '../../data/database/db_provider.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

const kDeleteConfirmPhrase = '删除泡泡的全部记忆';

class DeleteAllDataPage extends StatefulWidget {
  const DeleteAllDataPage({super.key, this.service});

  final DataCenterService? service;

  @override
  State<DeleteAllDataPage> createState() => _DeleteAllDataPageState();
}

class _DeleteAllDataPageState extends State<DeleteAllDataPage> {
  late final DataCenterService _service =
      widget.service ?? DataCenterService(AppDb.instance);

  final TextEditingController _phrase = TextEditingController();
  Map<String, int>? _scope;
  bool _safetyBackup = true;
  bool _busy = false;
  DeleteAllDataResult? _result;

  @override
  void initState() {
    super.initState();
    _loadScope();
  }

  @override
  void dispose() {
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _loadScope() async {
    final scope = await _service.deletionScope();
    if (!mounted) return;
    setState(() => _scope = scope);
  }

  bool get _phraseOk => _phrase.text.trim() == kDeleteConfirmPhrase;

  bool get _canDelete => _scope != null && _phraseOk && !_busy;

  Future<void> _delete() async {
    if (!_canDelete) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('最后确认'),
        content: Text(
          '即将删除全部内容数据，且不可在应用内恢复。\n'
          '${_safetyBackup ? '删除前会自动创建一份独立备份。' : '未勾选独立备份，删除后无法恢复。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-delete-all'),
            style: FilledButton.styleFrom(
              backgroundColor: context.bubbleColors.dangerDeep,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _busy = true);
    DeleteAllDataResult? result;
    String? error;
    try {
      result = await _service.deleteAllData(createSafetyBackup: _safetyBackup);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
      if (error != null) {
        _phrase.text = '';
      }
    });
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      return;
    }
    await _loadScope();
  }

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return Scaffold(
      appBar: AppBar(title: const Text('删除全部数据')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            if (_result != null) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: semantic.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(BubbleRadius.card),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已删除全部内容数据',
                      style: TextStyle(
                        fontSize: BubbleFontSize.cardTitle,
                        fontWeight: FontWeight.w700,
                        color: semantic.successDeep,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '共 ${_result!.totalDeleted} 行、'
                      '${_result!.attachmentFilesDeleted} 个附件文件；'
                      '${_result!.autoBackup == null ? '未创建删除前备份' : '删除前备份已保存'}。'
                      '应用已回到首次启动状态。',
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () => context.go('/'),
                      child: const Text('回到首页'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            const _SectionTitle('门一 · 将被删除的内容'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: semantic.danger.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(BubbleRadius.card),
                border: Border.all(
                  color: semantic.danger.withValues(alpha: 0.45),
                ),
              ),
              child: _scope == null
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Column(
                      children: [
                        for (final entry in _scope!.entries)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.key,
                                    style: const TextStyle(
                                      fontSize: BubbleFontSize.bodySmall,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${entry.value}',
                                  style: const TextStyle(
                                    fontSize: BubbleFontSize.badge,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            const _SectionTitle('门二 · 输入确认短语'),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: semantic.surfaceAlt.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(BubbleRadius.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '请输入「$kDeleteConfirmPhrase」以继续',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('delete-confirm-phrase'),
                    controller: _phrase,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: kDeleteConfirmPhrase,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          BubbleRadius.button,
                        ),
                      ),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SectionTitle('门三 · 独立备份'),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: semantic.surfaceAlt.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(BubbleRadius.card),
              ),
              child: Material(
                color: Colors.transparent,
                child: CheckboxListTile(
                  key: const Key('delete-safety-backup'),
                  value: _safetyBackup,
                  onChanged: (v) => setState(() => _safetyBackup = v ?? false),
                  title: const Text(
                    '删除前自动创建独立备份',
                    style: TextStyle(fontSize: BubbleFontSize.bodySmall),
                  ),
                  subtitle: Text(
                    '备份保存在 Backups 目录，不受本次删除影响',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.5),
                    ),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ),
            ),
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('delete-all-button'),
              style: FilledButton.styleFrom(
                backgroundColor: semantic.dangerDeep,
                disabledBackgroundColor: semantic.mist.withValues(alpha: 0.5),
              ),
              onPressed: _canDelete ? _delete : null,
              child: Text(_busy ? '正在删除…' : '删除全部数据'),
            ),
            const SizedBox(height: 10),
            const MemoryLockBar(
              '不影响已导出的文件与备份包；删除会写入审计日志（journal_logs）；'
              '删除后回到首次启动引导态',
            ),
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
