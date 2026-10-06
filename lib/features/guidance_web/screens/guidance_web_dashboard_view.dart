import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../core/omr/qtm_category.dart';
import '../../../core/omr/tat_category.dart';
import '../../../shared/widgets/surface_card.dart';
import '../services/guidance_web_dashboard_service.dart';

class GuidanceWebDashboardView extends StatefulWidget {
  const GuidanceWebDashboardView({
    super.key,
    this.service,
    this.refreshInterval = const Duration(seconds: 30),
  });
  final GuidanceWebDashboardService? service;
  final Duration? refreshInterval;
  @override
  State<GuidanceWebDashboardView> createState() => _DashboardState();
}

class _DashboardState extends State<GuidanceWebDashboardView> {
  static const _statisticsExplanation =
      'Graded results linked to examinee records across all batches. Archived attempts and soft-deleted scans are excluded. Each result is counted once; an examinee may have results in more than one batch.';
  late final _service = widget.service ?? GuidanceWebDashboardService();
  late Future<GuidanceDashboardData> _data;
  Timer? _refreshTimer;
  bool _fetching = false;
  @override
  void initState() {
    super.initState();
    _data = _fetch();
    final interval = widget.refreshInterval;
    if (interval != null) {
      _refreshTimer = Timer.periodic(interval, (_) => _refresh());
    }
  }

  Future<GuidanceDashboardData> _fetch() async {
    _fetching = true;
    try {
      return await _service.load();
    } finally {
      _fetching = false;
    }
  }

  Future<void> _refresh() async {
    if (_fetching) return;
    try {
      final next = await _fetch();
      if (mounted) {
        setState(() {
          _data = Future.value(next);
        });
      }
    } catch (_) {
      // Keep the last chart snapshot; the next background check retries.
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _reload() {
    if (_fetching) return;
    final next = _fetch();
    setState(() {
      _data = next;
    });
  }

  void _showStatisticsInformation() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About these statistics'),
        content: const Text(_statisticsExplanation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: EdgeInsets.all(
      AppSpace.gutterFor(MediaQuery.sizeOf(context).width),
    ),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1440),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF14243D), Color(0xFF254B62)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Examination overview',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Compare result distributions across the three examinations.',
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: const Color(0xFFCDDBEA),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (widget.refreshInterval != null)
                        const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.sync,
                              size: 16,
                              color: Color(0xFF99E2B0),
                            ),
                            SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Updates automatically',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: const Color(0xFFCDDBEA),
                                ),
                              ),
                            ),
                          ],
                        ),
                      IconButton(
                        tooltip: 'About these statistics',
                        onPressed: _showStatisticsInformation,
                        icon: const Icon(
                          Icons.info_outline,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            const SizedBox(height: 20),
            FutureBuilder<GuidanceDashboardData>(
              future: _data,
              builder: (context, snapshot) {
                final loading =
                    !snapshot.hasData &&
                    snapshot.connectionState != ConnectionState.done;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (loading)
                      const Padding(
                        padding: EdgeInsets.all(32),
                        child: Column(
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('Loading examination statistics…'),
                          ],
                        ),
                      )
                    else if (snapshot.hasError)
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Column(
                          children: [
                            const Icon(Icons.cloud_off_outlined, size: 32),
                            const SizedBox(height: 12),
                            const Text(
                              'Statistics could not be loaded. Please check your connection and try again.',
                            ),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _reload,
                              child: const Text('Try again'),
                            ),
                          ],
                        ),
                      )
                    else
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final charts = snapshot.data!.charts;
                          return Column(
                            children: [
                              for (final chart in charts)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 16),
                                  child: _ChartCard(data: chart),
                                ),
                            ],
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.data});
  final DashboardDistribution data;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    key: ValueKey('dashboard.chart.${data.title}'),
    color: switch (data.title) {
      'Admission Test' => const Color(0xFFEDF3FC),
      'QTM' => const Color(0xFFEDF6F1),
      _ => const Color(0xFFF4F0FA),
    },
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          data.title,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF14243D),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${data.total} graded results',
          style: const TextStyle(fontSize: 14, color: AppColors.textGray),
        ),
        if (data.total == 0)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'No eligible results yet. Counts will appear here after results are graded and linked.',
            ),
          ),
        const SizedBox(height: 16),
        const Text(
          'Number of results',
          style: TextStyle(fontSize: 12, color: AppColors.textGray),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 250,
          child: Semantics(
            label:
                '${data.title}: ${[for (var i = 0; i < data.labels.length; i++) '${data.title == 'Admission Test' ? 'Category ' : ''}${data.labels[i]}: ${data.counts[i]} results'].join(', ')}',
            child: CustomPaint(painter: _BarPainter(data)),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            data.title == 'Admission Test'
                ? 'Admission category'
                : 'Score range',
            style: const TextStyle(fontSize: 12, color: AppColors.textGray),
          ),
        ),
      ],
    ),
  );
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.data);
  final DashboardDistribution data;

  // Category colors, as on the result analytics (A, B, C, D).
  static const _categoryColors = [
    Color(0xFFEF4444),
    Color(0xFFFFB000),
    Color(0xFF4A7AF5),
    Color(0xFF10B981),
  ];

  /// Category colour for bar [i]: by letter for the Admission Test, otherwise
  /// by the category the score range's midpoint falls in (the unclassified
  /// gap counts as A).
  Color _barColor(int i) {
    final label = data.labels[i];
    if (data.title == 'Admission Test') {
      final index = 'ABCD'.indexOf(label);
      return index < 0 ? AppColors.primaryGreen : _categoryColors[index];
    }
    final match = RegExp(r'(\d+)–(\d+)').firstMatch(label);
    if (match == null) return AppColors.primaryGreen;
    final mid = (int.parse(match.group(1)!) + int.parse(match.group(2)!)) ~/ 2;
    final index = switch (data.title) {
      'QTM' => qtmCategory(mid)?.index ?? 0,
      'TAT' => tatCategory(mid)?.index ?? 0,
      _ => -1,
    };
    return index < 0 ? AppColors.primaryGreen : _categoryColors[index];
  }

  void _text(
    Canvas canvas,
    String text,
    Offset offset, {
    bool centered = false,
    double fontSize = 12,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, color: AppColors.textDark),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      centered ? offset - Offset(painter.width / 2, 0) : offset,
    );
    painter.dispose();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 32.0, top = 24.0, bottom = 60.0;
    final height = size.height - top - bottom;
    final plotWidth = size.width - left - 10;
    final maxCount = data.counts.fold<int>(0, math.max);
    final step = math.max(1, (maxCount / 4).ceil());
    final ceiling = step * 4;
    for (var tick = 0; tick <= 4; tick++) {
      final y = top + height - height * tick / 4;
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width - 10, y),
        Paint()..color = AppColors.cardBorder,
      );
      _text(canvas, '${tick * step}', Offset(0, y - 7));
    }
    canvas.drawLine(
      const Offset(left, top),
      Offset(left, top + height),
      Paint()..color = AppColors.textGray,
    );
    final slot = plotWidth / data.labels.length;
    // Keep each range intact; stagger crowded labels instead of splitting it.
    final staggerLabels = data.labels.any((label) {
      final measurement = TextPainter(
        text: TextSpan(text: label, style: const TextStyle(fontSize: 13)),
        textDirection: TextDirection.ltr,
      )..layout();
      final crowded = measurement.width + 6 > slot;
      measurement.dispose();
      return crowded;
    });
    for (var i = 0; i < data.labels.length; i++) {
      final x = left + slot * (i + 0.5);
      final barHeight = height * data.counts[i] / ceiling;
      final bar = Rect.fromLTWH(
        x - math.min(64.0, slot * .52) / 2,
        top + height - barHeight,
        math.min(64.0, slot * .52),
        barHeight,
      );
      if (barHeight > 0)
        canvas.drawRRect(
          RRect.fromRectAndRadius(bar, const Radius.circular(5)),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _barColor(i),
                Color.lerp(_barColor(i), const Color(0xFF14243D), 0.18)!,
              ],
            ).createShader(bar),
        );
      _text(
        canvas,
        '${data.counts[i]}',
        Offset(x, top + height - barHeight - 19),
        centered: true,
        fontSize: 13,
      );
      _text(
        canvas,
        data.labels[i],
        Offset(x, top + height + 12 + (staggerLabels && i.isOdd ? 20 : 0)),
        centered: true,
        fontSize: 13,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter oldDelegate) =>
      oldDelegate.data != data;
}
