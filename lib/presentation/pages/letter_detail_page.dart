// 信件详情（T11.2）：信纸卡、落款与签名、草稿编辑/寄出、已寄出再读与删除。
// 依据 UI_PAGE_SPEC §19、REQUIREMENTS FR-LET-01。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/letter_repository.dart';
import '../../domain/letter/letter_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class LetterDetailPage extends StatefulWidget {
  const LetterDetailPage({super.key, required this.letterId, this.repository});

  final String letterId;
  final LetterRepository? repository;

  @override
  State<LetterDetailPage> createState() => _LetterDetailPageState();
}

class _LetterDetailPageState extends State<LetterDetailPage> {
  late final LetterRepository _repo =
      widget.repository ?? LetterRepository(AppDb.instance);
  final ScrollController _scrollController = ScrollController();

  Letter? _letter;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final letter = await _repo.getLetter(widget.letterId);
    if (!mounted) return;
    setState(() {
      _letter = letter;
      _loading = false;
    });
  }

  Future<void> _send() async {
    final letter = _letter;
    if (letter == null || _sending) return;
    setState(() => _sending = true);
    try {
      await _repo.sendLetter(letter.id);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('信已寄出'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    } on StateError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error.message.toString())));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('寄出失败：$error')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _edit() async {
    final letter = _letter;
    if (letter == null) return;
    final controller = TextEditingController(text: letter.content);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑这封信'),
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
                '只有草稿可以修改；寄出之后就当作真的送出去了。',
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
      await _repo.updateDraft(letter.id, content: saved);
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _delete() async {
    final letter = _letter;
    if (letter == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移到回收站？'),
        content: const Text('信件会保留 30 天，期间可以在数据中心恢复。'),
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
    await _repo.softDelete(letter.id);
    if (!mounted) return;
    context.pop();
  }

  void _readAgain() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final letter = _letter;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text('信件'),
        actions: [
          if (letter != null)
            IconButton(
              tooltip: '删除',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : letter == null
          ? const Center(child: Text('这封信不存在或已被删除'))
          : ListView(
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
              children: [
                _paperCard(context, letter, onSurface),
                const SizedBox(height: 14),
                _relatedSection(context, onSurface, letter),
                const SizedBox(height: 16),
                if (LetterState.fromWire(letter.state).isDraft) ...[
                  FilledButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: Text(_sending ? '寄出中…' : '寄出这封信'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _edit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑草稿'),
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _readAgain,
                          icon: const Icon(Icons.replay_rounded, size: 18),
                          label: const Text('再读一遍'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextButton(
                          onPressed: _delete,
                          style: TextButton.styleFrom(
                            foregroundColor: context.bubbleColors.dangerDeep,
                          ),
                          child: const Text('删除这封信'),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                Text(
                  '信只保存在本地；泡泡主动写信至少间隔 7 天。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: onSurface.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _paperCard(BuildContext context, Letter letter, Color onSurface) {
    final semantic = context.bubbleColors;
    final direction = LetterDirection.fromWire(letter.direction);
    final state = LetterState.fromWire(letter.state);
    final title = (letter.title ?? '').trim().isEmpty
        ? LetterRules.deriveTitle(letter.content)
        : letter.title!.trim();
    final sentAt = letter.sentAt;
    final timeLabel = sentAt == null ? '未寄出 · 草稿' : _formatDateTime(sentAt);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
        boxShadow: [
          BoxShadow(
            color: semantic.pink.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, 8),
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
                  '${direction.routeLabel} · $timeLabel',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    fontWeight: FontWeight.w600,
                    color: onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ),
              MemoryBadge(
                text: state.label,
                color: state.isDraft ? semantic.warnDeep : semantic.successDeep,
                background: (state.isDraft ? semantic.warn : semantic.success)
                    .withValues(alpha: 0.16),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Divider(color: semantic.stroke, height: 1),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            letter.content,
            style: TextStyle(
              fontSize: BubbleFontSize.body,
              height: 2.0,
              color: onSurface.withValues(alpha: 0.86),
            ),
          ),
          const SizedBox(height: 18),
          if (direction.isFromBubble)
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [semantic.lavender, semantic.bubbleUserA],
                      ),
                    ),
                    child: const Icon(
                      Icons.cloud_rounded,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    LetterRules.signature,
                    style: TextStyle(
                      fontSize: BubbleFontSize.secondary,
                      fontStyle: FontStyle.italic,
                      color: onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '— 你',
                style: TextStyle(
                  fontSize: BubbleFontSize.secondary,
                  fontStyle: FontStyle.italic,
                  color: onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _relatedSection(BuildContext context, Color onSurface, Letter letter) {
    final memories = LetterRules.decodeIds(letter.relatedMemoryIds);
    final experiences = LetterRules.decodeIds(letter.relatedExperienceIds);
    if (memories.isEmpty && experiences.isEmpty) {
      return const SizedBox.shrink();
    }
    final semantic = context.bubbleColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '写信时想起的',
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: FontWeight.w700,
            color: semantic.pinkDeep,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final id in experiences)
              ActionChip(
                label: Text('共同经历 · ${_short(id)}'),
                onPressed: () => context.push('/experience/$id'),
              ),
            for (final id in memories)
              ActionChip(
                label: Text('记忆 · ${_short(id)}'),
                onPressed: () => context.push('/memory/detail/$id'),
              ),
          ],
        ),
      ],
    );
  }

  static String _short(String id) =>
      id.length > 12 ? '${id.substring(0, 12)}…' : id;

  String _formatDateTime(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${local.year}年${local.month}月${local.day}日 '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
