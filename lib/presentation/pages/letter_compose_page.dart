// 写信编辑器（T11.2）：抬头、正文、存草稿与寄出。
// 依据 UI_PAGE_SPEC §34、REQUIREMENTS FR-LET-01。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/repositories/letter_repository.dart';
import '../../domain/letter/letter_models.dart';
import '../theme/bubble_colors.dart';

class LetterComposePage extends StatefulWidget {
  const LetterComposePage({super.key, this.repository});

  final LetterRepository? repository;

  @override
  State<LetterComposePage> createState() => _LetterComposePageState();
}

class _LetterComposePageState extends State<LetterComposePage> {
  late final LetterRepository _repo =
      widget.repository ?? LetterRepository(AppDb.instance);
  final TextEditingController _controller = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveDraft() async {
    final content = _controller.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '先写点什么，再存草稿');
      return;
    }
    await _create(send: false);
  }

  Future<void> _send() async {
    final content = _controller.text.trim();
    if (content.isEmpty) {
      setState(() => _error = '先写点什么，再寄出');
      return;
    }
    await _create(send: true);
  }

  Future<void> _create({required bool send}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await _repo.createDraft(
        LetterDraft(
          direction: LetterDirection.userToBubble,
          content: _controller.text.trim(),
        ),
      );
      if (send) await _repo.sendLetter(created.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(send ? '信已寄出' : '已存进草稿'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      context.pop(true);
    } on StateError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message.toString();
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '保存失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final semantic = context.bubbleColors;
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('写一封信'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _saveDraft,
            child: const Text('存草稿'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(BubbleRadius.card),
              border: Border.all(color: semantic.stroke),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '你 → 泡泡 · ${now.year}年${now.month}月${now.day}日',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    fontWeight: FontWeight.w600,
                    color: onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 6),
                Divider(color: semantic.stroke, height: 1),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('letter-compose-content'),
                  controller: _controller,
                  minLines: 14,
                  maxLines: 24,
                  style: TextStyle(
                    fontSize: BubbleFontSize.body,
                    height: 2.0,
                    color: onSurface.withValues(alpha: 0.88),
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: '想和泡泡说些什么…',
                  ),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: semantic.dangerDeep,
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_rounded, size: 18),
            label: Text(_busy ? '处理中…' : '寄出这封信'),
          ),
          const SizedBox(height: 10),
          Text(
            '信只保存在本地。回信提醒受「说说与日记信件提醒」开关控制（通知接入在后续阶段）。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.5,
              color: onSurface.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}
