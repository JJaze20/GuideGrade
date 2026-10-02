import 'dart:math' as math;

/// Contrast for a solid mark at a rotated paper edge. Sample its central
/// core and the brighter half of its surroundings, avoiding bounding-box
/// paper and the dark tabletop outside the sheet. Bounded to 33 pixels.
double tatCornerContrast({
  required int imageWidth,
  required int imageHeight,
  required double x,
  required double y,
  required double width,
  required double height,
  required double Function(int x, int y) grayAt,
}) {
  final cx = x + width / 2, cy = y + height / 2;
  double sample(double sx, double sy) => grayAt(
      sx.round().clamp(0, imageWidth - 1),
      sy.round().clamp(0, imageHeight - 1));
  final core = <double>[
    for (final dx in [-.15, 0.0, .15])
      for (final dy in [-.15, 0.0, .15]) sample(cx + dx * width, cy + dy * height),
  ]..sort();
  final surround = <double>[
    for (var i = 0; i < 24; i++)
      sample(cx + width * .9 * math.cos(i * math.pi / 12),
          cy + height * .9 * math.sin(i * math.pi / 12)),
  ]..sort();
  return surround[17] - core[4];
}

/// Only use a page-boundary prior when one was actually detected. It rules
/// out background marks without narrowing the no-boundary fallback search.
double? tatCornerAnchorRadius(int width, int height, bool hasPageBoundary) =>
    hasPageBoundary ? .08 * math.min(width, height) : null;
