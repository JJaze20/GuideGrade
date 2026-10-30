// Layout of the printed "shading sample" in each sheet's header: a "Correct
// shading" caption and a row of four answer bubbles, A B C D, with D fully
// shaded.
//
// One description of the shapes, shared by everything that needs them so they
// can never drift apart:
//   * generate_sheets.dart draws it on AT and QTM (via PdfGraphics),
//   * add_tat_v5_sample_shading.dart appends it to the TAT v5 PDF (raw PDF
//     operators),
//   * verify_sample_shading_clear.dart measures it against the scanner's
//     bubbles, marks and name crops.
//
// Everything here is in top-left page coordinates (points, y down) and is
// purely printed guidance -- nothing in lib/core/omr/ reads this area.
import 'dart:math' as math;

/// Axis-aligned box in top-left page coordinates (points).
class Box {
  Box(this.x0, this.y0, this.x1, this.y1);
  final double x0, y0, x1, y1;

  Box union(Box o) => Box(math.min(x0, o.x0), math.min(y0, o.y0), math.max(x1, o.x1), math.max(y1, o.y1));

  /// Gap between two boxes (0 when they touch or overlap).
  double gapTo(Box o) {
    final dx = math.max(0.0, math.max(o.x0 - x1, x0 - o.x1));
    final dy = math.max(0.0, math.max(o.y0 - y1, y0 - o.y1));
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Distance from the point ([px], [py]) to this box.
  double distanceToPoint(double px, double py) => gapTo(Box(px, py, px, py));
}

/// Measures [text] at [size] points in Helvetica (bold when [bold]).
typedef TextMeasure = double Function(String text, double size, bool bold);

sealed class ShadeShape {
  Box get bounds;
}

class ShadeText extends ShadeShape {
  ShadeText(this.x, this.baselineY, this.size, this.text, {required this.bold, required this.gray, required this.width});
  final double x, baselineY, size, width;
  final String text;
  final bool bold, gray;

  @override
  Box get bounds => Box(x, baselineY - size * 0.75, x + width, baselineY + size * 0.25);
}

class ShadeEllipse extends ShadeShape {
  ShadeEllipse(this.cx, this.cy, this.rx, this.ry, {required this.filled, this.lineWidth = 0});
  final double cx, cy, rx, ry;
  final bool filled;
  final double lineWidth;

  @override
  Box get bounds => Box(cx - rx, cy - ry, cx + rx, cy + ry);
}

/// Per-exam sizing: the caption text size and the bubble the sample copies.
class SampleShadingStyle {
  const SampleShadingStyle({required this.fontSize, required this.rx, required this.ry, required this.ringWidth});
  final double fontSize, rx, ry, ringWidth;

  /// AT / QTM: round bubbles of radius 6 (kBubbleRadius in generate_sheets.dart).
  static const at = SampleShadingStyle(fontSize: 8, rx: 6, ry: 6, ringWidth: 0.8);
  static const qtm = SampleShadingStyle(fontSize: 7, rx: 6, ry: 6, ringWidth: 0.8);

  /// TAT v5: oval bubbles (bubbleRadiusPt 8 x bubbleRadiusYPt 5.6).
  static const tat = SampleShadingStyle(fontSize: 7, rx: 8, ry: 5.6, ringWidth: 0.65);
}

const String sampleCaption = 'Correct shading';

/// The choices drawn, in order; the one in [sampleShadedChoice] is fully shaded.
const List<String> sampleChoices = ['A', 'B', 'C', 'D'];
const String sampleShadedChoice = 'D';

/// Size of the printed choice letters, same as the answer bubbles' own
/// (kLetterFontSize in generate_sheets.dart; the TAT sheet uses 6 too).
const double sampleLetterSize = 6;

const double _captionGap = 8; // caption -> first bubble
const double _bubbleGap = 5; // between neighbouring bubbles

/// Total width of the sample, so a caller can right-align it.
double sampleShadingWidth(SampleShadingStyle s, TextMeasure measure) {
  final caption = measure(sampleCaption, s.fontSize, false);
  return caption + _captionGap + sampleChoices.length * 2 * s.rx + (sampleChoices.length - 1) * _bubbleGap;
}

/// The sample's shapes with its left edge at [leftX] and the caption's text
/// baseline at [baselineY]. The bubbles are centred on the text's x-height.
/// Empty choices are rings with their letter, like the sheet's own bubbles;
/// the shaded one is a solid bubble (its letter is covered by the shading).
List<ShadeShape> buildSampleShading(SampleShadingStyle s, double leftX, double baselineY, TextMeasure measure) {
  final captionW = measure(sampleCaption, s.fontSize, false);
  final cy = baselineY - s.fontSize * 0.35;
  final shapes = <ShadeShape>[
    ShadeText(leftX, baselineY, s.fontSize, sampleCaption, bold: false, gray: true, width: captionW),
  ];

  var cursor = leftX + captionW + _captionGap;
  for (final choice in sampleChoices) {
    final cx = cursor + s.rx;
    if (choice == sampleShadedChoice) {
      shapes.add(ShadeEllipse(cx, cy, s.rx, s.ry, filled: true));
    } else {
      shapes.add(ShadeEllipse(cx, cy, s.rx, s.ry, filled: false, lineWidth: s.ringWidth));
      final w = measure(choice, sampleLetterSize, true);
      // Letter centred in the ring (cap height is ~0.72 of the font size).
      shapes.add(ShadeText(cx - w / 2, cy + sampleLetterSize * 0.36, sampleLetterSize, choice, bold: true, gray: false, width: w));
    }
    cursor += 2 * s.rx + _bubbleGap;
  }
  return shapes;
}

Box sampleBounds(List<ShadeShape> shapes) => shapes.map((s) => s.bounds).reduce((a, b) => a.union(b));
