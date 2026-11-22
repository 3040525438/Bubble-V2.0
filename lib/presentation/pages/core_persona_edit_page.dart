// 核心人格编辑（T4.3）：字段化表单 + 保存前逐项 diff 确认（FR-PER-02、UI_PAGE_SPEC §11）。
// 任何保存都必须用户逐项勾选确认，确认后生成新版本（不覆盖历史）。
import 'package:flutter/material.dart';

import '../../data/database/db_provider.dart';
import '../../data/repositories/persona_repository.dart';
import '../../domain/persona/persona_models.dart';
import '../theme/bubble_colors.dart';

class CorePersonaEditPage extends StatefulWidget {
  const CorePersonaEditPage({super.key, this.repository});

  final PersonaRepository? repository;

  @override
  State<CorePersonaEditPage> createState() => _CorePersonaEditPageState();
}

class _CorePersonaEditPageState extends State<CorePersonaEditPage> {
  late final PersonaRepository _repo =
      widget.repository ?? PersonaRepository(AppDb.instance);

  PersonaCoreFields? _original;
  final Map<String, TextEditingController> _controllers = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _repo.ensureSeed();
    final core = await _repo.coreFields();
    if (!mounted) return;
    setState(() {
      _original = core;
      for (final key in PersonaCoreFields.fieldKeys) {
        _controllers[key] = TextEditingController(text: core.valueOf(key));
      }
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  PersonaCoreFields _edited() => PersonaCoreFields(
        identity: _controllers['identity']!.text,
        personality: _controllers['personality']!.text,
        values: _controllers['values']!.text,
        relationship: _controllers['relationship']!.text,
        speakingStyle: _controllers['speaking_style']!.text,
        boundaries: _controllers['boundaries']!.text,
      );

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _save() async {
    final original = _original;
    if (original == null || _saving) return;
    final edited = _edited();
    final changed = edited.changedKeysComparedTo(original);
    if (changed.isEmpty) {
      _toast('没有修改内容');
      return;
    }
    final nextVersionNo = await _nextVersionHint();
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CoreDiffDialog(
        original: original,
        edited: edited,
        changedKeys: changed,
        nextVersionNo: nextVersionNo,
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final version = await _repo.saveCore(
        edited,
        userConfirmed: true,
        reason: '用户修改核心人格：${changed.map((k) => PersonaCoreFields.fieldLabels[k] ?? k).join('、')}',
      );
      if (!mounted) return;
      _toast('已保存核心人格 v${version.versionNo}');
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$error');
    }
  }

  /// 展示用的下一个版本号（实际以仓储事务内分配为准）
  Future<int> _nextVersionHint() async {
    final versions = await _repo.versions();
    return (versions.isEmpty ? 0 : versions.first.versionNo) + 1;
  }

  @override
  Widget build(BuildContext context) {
    final original = _original;
    return Scaffold(
      appBar: AppBar(title: const Text('编辑核心人格')),
      body: original == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
              children: [
                _notice(),
                const SizedBox(height: 12),
                for (final key in PersonaCoreFields.fieldKeys) ...[
                  _fieldEditor(key),
                  const SizedBox(height: 12),
                ],
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中…' : '保存修改'),
                ),
              ],
            ),
    );
  }

  Widget _notice() {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: semantic.lavender.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.lavender.withValues(alpha: 0.6)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded,
              size: 16, color: semantic.lavenderDeep),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '保存前会逐项确认改动；保存后生成新版本，历史版本仍可恢复。',
              style: TextStyle(fontSize: BubbleFontSize.badge, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldEditor(String key) {
    final semantic = context.bubbleColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          PersonaCoreFields.fieldLabels[key] ?? key,
          style: TextStyle(
            fontSize: BubbleFontSize.secondary,
            fontWeight: FontWeight.w600,
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.7),
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          key: ValueKey('core_field_$key'),
          controller: _controllers[key],
          minLines: 2,
          maxLines: 5,
          style: const TextStyle(fontSize: BubbleFontSize.bodySmall, height: 1.5),
          decoration: InputDecoration(
            filled: true,
            fillColor: semantic.surfaceAlt,
            hintText: '填写${PersonaCoreFields.fieldLabels[key] ?? key}',
          ),
        ),
      ],
    );
  }
}

/// 保存前 diff 双栏确认：每项必须勾选（逐项确认），全部勾选才可保存。
class _CoreDiffDialog extends StatefulWidget {
  const _CoreDiffDialog({
    required this.original,
    required this.edited,
    required this.changedKeys,
    required this.nextVersionNo,
  });

  final PersonaCoreFields original;
  final PersonaCoreFields edited;
  final List<String> changedKeys;
  final int nextVersionNo;

  @override
  State<_CoreDiffDialog> createState() => _CoreDiffDialogState();
}

class _CoreDiffDialogState extends State<_CoreDiffDialog> {
  late final Set<String> _checked = {...widget.changedKeys};

  bool get _allChecked => _checked.length == widget.changedKeys.length;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    return AlertDialog(
      title: Text('确认修改（生成 v${widget.nextVersionNo}）'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final key in widget.changedKeys)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        value: _checked.contains(key),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(
                          '确认修改「${PersonaCoreFields.fieldLabels[key] ?? key}」',
                          style: const TextStyle(
                              fontSize: BubbleFontSize.bodySmall,
                              fontWeight: FontWeight.w600),
                        ),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _checked.add(key);
                          } else {
                            _checked.remove(key);
                          }
                        }),
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _diffBox(
                              context,
                              title: '原文',
                              value: widget.original.valueOf(key),
                              background:
                                  semantic.danger.withValues(alpha: 0.10),
                              color: semantic.dangerDeep,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _diffBox(
                              context,
                              title: '修改后',
                              value: widget.edited.valueOf(key),
                              background:
                                  semantic.success.withValues(alpha: 0.12),
                              color: semantic.successDeep,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('放弃'),
        ),
        FilledButton(
          onPressed: _allChecked ? () => Navigator.pop(context, true) : null,
          child: Text('确认保存（生成 v${widget.nextVersionNo}）'),
        ),
      ],
    );
  }

  Widget _diffBox(
    BuildContext context, {
    required String title,
    required String value,
    required Color background,
    required Color color,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 3),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(BubbleRadius.badge),
            ),
            child: Text(
              value,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: color,
                height: 1.45,
              ),
            ),
          ),
        ],
      );
}
