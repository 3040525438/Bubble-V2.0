// 日记列表（T11.1）：列表/月历双态、来源徽章、搜索与「整理今天」。
// 依据 UI_PAGE_SPEC §16/§33、REQUIREMENTS FR-DIA-01。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/database/app_database.dart';
import '../../data/database/db_provider.dart';
import '../../data/diary/diary_generator.dart';
import '../../data/repositories/diary_repository.dart';
import '../../domain/diary/diary_models.dart';
import '../theme/bubble_colors.dart';
import '../widgets/memory/memory_common.dart';

enum _DiaryViewMode { list, calendar }

class DiaryPage extends StatefulWidget {
  const DiaryPage({super.key, this.repository, this.generator});

  final DiaryRepository? repository;
  final DiaryGenerator? generator;

  @override
  State<DiaryPage> createState() => _DiaryPageState();
}

class _DiaryPageState extends State<DiaryPage> {
  late final DiaryRepository _repo =
      widget.repository ?? DiaryRepository(AppDb.instance);
  late final DiaryGenerator _generator =
      widget.generator ?? DiaryGenerator(AppDb.instance, repository: _repo);

  final TextEditingController _searchController = TextEditingController();

  List<Diary> _rows = const <Diary>[];
  bool _loading = true;
  bool _organizing = false;
  bool _calendarInitialized = false;
  String _keyword = '';
  _DiaryViewMode _mode = _DiaryViewMode.list;
  DateTime _calendarMonth = DateTime.now();
  int? _selectedDay;

  @override
  void initState() {
    super.initState();
    _calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
    _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final rows = await _repo.listDiaries(keyword: _keyword);
    if (!mounted) return;
    if (!_calendarInitialized && rows.isNotEmpty) {
      // 首次进入时把月历定位到最近有日记的月份
      final newest = DiaryRules.parseDateKey(rows.first.entryDate);
      if (newest != null) {
        _calendarMonth = DateTime(newest.year, newest.month);
      }
      _calendarInitialized = true;
    }
    setState(() {
      _rows = rows;
      _loading = false;
      _selectedDay ??= _defaultSelectedDay(rows);
    });
  }

  int? _defaultSelectedDay(List<Diary> rows) {
    final prefix =
        '${_calendarMonth.year}-'
        '${_calendarMonth.month.toString().padLeft(2, '0')}-';
    final today = DateTime.now();
    final sameMonth =
        today.year == _calendarMonth.year &&
        today.month == _calendarMonth.month;
    if (sameMonth &&
        rows.any((row) => row.entryDate == DiaryRules.dateKey(today))) {
      return today.day;
    }
    for (final row in rows) {
      if (row.entryDate.startsWith(prefix)) {
        return DiaryRules.parseDateKey(row.entryDate)?.day;
      }
    }
    return null;
  }

  Future<void> _organizeToday() async {
    if (_organizing) return;
    setState(() => _organizing = true);
    try {
      final draft = await _generator.generate();
      if (!mounted) return;
      final controller = TextEditingController(text: draft.content);
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) {
          final semantic = context.bubbleColors;
          return AlertDialog(
            title: const Text('整理今天的日记'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MemoryBadge(
                    text: draft.fromModel ? '模型整理' : '本地整理',
                    color: draft.fromModel
                        ? semantic.successDeep
                        : semantic.warnDeep,
                    background:
                        (draft.fromModel ? semantic.success : semantic.warn)
                            .withValues(alpha: 0.15),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: controller,
                    minLines: 6,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '整理结果可以逐字修改',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '只依据今天的真实聊天与记忆整理；未配置模型时是本地整理，不会冒充模型内容。',
                    style: TextStyle(
                      fontSize: BubbleFontSize.badge,
                      height: 1.4,
                      color: semantic.lavenderDeep,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
      if (saved == true) {
        final content = controller.text.trim();
        if (content.isNotEmpty) {
          await _generator.save(
            DiaryGeneratedDraft(
              content: content,
              fromModel: draft.fromModel,
              relatedMessageIds: draft.relatedMessageIds,
              relatedMemoryIds: draft.relatedMemoryIds,
            ),
          );
          await _reload();
          if (!mounted) return;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('已写进今天的日记'),
                behavior: SnackBarBehavior.floating,
              ),
            );
        }
      }
      controller.dispose();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('整理失败：$error')));
    } finally {
      if (mounted) setState(() => _organizing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日记与信件'),
        actions: [
          IconButton(
            key: const ValueKey('diary-organize-today'),
            tooltip: '整理今天',
            onPressed: _organizing ? null : _organizeToday,
            icon: _organizing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_rounded),
          ),
          IconButton(
            tooltip: '信件',
            onPressed: () => context.push('/letters'),
            icon: const Icon(Icons.mail_outline_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 30),
        children: [
          Row(
            children: [
              _segment(context, onSurface, _DiaryViewMode.list, '列表'),
              const SizedBox(width: 8),
              _segment(context, onSurface, _DiaryViewMode.calendar, '月历'),
              const Spacer(),
              Text(
                '${_rows.length} 篇',
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  color: onSurface.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('diary-search'),
            controller: _searchController,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              hintText: '搜索日记内容',
              border: const OutlineInputBorder(),
              suffixIcon: _keyword.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _keyword = '');
                        _reload();
                      },
                    ),
            ),
            onSubmitted: (value) {
              setState(() => _keyword = value.trim());
              _reload();
            },
          ),
          const SizedBox(height: 14),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 40),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_rows.isEmpty)
            MemoryEmptyCard(
              title: _keyword.isEmpty ? '还没有日记' : '没有找到相关日记',
              subtitle: _keyword.isEmpty
                  ? '一天结束的时候，泡泡会把聊天与记忆整理成日记；'
                        '你也可以自己补写一篇。'
                  : '换一个关键词试试，或清空搜索查看全部日记。',
            )
          else if (_mode == _DiaryViewMode.list)
            ..._listView()
          else
            ..._calendarView(onSurface),
          const SizedBox(height: 12),
          Text(
            '删除的日记会保留 30 天，之后可在数据中心恢复或清理。',
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

  Widget _segment(
    BuildContext context,
    Color onSurface,
    _DiaryViewMode mode,
    String label,
  ) {
    final semantic = context.bubbleColors;
    final selected = _mode == mode;
    return InkWell(
      key: ValueKey('diary-view-${mode.name}'),
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: () {
        setState(() {
          _mode = mode;
          _selectedDay ??= _defaultSelectedDay(_rows);
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? semantic.lavender.withValues(alpha: 0.24)
              : semantic.surfaceAlt.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
          border: Border.all(
            color: selected ? semantic.lavenderDeep : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? semantic.lavenderDeep : onSurface,
          ),
        ),
      ),
    );
  }

  List<Widget> _listView() {
    final groups = <String, List<Diary>>{};
    for (final row in _rows) {
      final parsed = DiaryRules.parseDateKey(row.entryDate);
      if (parsed == null) continue;
      final key = '${parsed.year}-${parsed.month}';
      groups.putIfAbsent(key, () => <Diary>[]).add(row);
    }
    final widgets = <Widget>[];
    for (final entry in groups.entries) {
      final parts = entry.key.split('-');
      final month = int.parse(parts[1]);
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8, top: 4),
          child: Row(
            children: [
              MemoryBadge(
                text: '$month月 · ${entry.value.length} 篇',
                color: context.bubbleColors.lavenderDeep,
                background: context.bubbleColors.lavender.withValues(
                  alpha: 0.18,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Divider(color: context.bubbleColors.stroke)),
            ],
          ),
        ),
      );
      for (final row in entry.value) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _DiaryCard(
              diary: row,
              onTap: () async {
                await context.push('/diary/${row.id}');
                await _reload();
              },
            ),
          ),
        );
      }
    }
    return widgets;
  }

  List<Widget> _calendarView(Color onSurface) {
    final semantic = context.bubbleColors;
    final prefix =
        '${_calendarMonth.year}-'
        '${_calendarMonth.month.toString().padLeft(2, '0')}-';
    final marks = <int, DiaryDayMark>{};
    for (final row in _rows) {
      if (!row.entryDate.startsWith(prefix)) continue;
      final day = DiaryRules.parseDateKey(row.entryDate)?.day;
      if (day == null) continue;
      final origin = DiaryOrigin.fromWire(row.origin);
      final previous = marks[day];
      marks[day] = DiaryDayMark(
        dateKey: row.entryDate,
        origin:
            previous?.origin == DiaryOrigin.manual ||
                origin == DiaryOrigin.manual
            ? DiaryOrigin.manual
            : DiaryOrigin.aiOrganized,
        count: (previous?.count ?? 0) + 1,
      );
    }
    final daysInMonth = DateTime(
      _calendarMonth.year,
      _calendarMonth.month + 1,
      0,
    ).day;
    final offset =
        DateTime(_calendarMonth.year, _calendarMonth.month, 1).weekday - 1;
    final selectedDay = _selectedDay;
    final dayRows = selectedDay == null
        ? const <Diary>[]
        : _rows
              .where(
                (row) =>
                    row.entryDate ==
                    '$prefix${selectedDay.toString().padLeft(2, '0')}',
              )
              .toList();

    return <Widget>[
      Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(BubbleRadius.card),
          border: Border.all(color: semantic.stroke),
        ),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '上个月',
                  onPressed: () => _changeMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                ),
                Expanded(
                  child: Text(
                    '${_calendarMonth.year}年${_calendarMonth.month}月',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: BubbleFontSize.cardTitle,
                      fontWeight: FontWeight.w700,
                      color: onSurface,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下个月',
                  onPressed: () => _changeMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                ),
              ],
            ),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.05,
              children: [
                for (final label in const ['一', '二', '三', '四', '五', '六', '日'])
                  Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: BubbleFontSize.badge,
                        color: onSurface.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                for (var i = 0; i < offset; i++) const SizedBox.shrink(),
                for (var day = 1; day <= daysInMonth; day++)
                  _dayCell(context, day, marks[day], selectedDay),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 10,
              children: [
                _legend(context, semantic.lavender, 'AI 整理'),
                _legend(context, semantic.pinkDeep, '你补写'),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      if (dayRows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text(
            selectedDay == null ? '这个月还没有日记' : '这一天还没有日记',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: BubbleFontSize.badge,
              color: onSurface.withValues(alpha: 0.4),
            ),
          ),
        )
      else
        for (final row in dayRows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _DiaryCard(
              diary: row,
              onTap: () async {
                await context.push('/diary/${row.id}');
                await _reload();
              },
            ),
          ),
    ];
  }

  Widget _dayCell(
    BuildContext context,
    int day,
    DiaryDayMark? mark,
    int? selectedDay,
  ) {
    final semantic = context.bubbleColors;
    final selected = selectedDay == day;
    return InkWell(
      key: ValueKey('diary-day-$day'),
      borderRadius: BorderRadius.circular(BubbleRadius.badge),
      onTap: mark == null ? null : () => setState(() => _selectedDay = day),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: selected ? semantic.bubbleUserA : Colors.transparent,
          borderRadius: BorderRadius.circular(BubbleRadius.badge),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$day',
              style: TextStyle(
                fontSize: BubbleFontSize.secondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: mark == null ? 0.45 : 0.85),
              ),
            ),
            const SizedBox(height: 2),
            if (mark != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: mark.origin == DiaryOrigin.manual
                          ? semantic.pinkDeep
                          : semantic.lavenderDeep,
                    ),
                  ),
                  if (mark.count > 1) ...[
                    const SizedBox(width: 2),
                    Text(
                      '${mark.count}',
                      style: TextStyle(
                        fontSize: 8,
                        color: selected
                            ? Colors.white
                            : Theme.of(context).colorScheme.onSurface
                                  .withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: BubbleFontSize.badge,
            color: Theme.of(context).colorScheme.onSurface
                .withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  void _changeMonth(int delta) {
    setState(() {
      _calendarMonth = DateTime(
        _calendarMonth.year,
        _calendarMonth.month + delta,
      );
      _selectedDay = _defaultSelectedDay(_rows);
    });
  }
}

class _DiaryCard extends StatelessWidget {
  const _DiaryCard({required this.diary, required this.onTap});

  final Diary diary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final semantic = context.bubbleColors;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final origin = DiaryOrigin.fromWire(diary.origin);
    final title = DiaryRules.deriveTitle(diary.content);
    final summary = diary.content.replaceAll(RegExp(r'\s+'), ' ').trim();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(BubbleRadius.card),
      child: InkWell(
        borderRadius: BorderRadius.circular(BubbleRadius.card),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: BubbleFontSize.cardTitle,
                        fontWeight: FontWeight.w700,
                        color: onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  MemoryBadge(
                    text: origin.label,
                    color: origin == DiaryOrigin.manual
                        ? semantic.successDeep
                        : semantic.lavenderDeep,
                    background:
                        (origin == DiaryOrigin.manual
                                ? semantic.success
                                : semantic.lavender)
                            .withValues(alpha: 0.16),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${DiaryRules.displayDate(diary.entryDate)} · $summary',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: BubbleFontSize.badge,
                  height: 1.5,
                  color: onSurface.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
