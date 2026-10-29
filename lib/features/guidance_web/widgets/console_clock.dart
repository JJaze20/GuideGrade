import 'dart:async';

import 'package:flutter/material.dart';

import 'console_style.dart';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "Thursday, October 29, 2026".
String formatConsoleDate(DateTime t) =>
    '${_weekdays[t.weekday - 1]}, ${_months[t.month - 1]} ${t.day}, ${t.year}';

/// "2:35:09 PM" (12-hour clock with seconds, no leading zero on the hour).
String formatConsoleTime(DateTime t) {
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  final second = t.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second ${t.hour < 12 ? 'AM' : 'PM'}';
}

/// Arranges the date and the time (each already styled, with its icon) inside
/// the top bar.
typedef ConsoleClockLayout =
    Widget Function(BuildContext context, Widget date, Widget time);

/// The current date and time (with seconds) for the console's top bar, in the
/// viewer's own time zone. Ticks every second. The date and the time use the
/// same text style; [layout] decides where each one sits. [clock] is only
/// replaced in tests.
class ConsoleClock extends StatefulWidget {
  const ConsoleClock({
    super.key,
    required this.layout,
    this.clock = DateTime.now,
  });

  final ConsoleClockLayout layout;
  final DateTime Function() clock;

  @override
  State<ConsoleClock> createState() => _ConsoleClockState();
}

class _ConsoleClockState extends State<ConsoleClock> {
  late DateTime _now = widget.clock();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = widget.clock();
      if (next.second != _now.second ||
          next.minute != _now.minute ||
          next.hour != _now.hour ||
          next.day != _now.day) {
        setState(() => _now = next);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // One style for both, so the date and the time are the same size.
    final style = ConsoleText.body(
      size: 15,
      weight: FontWeight.w600,
      color: ConsoleColors.onGreen,
    );
    final date = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.calendar_today_outlined,
          size: 18,
          color: ConsoleColors.mint,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            formatConsoleDate(_now),
            key: const Key('consoleClockDate'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
    final time = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.schedule, size: 18, color: ConsoleColors.mint),
        const SizedBox(width: 10),
        Text(
          formatConsoleTime(_now),
          key: const Key('consoleClockTime'),
          style: style.copyWith(
            // Same-width digits, so the clock does not jiggle as it ticks.
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
    return widget.layout(context, date, time);
  }
}
