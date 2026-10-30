// Pure-Dart check that the printed shading sample (a "Correct shading" caption
// and four bubbles, A B C D, with D fully shaded -- drawn on every sheet's
// header) cannot disturb scanning: it is located from the
// real PDFs and measured against everything the decoder reads in
// lib/core/omr/ (answer bubbles, corner and interior marks, name-field crops).
// Run from the repository root:
//
//   cd tool && dart run verify_sample_shading_clear.dart
//
// It only measures; it does not prove a phone capture still decodes -- test a
// printed sheet on a device after any sheet change.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:pdf/pdf.dart';

import 'sample_shading.dart';

/// Decoded content of every stream in the PDF, in file order.
List<String> streamsOf(List<int> bytes) {
  final s = latin1.decode(bytes);
  final out = <String>[];
  var i = 0;
  while (true) {
    final k = s.indexOf('stream', i);
    if (k < 0) break;
    if (k >= 3 && s.substring(k - 3, k) == 'end') {
      i = k + 6;
      continue;
    }
    var st = k + 6;
    if (s.codeUnitAt(st) == 13) st++;
    if (s.codeUnitAt(st) == 10) st++;
    final e = s.indexOf('endstream', st);
    var body = bytes.sublist(st, e);
    if (s.substring(s.lastIndexOf('<<', k), k).contains('FlateDecode')) {
      try {
        body = zlib.decode(body);
      } catch (_) {}
    }
    out.add(latin1.decode(body));
    i = e + 9;
  }
  return out;
}

double _d(String block, String name) => double.parse(RegExp('$name: ([\\d.]+)').firstMatch(block)!.group(1)!);

/// Template block text for [marker] up to the next template declaration.
String blockOf(String source, String marker) {
  final start = source.indexOf(marker);
  if (start < 0) throw StateError('no $marker');
  final next = source.indexOf('\nfinal OmrExamTemplate ', start + 10);
  return source.substring(start, next < 0 ? source.length : next);
}

int failures = 0;

void checkExam(String code, String pdfPath, String block, SampleShadingStyle style, PdfFont regular, PdfFont bold) {
  final pw = _d(block, 'pageWidthPt');
  final ph = _d(block, 'pageHeightPt');
  final rx = _d(block, 'bubbleRadiusPt');
  final ry = RegExp(r'bubbleRadiusYPt: ([\d.]+)').firstMatch(block) == null ? rx : _d(block, 'bubbleRadiusYPt');

  void check(bool ok, String what) {
    if (!ok) {
      failures++;
      print('  FAIL: $what');
    }
  }

  // Where the sample really sits: the caption's position in the PDF.
  final streams = streamsOf(File(pdfPath).readAsBytesSync()).where((s) => s.contains('(Correct shading)')).toList();
  check(streams.length == 1, '$pdfPath: expected exactly one stream with the sample, found ${streams.length}');
  if (streams.length != 1) return;
  final content = streams.single;
  final cap = RegExp(r'/F\d+ ([\d.]+) Tf\s+(?:1 0 0 1 )?([\d.]+) ([\d.]+) (?:Td|Tm)\s*\[?\(Correct shading\)').firstMatch(content);
  if (cap == null) {
    check(false, '$pdfPath: caption position not found');
    return;
  }
  check(double.parse(cap.group(1)!) == style.fontSize, 'caption font size ${cap.group(1)} != ${style.fontSize}');
  final leftX = double.parse(cap.group(2)!);
  final baselineY = ph - double.parse(cap.group(3)!);
  check(!content.contains('(x)'), 'a leftover "x" mark from the earlier sample is still printed');

  double measure(String t, double size, bool isBold) => ((isBold ? bold : regular).stringMetrics(t) * size).advanceWidth;
  final shapes = buildSampleShading(style, leftX, baselineY, measure);
  final box = sampleBounds(shapes);

  var nearestBubble = double.infinity;
  for (final m in RegExp(r'BubblePos\("[A-Z]", ([\d.]+), ([\d.]+)\)').allMatches(block)) {
    final x = double.parse(m.group(1)!) * pw, y = double.parse(m.group(2)!) * ph;
    nearestBubble = math.min(nearestBubble, box.gapTo(Box(x - rx, y - ry, x + rx, y + ry)));
  }

  // Every mark centre the decoder looks for: the 4 corners and each interior mark.
  final marks = <(double, double)>[
    for (final m in RegExp(r'OmrCorner\(([\d.]+), ([\d.]+)\)').allMatches(block)) (double.parse(m.group(1)!) * pw, double.parse(m.group(2)!) * ph),
    for (final m in RegExp(r'OmrFiducial\(OmrFiducialRole\.\w+, ([\d.]+), ([\d.]+), [\d.]+\)').allMatches(block)) (double.parse(m.group(1)!) * pw, double.parse(m.group(2)!) * ph),
  ];
  var nearestMark = double.infinity;
  for (final (x, y) in marks) {
    nearestMark = math.min(nearestMark, box.distanceToPoint(x, y));
  }

  var nearestName = double.infinity;
  for (final m in RegExp(r'OmrFieldRect\(([\d.]+), ([\d.]+), ([\d.]+), ([\d.]+)\)').allMatches(block)) {
    final x = double.parse(m.group(1)!) * pw, y = double.parse(m.group(2)!) * ph;
    nearestName = math.min(nearestName, box.gapTo(Box(x, y, x + double.parse(m.group(3)!) * pw, y + double.parse(m.group(4)!) * ph)));
  }

  // After the page warp the decoder re-finds each mark inside a box of +-32
  // canonical px (= 16 pt) around its expected centre; keep a margin outside it.
  const postWarpHalf = 16.0;
  print('$code  (${marks.length} marks, page ${pw.toStringAsFixed(0)}x${ph.toStringAsFixed(0)}pt)');
  print('  sample box x ${box.x0.toStringAsFixed(1)}..${box.x1.toStringAsFixed(1)}, y ${box.y0.toStringAsFixed(1)}..${box.y1.toStringAsFixed(1)} '
      '(${shapes.length} shapes)');
  print('  nearest answer bubble ${nearestBubble.toStringAsFixed(1)}pt, nearest mark centre ${nearestMark.toStringAsFixed(1)}pt, '
      'nearest name-crop ${nearestName.toStringAsFixed(1)}pt');
  check(nearestBubble >= 8, 'sample is within 8pt of an answer bubble ($nearestBubble)');
  check(nearestMark >= postWarpHalf + 6, 'sample is inside/near a mark search box ($nearestMark < ${postWarpHalf + 6})');
  check(nearestName >= 8, 'sample is within 8pt of a name-field crop ($nearestName)');
  check(box.x1 <= pw - 24 && box.x0 > 24 && box.y0 > 24, 'sample reaches the unprinted page margin');
  // The only filled shapes must be bubble-sized discs/dots: nothing solid that
  // is bigger than the exam's own bubble.
  for (final s in shapes.whereType<ShadeEllipse>().where((e) => e.filled)) {
    check(s.rx <= rx && s.ry <= ry, 'a filled shape is larger than the exam\'s own bubble');
  }
}

void main() {
  final doc = PdfDocument();
  final regular = PdfFont.helvetica(doc);
  final bold = PdfFont.helveticaBold(doc);
  final templates = File('../lib/core/omr/omr_templates.dart').readAsStringSync();
  final tat = File('../lib/core/omr/omr_template_tat_v5.dart').readAsStringSync();
  checkExam('AT', '../answer_sheets/AT.pdf', blockOf(templates, 'final OmrExamTemplate _omrAT ='), SampleShadingStyle.at, regular, bold);
  checkExam('QTM', '../answer_sheets/QTM.pdf', blockOf(templates, 'final OmrExamTemplate _omrQTM ='), SampleShadingStyle.qtm, regular, bold);
  checkExam('TAT v5', '../answer_sheets/TAT-portrait-v5.pdf', blockOf(tat, 'final OmrExamTemplate omrTATPortraitV5 ='), SampleShadingStyle.tat, regular, bold);
  if (failures > 0) {
    print('$failures check(s) FAILED');
    exit(1);
  }
  print('All clearance checks passed.');
}
