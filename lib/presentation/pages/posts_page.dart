// 说说主页（T10.1，Tab2）：心情筛选 + 双列瀑布流 + 写一篇入口。
// 依据 UI_PAGE_SPEC §2、REQUIREMENTS FR-POST。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/repositories/post_repository.dart';
import '../../domain/post/post_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class PostsPage extends StatefulWidget {
  const PostsPage({super.key, this.repository});

  final PostRepository? repository;

  @override
  State<PostsPage> createState() => _PostsPageState();
}

class _PostsPageState extends State<PostsPage> {
  late final PostRepository _repo =
      widget.repository ?? PostRepository(AppDb.instance);

  List<Post> _posts = const <Post>[];
  PostMood? _mood;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final posts = await _repo.listPosts(mood: _mood);
    if (!mounted) return;
    setState(() {
      _posts = posts;
      _loading = false;
    });
  }

  Future<void> _openGenerator() async {
    final published = await context.push<bool>('/post/generate');
    if (published == true) await _reload();
  }

  Future<void> _openDetail(String id) async {
    await context.push('/post/$id');
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final left = <Post>[];
    final right = <Post>[];
    for (var i = 0; i < _posts.length; i++) {
      (i.isEven ? left : right).add(_posts[i]);
    }
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
          children: [
            Row(
              children: [
                Text(
                  '说说',
                  style: TextStyle(
                    fontSize: BubbleFontSize.pageTitle,
                    fontWeight: FontWeight.w700,
                    color: onSurface,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _openGenerator,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('写一篇'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _moodChip(context, null, '全部', onSurface),
                for (final mood in PostMood.values)
                  _moodChip(context, mood, mood.label, onSurface),
              ],
            ),
            const SizedBox(height: 14),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.only(top: 40),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (_posts.isEmpty)
              const MemoryEmptyCard(
                title: '还没有说说',
                subtitle:
                    '泡泡会从记忆里想起一些小事，写成说说；'
                    '你也可以指定一个主题，让她写一篇。',
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        for (final post in left) ...[
                          _PostCard(
                            post: post,
                            onTap: () => _openDetail(post.id),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      children: [
                        for (final post in right) ...[
                          _PostCard(
                            post: post,
                            onTap: () => _openDetail(post.id),
                          ),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            if (_posts.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                '点按卡片查看详情 · 编辑历史保留在本地',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.35),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _moodChip(
    BuildContext context,
    PostMood? mood,
    String label,
    Color onSurface,
  ) {
    final semantic = context.bubbleColors;
    final selected = _mood == mood;
    return InkWell(
      key: ValueKey('mood-filter-${mood?.wire ?? 'all'}'),
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: () {
        setState(() => _mood = mood);
        _reload();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? semantic.bubbleUserA
              : semantic.surfaceAlt.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : onSurface,
          ),
        ),
      ),
    );
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({required this.post, required this.onTap});

  final Post post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final semantic = context.bubbleColors;
    final mood = PostMood.fromWire(post.mood);
    final hasImage = (post.imageIds ?? '').trim().isNotEmpty;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasImage) ...[
                Container(
                  height: 110,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(BubbleRadius.badge),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        semantic.pink.withValues(alpha: 0.45),
                        semantic.lavender.withValues(alpha: 0.45),
                      ],
                    ),
                  ),
                  child: Icon(
                    Icons.image_outlined,
                    color: Colors.white.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Text(
                post.content,
                maxLines: 7,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  height: 1.65,
                  color: onSurface.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  if (mood != null)
                    MemoryBadge(
                      text: mood.label,
                      color: semantic.pinkDeep,
                      background: semantic.pink.withValues(alpha: 0.18),
                    ),
                  if (post.origin == 'user_topic') ...[
                    const SizedBox(width: 4),
                    MemoryBadge(
                      text: '指定主题',
                      color: semantic.lavenderDeep,
                      background: semantic.lavender.withValues(alpha: 0.18),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    _relativeTime(post.publishedAt),
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      color: onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _relativeTime(int ms) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final diff = now - ms;
  if (diff < 60 * 1000) return '刚刚';
  if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
  if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
  if (diff < 7 * 24 * 60 * 60 * 1000) {
    return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
  }
  final local = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}
