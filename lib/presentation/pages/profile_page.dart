// 我的（Tab4，阶段 3 最小可用版）：泡泡资料头 + 功能入口。
// 记忆/人格/设置与数据的正式页面分别随阶段 5/4/14 落地，当前跳转到占位页。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theme/bubble_colors.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
        children: [
          Text('我的',
              style: TextStyle(
                fontSize: BubbleFontSize.pageTitle,
                fontWeight: FontWeight.w700,
                color: onSurface,
              )),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(BubbleRadius.card),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  semantic.lavender.withValues(alpha: 0.55),
                  semantic.bubbleUserB.withValues(alpha: 0.5),
                ],
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                  child: const Icon(Icons.cloud_rounded,
                      size: 32, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('泡泡',
                          style: TextStyle(
                            fontSize: BubbleFontSize.profileName,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          )),
                      const SizedBox(height: 4),
                      Text('正在学着更懂你一点。',
                          style: TextStyle(
                            fontSize: BubbleFontSize.secondary,
                            color: Colors.white.withValues(alpha: 0.85),
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _EntryCard(
            icon: Icons.memory_rounded,
            title: '模型管理',
            subtitle: '接入 DeepSeek、查看 Token 用量',
            onTap: () => context.push('/models'),
          ),
          _EntryCard(
            icon: Icons.psychology_alt_rounded,
            title: '人格中心',
            subtitle: '核心人格、成长记录与表达样本',
            onTap: () => context.push('/persona'),
          ),
          _EntryCard(
            icon: Icons.auto_stories_rounded,
            title: '记忆中心',
            subtitle: '收件箱、常驻记忆与冲突裁决',
            onTap: () => context.push('/memory'),
          ),
          _EntryCard(
            icon: Icons.psychology_rounded,
            title: '泡泡的思考',
            subtitle: '让她回顾聊天、记忆与约定',
            onTap: () => context.push('/thinking'),
          ),
          _EntryCard(
            icon: Icons.bolt_rounded,
            title: '主动性',
            subtitle: '主动程度、候选池与执行记录',
            onTap: () => context.push('/proactive'),
          ),
          _EntryCard(
            icon: Icons.tune_rounded,
            title: '设置',
            subtitle: '主动性、通知与数据管理',
            onTap: () => context.push('/settings'),
          ),
          const SizedBox(height: 10),
          Text(
            '泡泡 Bubble V2.0 · 本地优先 · 数据只存在这台设备上',
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
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(BubbleRadius.card),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(icon, size: 21, color: semantic.lavenderDeep),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                            fontSize: BubbleFontSize.cardTitle,
                            fontWeight: FontWeight.w600,
                            color: onSurface,
                          )),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(
                            fontSize: BubbleFontSize.badge,
                            color: onSurface.withValues(alpha: 0.45),
                          )),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: onSurface.withValues(alpha: 0.3)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
