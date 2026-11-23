// 主动行为决策中心（T8.3）：候选池、统一决策运行、执行留痕与反馈。
// 依据 AUTONOMOUS_SYSTEM §2、REQUIREMENTS FR-DEC-01~03 / FR-FBK-01。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/diary/diary_generator.dart';
import '../../data/letter/letter_generator.dart';
import '../../data/notification/notification_runtime.dart';
import '../../data/post/post_generator.dart';
import '../../data/proactive/content_deliverer.dart';
import '../../data/proactive/proactive_chat_deliverer.dart';
import '../../data/proactive/proactive_decision_center.dart';
import '../../data/repositories/conversation_repository.dart';
import '../../data/repositories/proactive_repository.dart';
import '../../domain/proactive/proactive_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';
import 'settings_page.dart';

class ProactiveCenterPage extends StatefulWidget {
  const ProactiveCenterPage({
    super.key,
    this.repository,
    this.center,
    this.clock,
  });

  final ProactiveRepository? repository;
  final ProactiveDecisionCenter? center;
  final DateTime Function()? clock;

  @override
  State<ProactiveCenterPage> createState() => _ProactiveCenterPageState();
}

class _ProactiveCenterPageState extends State<ProactiveCenterPage> {
  late final DateTime Function() _clock = widget.clock ?? DateTime.now;
  late final ProactiveRepository _repo =
      widget.repository ??
      ProactiveRepository(AppDb.instance, clock: widget.clock);
  late final ProactiveDecisionCenter _center =
      widget.center ??
      ProactiveDecisionCenter(
        AppDb.instance,
        repository: _repo,
        clock: widget.clock,
        // 与主界面保持一致：说说/日记/信件/主动聊天真实落地，而不是只留记录
        deliverer: contentAwareDeliverer(
          post: PostGenerator(AppDb.instance),
          diary: DiaryGenerator(AppDb.instance),
          letter: LetterGenerator(AppDb.instance),
          chat: NotificationRuntime.dispatcher == null
              ? null
              : ProactiveChatDeliverer(
                  conversations: ConversationRepository(AppDb.instance),
                  notifications: NotificationRuntime.dispatcher!,
                ),
          notifications: NotificationRuntime.dispatcher,
        ),
      );

  ProactiveSettings _settings = const ProactiveSettings();
  List<ProactiveCandidate> _pending = const <ProactiveCandidate>[];
  List<ProactiveAction> _actions = const <ProactiveAction>[];
  int _todayCount = 0;
  int? _lastAtMs;
  ProactiveRunResult? _lastRun;
  bool _loading = true;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final settings = await _repo.loadSettings();
    final pending = await _repo.pendingCandidates();
    final actions = await _repo.recentActions(limit: 20);
    final today = await _repo.executedTodayTotal();
    final lastAt = await _repo.lastProactiveAtMs();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _pending = pending;
      _actions = actions;
      _todayCount = today;
      _lastAtMs = lastAt;
      _loading = false;
    });
  }

  Future<void> _runOnce() async {
    if (_running) return;
    setState(() => _running = true);
    try {
      final result = await _center.runOnce();
      if (!mounted) return;
      setState(() {
        _running = false;
        _lastRun = result;
      });
      await _reload();
      if (!mounted) return;
      final summary = result.isEmpty && result.expired == 0
          ? '候选池是空的，泡泡暂时没有想做的事'
          : '执行 ${result.executed} · 顺延 ${result.deferred} · '
                '拒绝 ${result.rejected} · 过期 ${result.expired}';
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(summary), behavior: SnackBarBehavior.floating),
        );
    } catch (error) {
      if (!mounted) return;
      setState(() => _running = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('决策失败：$error')));
    }
  }

  Future<void> _execute(String candidateId) async {
    final decision = await _center.executeManually(candidateId);
    if (!mounted) return;
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            decision.isExecute
                ? '已执行并留下记录'
                : '未执行：${decision.note ?? decision.reason.label}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _cancel(String candidateId) async {
    await _repo.cancelCandidate(candidateId);
    await _reload();
  }

  Future<void> _feedback(ProactiveAction action, String verdict) async {
    await _repo.recordFeedback(
      candidateId: action.candidateId,
      actionId: action.id,
      verdict: verdict,
      note: verdict == 'like' ? '这次正好' : '这次不太合适',
    );
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('记下了：只调整这类行为的频率与优先级，不改核心人格'),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _revert(ProactiveAction action) async {
    final feedbackId = action.userFeedbackId;
    if (feedbackId == null) return;
    await _repo.revertFeedback(feedbackId);
    await _reload();
  }

  String _formatMs(int? ms) {
    if (ms == null) return '还没有';
    final local = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  String? _nextEligibleLabel() {
    final lastAt = _lastAtMs;
    if (lastAt == null) return null;
    final nextAt =
        lastAt +
        Duration(minutes: _settings.effectiveMinIntervalMinutes).inMilliseconds;
    if (nextAt <= _clock().millisecondsSinceEpoch) return null;
    return _formatMs(nextAt);
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text('主动行为'),
        actions: [
          IconButton(
            tooltip: '主动程度设置',
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _running ? null : _reload,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
              children: [
                _overviewCard(context, onSurface),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _running ? null : _runOnce,
                  icon: _running
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded),
                  label: Text(_running ? '正在决策…' : '运行一次决策'),
                ),
                const SizedBox(height: 18),
                _sectionTitle(context, '候选池（${_pending.length}）'),
                const SizedBox(height: 8),
                if (_pending.isEmpty)
                  const MemoryEmptyCard(
                    title: '候选池是空的',
                    subtitle:
                        '泡泡思考后产生的想聊天、想发说说、想写日记的念头会先来到这里，'
                        '再由决策中心统一判断要不要执行。',
                  )
                else
                  for (final candidate in _pending) ...[
                    _candidateCard(context, onSurface, candidate),
                    const SizedBox(height: 8),
                  ],
                const SizedBox(height: 14),
                _sectionTitle(context, '执行记录（最近 ${_actions.length} 次）'),
                const SizedBox(height: 8),
                if (_actions.isEmpty)
                  const MemoryEmptyCard(
                    title: '还没有主动记录',
                    subtitle: '每一次真正执行或被拒绝的决策都会留下痕迹，方便你回看与反馈。',
                  )
                else
                  for (final action in _actions) ...[
                    _actionCard(context, onSurface, action),
                    const SizedBox(height: 8),
                  ],
                const SizedBox(height: 16),
                const ProactiveExplainCard(),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text(
                      '硬限制：',
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        fontWeight: FontWeight.w700,
                        color: onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ),
                const SizedBox(height: 6),
                const HardLimitRow(
                  labels: ['勿扰时段', '同类冷却', '重复检测', '每日上限', '最短间隔', '安静决策'],
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: BubbleFontSize.bodySmall,
        fontWeight: FontWeight.w700,
        color: context.bubbleColors.lavenderDeep,
      ),
    );
  }

  Widget _overviewCard(BuildContext context, Color onSurface) {
    final semantic = context.bubbleColors;
    final nextEligible = _nextEligibleLabel();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            semantic.lavender.withValues(alpha: 0.32),
            semantic.mist.withValues(alpha: 0.28),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '今日已主动 $_todayCount / '
                  '${_settings.effectiveDailyCap} 次',
                  style: TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    fontWeight: FontWeight.w700,
                    color: onSurface,
                  ),
                ),
              ),
              MemoryBadge(
                text: _settings.level.label,
                color: semantic.lavenderDeep,
                background: Colors.white.withValues(alpha: 0.55),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '上次主动：${_formatMs(_lastAtMs)}'
            '${nextEligible == null ? '' : ' · 下次最早 $nextEligible'}',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.6),
            ),
          ),
          if (!_settings.enabled) ...[
            const SizedBox(height: 8),
            Text(
              '你已关闭「允许泡泡主动找我」，候选只会被记录，不会执行。',
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                fontWeight: FontWeight.w600,
                color: semantic.dangerDeep,
              ),
            ),
          ],
          if (_lastRun != null) ...[
            const SizedBox(height: 8),
            Text(
              '上一轮：执行 ${_lastRun!.executed} · 顺延 ${_lastRun!.deferred} · '
              '拒绝 ${_lastRun!.rejected} · 过期 ${_lastRun!.expired}',
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _candidateCard(
    BuildContext context,
    Color onSurface,
    ProactiveCandidate candidate,
  ) {
    final semantic = context.bubbleColors;
    final kind = ProactiveActionKind.fromWire(candidate.actionKind);
    final nowMs = _clock().millisecondsSinceEpoch;
    final cooldown = candidate.cooldownUntil;
    final deferred = cooldown != null && cooldown > nowMs;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MemoryBadge(
                text: kind.label,
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.2),
              ),
              const SizedBox(width: 6),
              MemoryBadge(
                text: '优先级 ${candidate.priority}',
                color: onSurface.withValues(alpha: 0.6),
                background: semantic.surfaceAlt,
              ),
              const Spacer(),
              if (deferred)
                MemoryBadge(
                  text: '顺延到 ${_formatMs(cooldown)}',
                  color: semantic.warnDeep,
                  background: semantic.warn.withValues(alpha: 0.16),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            (candidate.title ?? '').trim().isEmpty
                ? (candidate.contentDraft ?? kind.label)
                : candidate.title!,
            style: TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              fontWeight: FontWeight.w600,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${candidate.sourceKind ?? '未知来源'} · '
            '过期 ${_formatMs(candidate.expiresAt)}',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.45),
            ),
          ),
          if ((candidate.contentDraft ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              candidate.contentDraft!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                height: 1.5,
                color: onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => _cancel(candidate.id),
                child: const Text('忽略'),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: () => _execute(candidate.id),
                child: const Text('立即执行'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionCard(
    BuildContext context,
    Color onSurface,
    ProactiveAction action,
  ) {
    final semantic = context.bubbleColors;
    final kind = ProactiveActionKind.fromWire(action.actionKind);
    final hasFeedback = action.userFeedbackId != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        border: Border.all(color: semantic.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              MemoryBadge(
                text: kind.label,
                color: semantic.lavenderDeep,
                background: semantic.lavender.withValues(alpha: 0.2),
              ),
              const SizedBox(width: 8),
              Text(
                _formatMs(action.executedAt),
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.45),
                ),
              ),
              const Spacer(),
              if (hasFeedback)
                TextButton(
                  onPressed: () => _revert(action),
                  child: const Text('撤销反馈'),
                ),
            ],
          ),
          if ((action.decisionNote ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              action.decisionNote!,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                height: 1.5,
                color: onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
          if (!hasFeedback && kind != ProactiveActionKind.quiet)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => _feedback(action, 'dislike'),
                  child: const Text('别这样'),
                ),
                const SizedBox(width: 4),
                TextButton(
                  onPressed: () => _feedback(action, 'like'),
                  child: const Text('正好'),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
