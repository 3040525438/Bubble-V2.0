// 设置主页（T8.3）：泡泡的主动性分组（三档 / 勿扰 / 上限 / 间隔 / 硬限制说明）。
// 依据 UI_PAGE_SPEC §22、REQUIREMENTS FR-SET-01/02；通知与数据分组在阶段 13/14 补齐。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/db_provider.dart';
import '../../data/repositories/proactive_repository.dart';
import '../../domain/proactive/proactive_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.repository});

  final ProactiveRepository? repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final ProactiveRepository _repo =
      widget.repository ?? ProactiveRepository(AppDb.instance);

  ProactiveSettings _settings = const ProactiveSettings();
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _repo.loadSettings();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loading = false;
    });
  }

  Future<void> _update(ProactiveSettings next) async {
    setState(() {
      _settings = next;
      _saving = true;
    });
    await _repo.saveSettings(next);
    if (!mounted) return;
    setState(() => _saving = false);
  }

  Future<void> _pickQuietTime({required bool isStart}) async {
    final text = isStart ? _settings.quietStart : _settings.quietEnd;
    final parts = text.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? (isStart ? 23 : 8),
      minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0,
    );
    final picked = await showTimePicker(
      context: context,
      initialTime: initial,
      helpText: isStart ? '选择勿扰开始时间' : '选择勿扰结束时间',
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
        title: const Text('设置'),
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
                _sectionTitle(context, '泡泡的主动性'),
                _proactivityCard(context, onSurface),
                const SizedBox(height: 18),
                _sectionTitle(context, '通知（阶段 13 开放）'),
                _placeholderCard(
                  context,
                  onSurface,
                  icon: Icons.notifications_none_rounded,
                  title: '通知隐私与提醒',
                  subtitle: '本地通知预排、隐私三档与说说/日记提醒',
                ),
                const SizedBox(height: 18),
                _sectionTitle(context, '模型与数据'),
                _entryCard(
                  context,
                  onSurface,
                  icon: Icons.memory_rounded,
                  title: '模型管理',
                  subtitle: '接入 DeepSeek、查看 Token 用量',
                  onTap: () => context.push('/models'),
                ),
                _placeholderCard(
                  context,
                  onSurface,
                  icon: Icons.folder_open_rounded,
                  title: '数据中心',
                  subtitle: '备份、恢复与完整性检查（阶段 14 开放）',
                ),
              ],
            ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
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

  Widget _proactivityCard(BuildContext context, Color onSurface) {
    final semantic = context.bubbleColors;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        side: BorderSide(color: semantic.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '主动程度',
                    style: TextStyle(
                      fontSize: BubbleFontSize.cardTitle,
                      fontWeight: FontWeight.w600,
                      color: onSurface,
                    ),
                  ),
                ),
                Text(
                  '默认「积极」',
                  style: TextStyle(
                    fontSize: BubbleFontSize.badge,
                    color: onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                for (final level in ProactivityLevel.values) ...[
                  Expanded(child: _levelChip(context, level, onSurface)),
                  if (level != ProactivityLevel.values.last)
                    const SizedBox(width: 8),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _settings.level.description,
              style: TextStyle(
                fontSize: BubbleFontSize.badge,
                color: onSurface.withValues(alpha: 0.55),
              ),
            ),
            const Divider(height: 22),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '允许泡泡主动找我',
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w600,
                  color: onSurface,
                ),
              ),
              subtitle: Text(
                '关闭后任何候选都不会执行（硬限制，优先级最高）',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.45),
                ),
              ),
              value: _settings.enabled,
              onChanged: (value) => _update(_settings.copyWith(enabled: value)),
            ),
            _rowTile(
              context,
              onSurface,
              icon: Icons.nightlight_round,
              title: '勿扰时段',
              value: '${_settings.quietStart} – ${_settings.quietEnd}',
              onTap: () => _pickQuietTime(isStart: true),
              trailingTap: () => _pickQuietTime(isStart: false),
            ),
            const SizedBox(height: 6),
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
                    '每日主动上限',
                    style: TextStyle(
                      fontSize: BubbleFontSize.bodySmall,
                      fontWeight: FontWeight.w600,
                      color: onSurface,
                    ),
                  ),
                ),
                Text(
                  '${_settings.effectiveDailyCap} 次',
                  style: TextStyle(
                    fontSize: BubbleFontSize.bodySmall,
                    color: semantic.lavenderDeep,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Slider(
              value: _settings.effectiveDailyCap.toDouble().clamp(1, 10),
              min: 1,
              max: 10,
              divisions: 9,
              label: '${_settings.effectiveDailyCap} 次',
              onChanged: (value) {
                setState(() {
                  _settings = _settings.copyWith(dailyCap: value.round());
                });
              },
              onChangeEnd: (_) => _update(_settings),
            ),
            Row(
              children: [
                Icon(
                  Icons.timer_outlined,
                  size: 19,
                  color: semantic.lavenderDeep,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '最短间隔',
                    style: TextStyle(
                      fontSize: BubbleFontSize.bodySmall,
                      fontWeight: FontWeight.w600,
                      color: onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final minutes in const [30, 60, 90, 120])
                  _intervalChip(context, minutes, onSurface),
              ],
            ),
            const SizedBox(height: 12),
            _hardLimitNote(context, onSurface),
            const SizedBox(height: 10),
            _entryCard(
              context,
              onSurface,
              icon: Icons.history_rounded,
              title: '主动行为记录',
              subtitle: '候选池、执行留痕与反馈',
              onTap: () => context.push('/proactive'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _levelChip(
    BuildContext context,
    ProactivityLevel level,
    Color onSurface,
  ) {
    final semantic = context.bubbleColors;
    final selected = _settings.level == level;
    return Semantics(
      button: true,
      selected: selected,
      label: '主动程度 ${level.label}',
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.button),
        onTap: () => _update(_settings.copyWith(level: level)),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? semantic.lavender.withValues(alpha: 0.35)
                : semantic.surfaceAlt.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(BubbleRadius.button),
            border: Border.all(
              color: selected ? semantic.lavenderDeep : Colors.transparent,
              width: selected ? 1.5 : 0,
            ),
          ),
          child: Text(
            level.label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: BubbleFontSize.bodySmall,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? semantic.lavenderDeep : onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _intervalChip(BuildContext context, int minutes, Color onSurface) {
    final semantic = context.bubbleColors;
    final selected = _settings.effectiveMinIntervalMinutes == minutes;
    return InkWell(
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: () => _update(_settings.copyWith(minIntervalMinutes: minutes)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? semantic.lavender.withValues(alpha: 0.3)
              : semantic.surfaceAlt.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
        ),
        child: Text(
          minutes >= 60 ? '${minutes ~/ 60} 小时' : '$minutes 分钟',
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: FontWeight.w600,
            color: selected ? semantic.lavenderDeep : onSurface,
          ),
        ),
      ),
    );
  }

  Widget _hardLimitNote(BuildContext context, Color onSurface) {
    final semantic = context.bubbleColors;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: semantic.warn.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(BubbleRadius.badge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '硬限制始终生效',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              fontWeight: FontWeight.w700,
              color: semantic.warnDeep,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '无论选哪一档，勿扰时段、同类冷却、重复检测、每日上限、最短间隔与「保持安静」决策都不会被任何候选绕过。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.5,
              color: onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowTile(
    BuildContext context,
    Color onSurface, {
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
    VoidCallback? trailingTap,
  }) {
    final semantic = context.bubbleColors;
    return InkWell(
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              icon,
              size: 19,
              color: trailingTap == null
                  ? semantic.lavenderDeep
                  : semantic.lavenderDeep,
            ),
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
              onTap: trailingTap,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  color: semantic.lavenderDeep,
                  fontWeight: FontWeight.w700,
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

  Widget _placeholderCard(
    BuildContext context,
    Color onSurface, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Opacity(
      opacity: 0.55,
      child: _entryCard(
        context,
        onSurface,
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: null,
      ),
    );
  }

  Widget _entryCard(
    BuildContext context,
    Color onSurface, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final semantic = context.bubbleColors;
    return Material(
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
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: BubbleFontSize.cardTitle,
                        fontWeight: FontWeight.w600,
                        color: onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        color: onSurface.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
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
      ),
    );
  }
}

/// 供决策中心页复用的「泡泡什么时候会主动？」说明卡
class ProactiveExplainCard extends StatelessWidget {
  const ProactiveExplainCard({super.key});

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.surfaceAlt.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(BubbleRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: semantic.lavenderDeep,
              ),
              const SizedBox(width: 8),
              Text(
                '泡泡什么时候会主动？',
                style: TextStyle(
                  fontSize: BubbleFontSize.bodySmall,
                  fontWeight: FontWeight.w700,
                  color: onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '泡泡会先产生候选（想聊天、想发说说、想写日记或只想安静陪着你），'
            '再由决策中心统一判断。只有同时满足勿扰时段之外、同类冷却已过、'
            '内容不重复、今日次数未到上限、距上次主动够久，才会真正执行。'
            'App 被系统彻底关闭时 iOS 不会唤醒它，这是系统限制，不是泡泡"不想你"。',
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              height: 1.6,
              color: onSurface.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 硬限制徽章行（决策中心页复用）
class HardLimitRow extends StatelessWidget {
  const HardLimitRow({super.key, required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final label in labels)
          MemoryBadge(
            text: label,
            color: context.bubbleColors.warnDeep,
            background: context.bubbleColors.warn.withValues(alpha: 0.15),
          ),
      ],
    );
  }
}
