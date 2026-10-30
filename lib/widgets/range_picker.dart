import 'package:flutter/material.dart';

import '../theme.dart';

/// A compact range calendar that drops out of the chip it belongs to.
///
/// `showDateRangePicker` takes over the whole screen on a phone, which turns a
/// two-tap decision into a journey. This keeps the dashboard visible behind it,
/// so the number you are filtering stays in sight while you pick.
Future<DateTimeRange?> showRangePopover(
  BuildContext context, {
  DateTimeRange? initial,
}) async {
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final Rect rect = box != null && overlay != null
      ? Rect.fromPoints(
          box.localToGlobal(Offset.zero, ancestor: overlay),
          box.localToGlobal(box.size.bottomRight(Offset.zero),
              ancestor: overlay),
        )
      : const Rect.fromLTWH(0, 0, 0, 0);

  return showMenu<DateTimeRange>(
    context: context,
    color: kSurface,
    elevation: 0,
    position: RelativeRect.fromRect(rect, Offset.zero & overlay!.size),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: kLine),
    ),
    items: [
      PopupMenuItem<DateTimeRange>(
        enabled: false,
        padding: EdgeInsets.zero,
        child: _Calendar(initial: initial),
      ),
    ],
  );
}

class _Calendar extends StatefulWidget {
  const _Calendar({this.initial});

  final DateTimeRange? initial;

  @override
  State<_Calendar> createState() => _CalendarState();
}

class _CalendarState extends State<_Calendar> {
  late DateTime _month;
  DateTime? _start;
  DateTime? _end;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final seed = widget.initial?.start ?? today;
    _month = DateTime(seed.year, seed.month);
    _start = widget.initial == null
        ? null
        : DateTime(widget.initial!.start.year, widget.initial!.start.month,
            widget.initial!.start.day);
    _end = widget.initial == null
        ? null
        : DateTime(widget.initial!.end.year, widget.initial!.end.month,
            widget.initial!.end.day);
  }

  static DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  void _pick(DateTime day) {
    setState(() {
      if (_start == null || _end != null) {
        _start = day;
        _end = null;
      } else if (day.isBefore(_start!)) {
        _end = _start;
        _start = day;
      } else {
        _end = day;
      }
    });
  }

  void _shift(int months) {
    setState(() => _month = DateTime(_month.year, _month.month + months));
  }

  @override
  Widget build(BuildContext context) {
    final today = _dayOf(DateTime.now());
    final first = DateTime(_month.year, _month.month, 1);
    // Monday-first grid, padded back to the Monday on or before the 1st.
    final lead = (first.weekday - DateTime.monday) % 7;
    final gridStart = first.subtract(Duration(days: lead));
    final canApply = _start != null;

    return SizedBox(
      width: 292,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StepButton(icon: Icons.chevron_left, onTap: () => _shift(-1)),
                Expanded(
                  child: Center(
                    child: Text(
                      '${_month.year} 年 ${_month.month} 月',
                      style: labelStyle(
                          color: kText, size: 12.5, weight: FontWeight.w600),
                    ),
                  ),
                ),
                _StepButton(icon: Icons.chevron_right, onTap: () => _shift(1)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
                  Expanded(
                    child: Center(
                      child:
                          Text(w, style: labelStyle(color: kFaint, size: 10.5)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (int week = 0; week < 6; week++)
              Row(
                children: [
                  for (int i = 0; i < 7; i++)
                    Expanded(
                      child: _cell(
                          gridStart.add(Duration(days: week * 7 + i)), today),
                    ),
                ],
              ),
            const SizedBox(height: 10),
            Text(
              _rangeLabel(),
              style: bodyStyle(color: kMuted, size: 11.5),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: kMuted,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
                  ),
                  child: const Text('取消', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: canApply
                      ? () => Navigator.of(context).pop(DateTimeRange(
                            start: _start!,
                            end: _end ?? _start!,
                          ))
                      : null,
                  style: TextButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('确定',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _rangeLabel() {
    String fmt(DateTime d) => '${d.month} 月 ${d.day} 日';
    if (_start == null) return '先选起始日期，再选结束日期';
    if (_end == null) return '从 ${fmt(_start!)} 起，再点一天作为结束';
    return '${fmt(_start!)} — ${fmt(_end!)}';
  }

  Widget _cell(DateTime day, DateTime today) {
    final inMonth = day.month == _month.month;
    final isStart = _start != null && day == _dayOf(_start!);
    final isEnd = _end != null && day == _dayOf(_end!);
    final inRange = _start != null &&
        _end != null &&
        day.isAfter(_dayOf(_start!)) &&
        day.isBefore(_dayOf(_end!));
    final selected = isStart || isEnd;
    final isToday = day == today;

    return Semantics(
      button: true,
      selected: selected,
      label: '${day.year} 年 ${day.month} 月 ${day.day} 日',
      child: GestureDetector(
        onTap: () => _pick(day),
        behavior: HitTestBehavior.opaque,
        child: Container(
          // A stable handle for tests: day numbers alone repeat across the
          // leading and trailing pad days of the neighbouring months.
          key: ValueKey('day-${day.year}-${day.month}-${day.day}'),
          height: 30,
          margin: const EdgeInsets.all(1),
          decoration: BoxDecoration(
            color: selected
                ? kAccent
                : inRange
                    ? kAccent.withOpacity(0.18)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: isToday && !selected
                ? Border.all(color: kAccent.withOpacity(0.55))
                : null,
          ),
          child: Center(
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 11.5,
                color: selected
                    ? Colors.white
                    : inMonth
                        ? kText
                        : kFaint,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 16,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 18, color: kMuted),
      ),
    );
  }
}
