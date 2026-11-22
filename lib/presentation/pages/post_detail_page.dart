// 说说详情（T10.1）：作者来源、正文、关联记忆、编辑历史与软删除。
// 依据 UI_PAGE_SPEC §28、DATABASE_DESIGN §2.18。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/feedback_repository.dart';
import '../../data/repositories/post_repository.dart';
import '../../domain/feedback/feedback_models.dart';
import '../../domain/post/post_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    required this.postId,
    this.repository,
    this.feedbackRepository,
  });

  final String postId;
  final PostRepository? repository;
  final FeedbackRepository? feedbackRepository;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late final PostRepository _repo =
      widget.repository ?? PostRepository(AppDb.instance);
  late final FeedbackRepository _feedbackRepo =
      widget.feedbackRepository ?? FeedbackRepository(AppDb.instance);

  Post? _post;
  List<JournalLog> _history = const <JournalLog>[];
  FeedbackEntry? _latestFeedback;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final post = await _repo.getPost(widget.postId);
    final history = await _repo.editHistory(widget.postId);
    final latest = await _feedbackRepo.latestFor(
      FeedbackTargetKind.post,
      widget.postId,
    );
    if (!mounted) return;
    setState(() {
      _post = post;
      _history = history;
      _latestFeedback = latest;
      _loading = false;
    });
  }

  /// 赞/踩切换：同一态度再次点击视为撤销（FR-FBK-01）。
  Future<void> _toggleFeedback(FeedbackVerdict verdict) async {
    final latest = _latestFeedback;
    try {
      if (latest != null && latest.verdict == verdict) {
        await _feedbackRepo.revert(latest.id);
      } else {
        await _feedbackRepo.record(
          kind: FeedbackTargetKind.post,
          targetId: widget.postId,
          verdict: verdict,
        );
      }
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('反馈失败：$error')));
    }
  }

  Future<void> _edit() async {
    final post = _post;
    if (post == null) return;
    final controller = TextEditingController(text: post.content);
    final saved = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑说说'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
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
    if (saved == null || saved.isEmpty) return;
    try {
      await _repo.updatePost(post.id, content: saved);
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _delete() async {
    final post = _post;
    if (post == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移到回收站？'),
        content: const Text('说说会保留 30 天，期间可以在数据中心恢复。'),
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
    await _repo.softDelete(post.id);
    if (!mounted) return;
    context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final post = _post;
    return Scaffold(
      appBar: AppBar(
        title: const Text('说说'),
        actions: [
          if (post != null) ...[
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
          : post == null
          ? const Center(child: Text('这条说说不存在或已被删除'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
              children: [
                _authorRow(context, onSurface, post),
                const SizedBox(height: 16),
                Text(
                  post.content,
                  style: TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    height: 1.8,
                    color: onSurface.withValues(alpha: 0.88),
                  ),
                ),
                const SizedBox(height: 12),
                _feedbackRow(context, onSurface),
                if ((post.imageIds ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    height: 150,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(BubbleRadius.card),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          context.bubbleColors.pink.withValues(alpha: 0.45),
                          context.bubbleColors.lavender.withValues(alpha: 0.45),
                        ],
                      ),
                    ),
                    child: Icon(
                      Icons.image_outlined,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _relatedSection(context, onSurface, post),
                const SizedBox(height: 18),
                _historySection(context, onSurface),
              ],
            ),
    );
  }

  Widget _feedbackRow(BuildContext context, Color onSurface) {
    final semantic = context.bubbleColors;
    final verdict = _latestFeedback?.verdict;

    Widget button({
      required FeedbackVerdict value,
      required IconData icon,
      required String label,
    }) {
      final active = verdict == value;
      final color = value == FeedbackVerdict.like
          ? semantic.successDeep
          : semantic.dangerDeep;
      return TextButton.icon(
        key: Key('post-feedback-${value.wire}'),
        onPressed: () => _toggleFeedback(value),
        icon: Icon(
          icon,
          size: 17,
          color: active ? color : onSurface.withValues(alpha: 0.45),
        ),
        label: Text(
          label,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? color : onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return Row(
      children: [
        Text(
          '这条说说感觉如何？',
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            color: onSurface.withValues(alpha: 0.45),
          ),
        ),
        const Spacer(),
        button(
          value: FeedbackVerdict.like,
          icon: Icons.thumb_up_alt_outlined,
          label: '喜欢',
        ),
        button(
          value: FeedbackVerdict.dislike,
          icon: Icons.thumb_down_alt_outlined,
          label: '不喜欢',
        ),
      ],
    );
  }

  Widget _authorRow(BuildContext context, Color onSurface, Post post) {
    final semantic = context.bubbleColors;
    final mood = PostMood.fromWire(post.mood);
    final topic = (post.topic ?? '').trim();
    final sourceText = post.origin == PostOrigin.userTopic.wire
        ? '按「$topic」生成'
        : (topic.isEmpty ? '泡泡自主生成' : '由「$topic」想起');
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [semantic.lavender, semantic.bubbleUserA],
            ),
          ),
          child: const Icon(Icons.cloud_rounded, color: Colors.white, size: 24),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '泡泡',
                style: TextStyle(
                  fontSize: BubbleFontSize.cardTitle,
                  fontWeight: FontWeight.w700,
                  color: onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$sourceText · ${_formatDateTime(post.publishedAt)}',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
        ),
        if (mood != null)
          MemoryBadge(
            text: mood.label,
            color: semantic.pinkDeep,
            background: semantic.pink.withValues(alpha: 0.18),
          ),
      ],
    );
  }

  Widget _relatedSection(BuildContext context, Color onSurface, Post post) {
    final ids = PostRules.decodeIds(post.relatedMemoryIds);
    if (ids.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '关联记忆',
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: FontWeight.w700,
            color: context.bubbleColors.lavenderDeep,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final id in ids)
              ActionChip(
                label: Text(id.length > 14 ? '${id.substring(0, 14)}…' : id),
                onPressed: () => context.push('/memory/detail/$id'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _historySection(BuildContext context, Color onSurface) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '编辑历史',
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: FontWeight.w700,
            color: context.bubbleColors.lavenderDeep,
          ),
        ),
        const SizedBox(height: 8),
        for (final log in _history)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(top: 6),
                  decoration: BoxDecoration(
                    color: context.bubbleColors.lavender,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${_opLabel(log.op)} · ${_formatDateTimeIso(log.at)}',
                        style: TextStyle(
                          fontSize: BubbleFontSize.badge,
                          fontWeight: FontWeight.w600,
                          color: onSurface.withValues(alpha: 0.65),
                        ),
                      ),
                      if ((log.afterDigest ?? '').isNotEmpty)
                        Text(
                          log.afterDigest!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: BubbleFontSize.badge,
                            height: 1.4,
                            color: onSurface.withValues(alpha: 0.42),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        Text(
          '删除的说说会保留 30 天，之后可在数据中心清理。',
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            color: onSurface.withValues(alpha: 0.35),
          ),
        ),
      ],
    );
  }

  String _opLabel(String op) {
    switch (op) {
      case 'create':
        return '生成';
      case 'update':
        return '你手动改';
      case 'delete':
        return '删除';
      default:
        return op;
    }
  }

  String _formatDateTime(int ms) {
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${local.month.toString().padLeft(2, '0')}月'
        '${local.day.toString().padLeft(2, '0')}日 '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  String _formatDateTimeIso(String iso) {
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return iso;
    return _formatDateTime(parsed.millisecondsSinceEpoch);
  }
}
