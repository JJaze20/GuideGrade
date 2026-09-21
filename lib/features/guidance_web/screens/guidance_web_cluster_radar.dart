import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/app_text_styles.dart';

/// One radar series: a fraction (0..1) per axis, in axis order. A null entry
/// means "no data for that axis" and the whole series is not drawn.
class ClusterRadarSeries {
  const ClusterRadarSeries({
    required this.label,
    required this.color,
    required this.fractions,
  });

  final String label;
  final Color color;
  final List<double?> fractions;

  bool get hasData => fractions.every((f) => f != null);
}

/// A dependency-free radar chart for the cluster analysis: one axis per
/// cluster, scaled 0–100% of that cluster's items so clusters of different
/// sizes are comparable.
class ClusterRadarChart extends StatelessWidget {
  const ClusterRadarChart({
    super.key,
    required this.axes,
    required this.series,
    this.size = const Size(380, 300),
  });

  final List<String> axes;
  final List<ClusterRadarSeries> series;
  final Size size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size.width,
      height: size.height,
      child: CustomPaint(painter: _RadarPainter(axes, series)),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.axes, this.series);

  final List<String> axes;
  final List<ClusterRadarSeries> series;

  @override
  void paint(Canvas canvas, Size size) {
    final n = axes.length;
    if (n < 3) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 46;

    Offset point(int i, double frac) {
      final angle = -math.pi / 2 + 2 * math.pi * i / n;
      return center + Offset(math.cos(angle), math.sin(angle)) * radius * frac;
    }

    final grid = Paint()
      ..color = const Color(0xFFD0D5DD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final ring in [0.25, 0.5, 0.75, 1.0]) {
      final path = Path()..moveTo(point(0, ring).dx, point(0, ring).dy);
      for (var i = 1; i < n; i++) {
        path.lineTo(point(i, ring).dx, point(i, ring).dy);
      }
      canvas.drawPath(path..close(), grid);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(center, point(i, 1), grid);
    }

    for (final s in series) {
      if (!s.hasData) continue;
      final path = Path();
      for (var i = 0; i < n; i++) {
        final p = point(i, s.fractions[i]!.clamp(0.0, 1.0));
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()..color = s.color.withValues(alpha: 0.25),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = s.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    for (var i = 0; i < n; i++) {
      final tp = TextPainter(
        text: TextSpan(
          text: axes[i],
          style: AppTextStyles.body(size: 10, weight: FontWeight.w600),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 96);
      final anchor = point(i, 1.0) +
          (point(i, 1.0) - center) / radius * 14; // push label outward
      canvas.save();
      final dx = (anchor.dx - tp.width / 2).clamp(0.0, size.width - tp.width);
      final dy = (anchor.dy - tp.height / 2).clamp(0.0, size.height - tp.height);
      tp.paint(canvas, Offset(dx, dy));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter old) =>
      old.axes != axes || old.series != series;
}
