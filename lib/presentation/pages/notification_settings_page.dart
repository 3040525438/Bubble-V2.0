// 通知设置页（T13.3/T13.5，UI_PAGE_SPEC §22）：隐私三档 / 提醒类别 / 每日上限 /
// 通知勿扰 / 权限状态 / 待投递队列。依据 FR-IOS-05/08，默认 minimal。
import 'package:flutter/material.dart';

import '../../data/database/db_provider.dart';
import '../../data/notification/notification_runtime.dart';
import '../../data/notification/notification_scheduler.dart';
import '../../data/repositories/notification_repository.dart';
import '../../domain/notification/notification_models.dart';
import '../theme/bubble_colors.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({
    super.key,
    this.repository,
    this.scheduler,
    this.clock,
  });

  final NotificationRepository? repository;
  final NotificationScheduler? scheduler;
  final DateTime Function()? clock;

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  late final NotificationRepository _repo =
      widget.repository ??
      NotificationRuntime.dispatcher?.repository ??
      NotificationRepository(AppDb.instance);
  late final NotificationScheduler _scheduler =
      widget.scheduler ??
      NotificationRuntime.dispatcher?.scheduler ??
      const NoopNotificationScheduler();
  DateTime Function() get _clock => widget.clock ?? DateTime.now;

  static const _sampleText = '今天的云像棉花糖，你那边也在下雨吗？';

  NotificationSettings _settings = const NotificationSettings();
  bool _loading = true;
  bool _saving = false;
  bool _permissionEnabled = false;
  bool _requesting = false;
  bool _sendingTest = false;
  int _activeCount = 0;
  int _todayCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _repo.loadSettings();
    final enabled = await _scheduler.isEnabled();
    final now = _clock();
    final dayStart = DateTime(now.year, now.month, now.day);
    final active = await _repo.activeCount();
    final today = await _repo.countInWindow(
      startMs: dayStart.millisecondsSinceEpoch,
      endMs: dayStart.add(const Duration(days: 1)).millisecondsSinceEpoch,
    );
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _permissionEnabled = enabled;
      _activeCount = active;
      _todayCount = today;
      _loading = false;
    });
  }

  Future<void> _update(NotificationSettings next) async {
    setState(() {
      _settings = next;
      _saving = true;
    });
    await _repo.saveSettings(next);
    if (!mounted) return;
    setState(() => _saving = false);
  }

  Future<void> _requestPermission() async {
    setState(() => _requesting = true);
    final granted = await _scheduler.requestPermission();
    if (!mounted) return;
    setState(() {
      _requesting = false;
      _permissionEnabled = granted;
    });
    if (!granted && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('系统通知未开启，可在「设置 > 通知」里手动允许'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  /// 发送一条 3 秒后到达的测试通知（不依赖模型与主动行为评分）。
  /// 用于真机验证：权限、隐私档位渲染、通知点击深链。
  Future<void> _sendTestNotification() async {
    if (!_scheduler.supported) {
      _showToast('当前平台不支持本地通知（需 iOS / Android 真机）');
      return;
    }
    if (!await _scheduler.isEnabled()) {
      _showToast('通知权限未开启，请先点上面的「开启通知」');
      return;
    }
    setState(() => _sendingTest = true);
    try {
      final rendered = renderNotification(
        privacy: _settings.privacyMode,
        sourceLabel: '泡泡',
        messageText: '这是一条测试通知，点我会回到聊天。',
      );
      final now = _clock();
      await _scheduler.schedule(
        NotificationPlan(
          notificationId: 'test_${now.millisecondsSinceEpoch}',
          fireAt: now.add(const Duration(seconds: 3)),
          title: rendered.title,
          body: rendered.body,
          payload: const NotificationPayload(type: 'chat'),
        ),
      );
      if (!mounted) return;
      setState(() {
        _activeCount += 1;
        _todayCount += 1;
      });
      _showToast('已安排，3 秒后到达；请回到桌面查看，点击通知会打开聊天');
    } catch (e) {
      if (!mounted) return;
      _showToast('测试通知发送失败：$e');
    } finally {
      if (mounted) setState(() => _sendingTest = false);
    }
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _pickQuiet({required bool isStart}) async {
    final text = isStart ? _settings.quietStart : _settings.quietEnd;
    final parts = text.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts.first) ?? (isStart ? 23 : 8),
        minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
      ),
      helpText: isStart ? '通知勿扰开始' : '通知勿扰结束',
    );
    if (picked == null) return;
    final value =
        '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    await _update(
      isStart
          ? _settings.copyWith(quietStart: value)
          : _settings.copyWith(quietEnd: value),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '通知',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(right: 14),
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
              children: [
                _permissionCard(onSurface),
                const SizedBox(height: 16),
                _testCard(onSurface),
                const SizedBox(height: 16),
                _sectionTitle('通知里显示什么'),
                _privacyCard(onSurface),
                const SizedBox(height: 16),
                _sectionTitle('提醒类别'),
                _kindCard(onSurface),
                const SizedBox(height: 16),
                _sectionTitle('节奏'),
                _cadenceCard(onSurface),
                const SizedBox(height: 16),
                _queueCard(onSurface),
                const SizedBox(height: 16),
                _footnote(onSurface),
              ],
            ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: BubbleFontSize.bodySmall,
          fontWeight: FontWeight.w700,
          color: context.bubbleColors.lavenderDeep,
        ),
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        side: BorderSide(color: context.bubbleColors.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: child,
      ),
    );
  }

  /// 测试通知入口：真机自行验证权限 / 样式 / 点击跳转。
  Widget _testCard(Color onSurface) {
    final semantic = context.bubbleColors;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.science_outlined,
                size: 20,
                color: semantic.lavenderDeep,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '试一试',
                  style: TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    fontWeight: FontWeight.w600,
                    color: onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '发一条 3 秒后到达的测试通知，用来验证权限、隐私档位样式与点击跳转；'
            '不依赖模型配置，也不会产生聊天消息。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.5,
              color: onSurface.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              key: const ValueKey('notif-test-send'),
              onPressed: _sendingTest ? null : _sendTestNotification,
              child: Text(_sendingTest ? '安排中…' : '发送测试通知（3 秒后）'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _permissionCard(Color onSurface) {
    final semantic = context.bubbleColors;
    final supported = _scheduler.supported;
    final (title, detail, color) = !supported
        ? (
            '当前平台不支持本地通知',
            '通知能力在 iOS / Android 真机可用；桌面与测试环境不会假装已开启',
            onSurface.withValues(alpha: 0.55),
          )
        : _permissionEnabled
        ? ('通知已开启', '泡泡的主动消息会按你的隐私设置提醒你', semantic.lavenderDeep)
        : ('通知未开启', '主动消息仍会安静地留在聊天里，不会弹任何提醒', semantic.warnDeep);
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                supported
                    ? (_permissionEnabled
                          ? Icons.notifications_active_rounded
                          : Icons.notifications_off_outlined)
                    : Icons.notifications_paused_outlined,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: BubbleFontSize.cardTitle,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.5,
              color: onSurface.withValues(alpha: 0.5),
            ),
          ),
          if (supported && !_permissionEnabled) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                key: const ValueKey('notif-permission-action'),
                onPressed: _requesting ? null : _requestPermission,
                child: Text(_requesting ? '请求中…' : '开启通知'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _privacyCard(Color onSurface) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final mode in NotificationPrivacy.values) ...[
            InkWell(
              key: ValueKey('notif-privacy-${mode.wire}'),
              borderRadius: BorderRadius.circular(BubbleRadius.badge),
              onTap: () => _update(_settings.copyWith(privacyMode: mode)),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    Icon(
                      _settings.privacyMode == mode
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      size: 20,
                      color: _settings.privacyMode == mode
                          ? context.bubbleColors.lavenderDeep
                          : onSurface.withValues(alpha: 0.3),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mode.label,
                            style: TextStyle(
                              fontSize: BubbleFontSize.bodySmall,
                              fontWeight: FontWeight.w600,
                              color: onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            mode.description,
                            style: TextStyle(
                              fontSize: BubbleFontSize.badge,
                              color: onSurface.withValues(alpha: 0.45),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (mode != NotificationPrivacy.values.last)
              Divider(
                height: 1,
                color: context.bubbleColors.stroke.withValues(alpha: 0.5),
              ),
          ],
          const SizedBox(height: 10),
          _preview(onSurface),
        ],
      ),
    );
  }

  Widget _preview(Color onSurface) {
    final rendered = renderNotification(
      privacy: _settings.privacyMode,
      sourceLabel: '新消息',
      messageText: _sampleText,
    );
    final semantic = context.bubbleColors;
    return Container(
      key: const ValueKey('notif-preview'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: semantic.lavender,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text(
                    '泡',
                    style: TextStyle(
                      fontSize: 11,
                      color: semantic.lavenderDeep,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  rendered.title,
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    fontWeight: FontWeight.w600,
                    color: onSurface,
                  ),
                ),
              ),
              Text(
                '现在',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.35),
                ),
              ),
            ],
          ),
          if (rendered.body.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              rendered.body,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                height: 1.5,
                color: onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '以上是通知在锁屏上的样子（示例）',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _kindCard(Color onSurface) {
    return _card(
      child: Column(
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('notif-switch-post'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              '说说发布后提醒',
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                fontWeight: FontWeight.w600,
                color: onSurface,
              ),
            ),
            subtitle: Text(
              '泡泡自主发说说时通知你',
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.45),
              ),
            ),
            value: _settings.allowPostNotify,
            onChanged: (value) =>
                _update(_settings.copyWith(allowPostNotify: value)),
          ),
          Divider(height: 1, color: context.bubbleColors.stroke),
          SwitchListTile.adaptive(
            key: const ValueKey('notif-switch-diary'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              '日记与信件提醒',
              style: TextStyle(
                fontSize: BubbleFontSize.bodySmall,
                fontWeight: FontWeight.w600,
                color: onSurface,
              ),
            ),
            subtitle: Text(
              '整理好日记或写下信件时通知你',
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.45),
              ),
            ),
            value: _settings.allowDiaryLetterNotify,
            onChanged: (value) =>
                _update(_settings.copyWith(allowDiaryLetterNotify: value)),
          ),
        ],
      ),
    );
  }

  Widget _cadenceCard(Color onSurface) {
    final semantic = context.bubbleColors;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.event_repeat_rounded,
                size: 19,
                color: semantic.lavenderDeep,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '每日通知上限',
                  style: TextStyle(
                    fontSize: BubbleFontSize.bodySmall,
                    fontWeight: FontWeight.w600,
                    color: onSurface,
                  ),
                ),
              ),
              Text(
                '${_settings.dailyNotifyCap} 条',
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w700,
                  color: semantic.lavenderDeep,
                ),
              ),
            ],
          ),
          Slider(
            key: const ValueKey('notif-cap-slider'),
            value: _settings.dailyNotifyCap.toDouble().clamp(1, 20),
            min: 1,
            max: 20,
            divisions: 19,
            label: '${_settings.dailyNotifyCap} 条',
            onChanged: (value) {
              setState(() {
                _settings = _settings.copyWith(dailyNotifyCap: value.round());
              });
            },
            onChangeEnd: (_) => _update(_settings),
          ),
          _timeRow(
            icon: Icons.nightlight_round,
            title: '通知勿扰',
            value: '${_settings.quietStart} – ${_settings.quietEnd}',
            onTap: () => _pickQuiet(isStart: true),
            onValueTap: () => _pickQuiet(isStart: false),
            onSurface: onSurface,
          ),
          const SizedBox(height: 4),
          Text(
            '勿扰时段内到点的提醒会顺延到结束后再显示，不会在夜里亮屏。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.5,
              color: onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeRow({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
    required VoidCallback onValueTap,
    required Color onSurface,
  }) {
    final semantic = context.bubbleColors;
    return InkWell(
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 19, color: semantic.lavenderDeep),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w600,
                  color: onSurface,
                ),
              ),
            ),
            InkWell(
              onTap: onValueTap,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w700,
                  color: semantic.lavenderDeep,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: onSurface.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }

  Widget _queueCard(Color onSurface) {
    final semantic = context.bubbleColors;
    return _card(
      child: Row(
        children: [
          Icon(Icons.schedule_rounded, size: 20, color: semantic.lavenderDeep),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '待投递 ${_activeCount} / ${NotificationPolicy.queueLimit}',
                  style: TextStyle(
                    fontSize: BubbleFontSize.bodySmall,
                    fontWeight: FontWeight.w600,
                    color: onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '今天已安排 $_todayCount 条 · 队列不做无限堆积',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: onSurface.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footnote(Color onSurface) {
    return Text(
      '所有提醒都在这台设备上预排，不使用任何云推送服务，内容不会离开手机。'
      'App 被系统彻底关闭时 iOS 不会唤醒它，这是系统限制，不是泡泡「不想你」。',
      style: TextStyle(
        fontSize: BubbleFontSize.badge,
        height: 1.6,
        color: onSurface.withValues(alpha: 0.4),
      ),
    );
  }
}
