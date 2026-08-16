// Generates the printable OMR answer sheets (answer_sheets/*.pdf) and the
// matching bubble-coordinate data (lib/core/omr/omr_templates.dart) from a
// single shared layout computation, so the two can never drift apart.
//
// Run with (from the repo root): cd tool && dart pub get && dart run generate_sheets.dart
//
// This is its own standalone Dart package (see tool/pubspec.yaml),
// deliberately kept out of the main app's pubspec.yaml dependency graph —
// pulling in the main app's opencv_dart/dartcv4 dependency here would make
// `dart run` try to build its native library for the desktop host (via
// CMake/Visual Studio), which this script has no need for and most dev
// machines won't have set up for that target.
//
// This replaces the original generate_sheets.py / gen_dart.py tooling,
// whose source (and the PDFs it produced) were never checked into this
// repo — only the Dart template data survived. This tool and its output
// are checked in this time.

import 'dart:io';
import 'dart:math' as math;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// ---------------------------------------------------------------------------
// Page geometry (A4 — the paper size actually used, not the US Letter the
// previous templates assumed).
// ---------------------------------------------------------------------------

const double kPageWidth = 595.28;
const double kPageHeight = 841.89;

/// Page edge -> outer edge of the corner markers. Printers generally can't
/// print all the way to the physical edge, so this stays as blank margin.
const double kPageMargin = 24;

/// Corner marker -> content bounding box. Kept small and uniform so the
/// scannable region hugs the actual content instead of the old design's
/// near-page-edge markers (up to ~470pt of dead space around narrow
/// sections like TAT/QTM).
const double kMarkerPad = 20;

/// Half-size of the drawn marker glyphs themselves (visual only, doesn't
/// affect layout math — the decoder locates markers by image analysis, not
/// by expecting an exact glyph size).
const double kMarkerHalf = 6;

const double kContentLeft = kPageMargin + kMarkerPad;
const double kContentTop = kPageMargin + kMarkerPad;

// ---------------------------------------------------------------------------
// Bubble grid geometry — bigger than the previous 15pt/16pt pitch for
// visibility, while still keeping AT and QTM (the two exam types this pass
// guarantees scanning correctness for) on a single page each.
// ---------------------------------------------------------------------------

const double kChoicePitch = 22; // x spacing between adjacent choice bubbles
const double kRowPitch = 20; // y spacing between adjacent item rows — keep at
// 20: with kRowsPerColumn fixed at 30 below, 29 * rowPitch + 2 * kBubbleRadius
// must stay under the ~623.89pt vertical content budget (A4 minus margins,
// marker padding and the header block) or the last rows run off the page.
// 20 leaves ~26pt of slack; anything above ~20.9 overflows.
const double kColumnGap = 50; // extra x gap between one column and the next
const double kRowLabelWidth = 24; // space reserved for "12." row numbering

/// The printed choice letter sits centered *inside* each bubble, so its own
/// ink already contributes to the decoder's fill-fraction reading before a
/// pencil ever touches it. Bubble radius vs. letter size is chosen so that
/// baseline ink stays well under the decoder's "blank" floor (~10% fill vs.
/// a 15% floor) even though every choice in a question carries a similarly
/// inked letter — a 7pt-radius bubble with a 10pt bold letter measured
/// closer to ~25% baseline fill, comfortably clearing that floor and
/// making every choice look plausibly "maybe marked" (hence flagged
/// ambiguous) even on a genuinely blank sheet.
const double kBubbleRadius = 9;
const double kLetterFontSize = 8;
const int kRowsPerColumn = 30;

// ---------------------------------------------------------------------------
// Header block (brand row, subtitle, name/exam-code table, title,
// instruction line). Fixed height, identical on every page, so every
// exam's content bounding box — and therefore its corner markers — reserves
// the same vertical space regardless of how wide its bubble grid is.
// ---------------------------------------------------------------------------

const double kBrandRowHeight = 26;
const double kSubtitleRowHeight = 14;
const double kGapAfterSubtitle = 6;
const double kTableHeight = 34;
const double kGapAfterTable = 8;
const double kTitleRowHeight = 20;
const double kInstructionRowHeight = 12;
const double kGapBeforeGrid = 10;

const double kHeaderHeight =
    kBrandRowHeight +
    kSubtitleRowHeight +
    kGapAfterSubtitle +
    kTableHeight +
    kGapAfterTable +
    kTitleRowHeight +
    kInstructionRowHeight +
    kGapBeforeGrid;

/// Row 30's bubble center sits `(kRowsPerColumn - 1) * kRowPitch` below row
/// 1's, plus bubble radius clearance below that.
const double kGridHeight = (kRowsPerColumn - 1) * kRowPitch + 2 * kBubbleRadius;

const double kContentHeight = kHeaderHeight + kGridHeight;

// ---------------------------------------------------------------------------
// Brand colors, matching lib/core/constants/app_colors.dart.
// ---------------------------------------------------------------------------

final kGreen = PdfColor.fromHex('#2E7D32'); // AppColors.primaryGreen
final kRedOrange = PdfColor.fromHex('#E53935'); // AppColors.warmRedOrange
final kNavy = PdfColor.fromHex('#1A237E'); // AppColors.darkNavy
final kGray = PdfColor.fromHex('#757575'); // AppColors.textGray
final kBlack = PdfColors.black;

// ---------------------------------------------------------------------------
// Exam content — item counts and choice letters preserved from the current
// lib/core/omr/omr_templates.dart.
// ---------------------------------------------------------------------------

class SectionSpec {
  final String name;
  final int itemCount;
  final List<String> Function(int itemNumberInSection) choicesForItem;
  const SectionSpec(this.name, this.itemCount, this.choicesForItem);
}

class ExamSpec {
  final String code;
  final String title;
  final List<SectionSpec> sections;
  const ExamSpec(this.code, this.title, this.sections);
}

final List<String> _atOdd = const ['A', 'B', 'C', 'D', 'E'];
final List<String> _atEven = const ['F', 'G', 'H', 'J', 'K'];
final List<String> _abcd = const ['A', 'B', 'C', 'D'];
final List<String> _tf = const ['T', 'F'];

final List<ExamSpec> kExams = [
  ExamSpec('AT', 'Admission Test (AT)', [
    SectionSpec('Section 1', 72, (n) => n.isOdd ? _atOdd : _atEven),
  ]),
  ExamSpec('TAT', 'Teaching Aptitude Test (TAT)', [
    SectionSpec('Test I', 30, (n) => _abcd),
    SectionSpec('Test II', 80, (n) => _tf),
    SectionSpec('Test III', 20, (n) => _tf),
  ]),
  ExamSpec('QTM', 'Qualifying Test in Mathematics (QTM)', [
    SectionSpec('Qualifying Test in Mathematics', 60, (n) => _abcd),
  ]),
];

// ---------------------------------------------------------------------------
// Layout: shared by both the PDF drawing and the Dart template emission, so
// they can never disagree about where a bubble is.
// ---------------------------------------------------------------------------

/// One placed bubble, in top-left-origin point space (matches BubblePos'
/// fraction convention once divided by page width/height).
class BubblePoint {
  final String choice;
  final double x;
  final double y;
  const BubblePoint(this.choice, this.x, this.y);
}

/// One placed item (question), with its global item number within its
/// section and its bubbles.
class ItemPlacement {
  final int itemNumber;
  final List<BubblePoint> bubbles;
  const ItemPlacement(this.itemNumber, this.bubbles);
}

/// One physical page: which section it continues, the 1-based page number
/// within that section (for multi-page sections), and its items.
class PagePlacement {
  final SectionSpec section;
  final int pageNumber;
  final int pageCount;
  final List<ItemPlacement> items;
  const PagePlacement(this.section, this.pageNumber, this.pageCount, this.items);
}

class ExamLayout {
  final ExamSpec exam;
  final List<PagePlacement> pages;
  final double contentWidth;
  const ExamLayout(this.exam, this.pages, this.contentWidth);
}

double _columnWidth(int choiceCount) => kRowLabelWidth + (choiceCount - 1) * kChoicePitch;

/// Max columns that fit within the page's content-width budget for a given
/// per-item choice count.
int _maxColumnsFor(int choiceCount) {
  final budget = kPageWidth - 2 * kPageMargin - 2 * kMarkerPad;
  final width = _columnWidth(choiceCount);
  return ((budget + kColumnGap) / (width + kColumnGap)).floor();
}

ExamLayout _layoutExam(ExamSpec exam) {
  final pages = <PagePlacement>[];
  double widestContent = 0;

  for (final section in exam.sections) {
    // Choice count is uniform within a section in every exam here (AT
    // alternates letters but always has 5 choices either way).
    final choiceCount = section.choicesForItem(1).length;
    final columnsPerPage = _maxColumnsFor(choiceCount);
    final itemsPerPage = columnsPerPage * kRowsPerColumn;
    final pageCount = (section.itemCount / itemsPerPage).ceil();

    for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
      final firstItem = pageIndex * itemsPerPage + 1;
      final lastItem = math.min(firstItem + itemsPerPage - 1, section.itemCount);
      final columnsOnThisPage = ((lastItem - firstItem + 1) / kRowsPerColumn).ceil();
      final usedWidth = columnsOnThisPage * _columnWidth(choiceCount) + (columnsOnThisPage - 1) * kColumnGap;
      if (usedWidth > widestContent) widestContent = usedWidth;

      final items = <ItemPlacement>[];
      for (var itemNumber = firstItem; itemNumber <= lastItem; itemNumber++) {
        final indexOnPage = itemNumber - firstItem;
        final col = indexOnPage ~/ kRowsPerColumn;
        final row = indexOnPage % kRowsPerColumn;
        final columnX = kContentLeft + col * (_columnWidth(choiceCount) + kColumnGap) + kRowLabelWidth;
        final rowY = kContentTop + kHeaderHeight + row * kRowPitch;
        final choices = section.choicesForItem(itemNumber);
        final bubbles = [
          for (var i = 0; i < choices.length; i++) BubblePoint(choices[i], columnX + i * kChoicePitch, rowY),
        ];
        items.add(ItemPlacement(itemNumber, bubbles));
      }
      pages.add(PagePlacement(section, pageIndex + 1, pageCount, items));
    }
  }

  return ExamLayout(exam, pages, widestContent);
}

/// The 4 corner marker points (top-left-origin, points), sized to the
/// widest page this exam actually uses so every page's content — including
/// narrower sections in a multi-page exam like TAT — stays safely inside a
/// single template-level marker rectangle.
List<(double, double)> _cornerMarkers(ExamLayout layout) {
  final right = kContentLeft + layout.contentWidth + kMarkerPad;
  final bottom = kContentTop + kContentHeight + kMarkerPad;
  return [(kPageMargin, kPageMargin), (right, kPageMargin), (kPageMargin, bottom), (right, bottom)];
}

// ---------------------------------------------------------------------------
// PDF drawing
// ---------------------------------------------------------------------------

void _paintPage(PdfGraphics canvas, ExamSpec exam, PagePlacement page, ExamLayout layout, PdfFont regular, PdfFont bold) {
  double flip(double topLeftY) => kPageHeight - topLeftY;

  // Corner markers: solid squares top-left/bottom-left, thin ticks
  // top-right/bottom-right (matches the physical sheet design already in
  // use, so the decoder's shape-agnostic centroid search keeps working).
  final corners = _cornerMarkers(layout);
  canvas.setColor(kBlack);
  canvas.drawRect(corners[0].$1 - kMarkerHalf, flip(corners[0].$2) - kMarkerHalf, kMarkerHalf * 2, kMarkerHalf * 2);
  canvas.fillPath();
  canvas.drawRect(corners[2].$1 - kMarkerHalf, flip(corners[2].$2) - kMarkerHalf, kMarkerHalf * 2, kMarkerHalf * 2);
  canvas.fillPath();
  canvas.setLineWidth(2.5);
  canvas.drawLine(corners[1].$1, flip(corners[1].$2) - kMarkerHalf, corners[1].$1, flip(corners[1].$2) + kMarkerHalf);
  canvas.strokePath();
  canvas.drawLine(corners[3].$1, flip(corners[3].$2) - kMarkerHalf, corners[3].$1, flip(corners[3].$2) + kMarkerHalf);
  canvas.strokePath();

  // Header: brand wordmark.
  var y = kContentTop;
  canvas.setColor(kRedOrange);
  canvas.drawString(bold, 20, 'Guide', kContentLeft, flip(y + 20));
  final guideWidth = (bold.stringMetrics('Guide') * 20).advanceWidth;
  canvas.setColor(kGreen);
  canvas.drawString(bold, 20, 'Grade', kContentLeft + guideWidth, flip(y + 20));
  y += kBrandRowHeight;

  canvas.setColor(kGray);
  canvas.drawString(regular, 10, 'Guidance and Testing Center', kContentLeft, flip(y + 10));
  y += kSubtitleRowHeight + kGapAfterSubtitle;

  // Name / exam info table.
  final tableWidth = layout.contentWidth;
  final columns = [
    ('Last Name', tableWidth * 0.24),
    ('First Name', tableWidth * 0.22),
    ('MI', tableWidth * 0.08),
    ('Exam Code', tableWidth * 0.18),
    ('Batch', tableWidth * 0.14),
    ('Date', tableWidth * 0.14),
  ];
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(kContentLeft, flip(y + kTableHeight), tableWidth, kTableHeight);
  canvas.strokePath();
  var colX = kContentLeft;
  for (final (label, w) in columns) {
    canvas.drawLine(colX, flip(y), colX, flip(y + kTableHeight));
    canvas.strokePath();
    canvas.setColor(kGray);
    canvas.drawString(regular, 7, label, colX + 3, flip(y + 10));
    colX += w;
  }
  y += kTableHeight + kGapAfterTable;

  // Title (+ page indicator for multi-page sections).
  canvas.setColor(kNavy);
  final title = page.pageCount > 1 ? '${exam.title} - ${page.section.name} (Page ${page.pageNumber} of ${page.pageCount})' : '${exam.title} - ${page.section.name}';
  canvas.drawString(bold, 13, title, kContentLeft, flip(y + 15));
  y += kTitleRowHeight;

  canvas.setColor(kGray);
  canvas.drawString(regular, 8, 'Use a No. 2 pencil. Fill the circle completely.', kContentLeft, flip(y + 9));
  y += kInstructionRowHeight + kGapBeforeGrid;

  // Bubble grid.
  for (final item in page.items) {
    canvas.setColor(kBlack);
    final labelX = item.bubbles.first.x - kRowLabelWidth;
    canvas.drawString(regular, 9, '${item.itemNumber}.', labelX, flip(item.bubbles.first.y) - 3);
    for (final bubble in item.bubbles) {
      canvas.setLineWidth(1);
      canvas.drawEllipse(bubble.x, flip(bubble.y), kBubbleRadius, kBubbleRadius);
      canvas.strokePath();
      canvas.setColor(kBlack);
      final metrics = bold.stringMetrics(bubble.choice) * kLetterFontSize;
      canvas.drawString(bold, kLetterFontSize, bubble.choice, bubble.x - metrics.advanceWidth / 2, flip(bubble.y) - metrics.ascent / 2);
    }
  }
}

// ---------------------------------------------------------------------------
// Dart template emission
// ---------------------------------------------------------------------------

const String _schema = '''
class BubblePos {
  final String choice;
  final double xFrac;
  final double yFrac;
  const BubblePos(this.choice, this.xFrac, this.yFrac);
}

class OmrSection {
  final String name;
  final int itemCount;
  final Map<int, List<BubblePos>> items;
  const OmrSection({required this.name, required this.itemCount, required this.items});
}

class OmrCorner {
  final double xFrac;
  final double yFrac;
  const OmrCorner(this.xFrac, this.yFrac);
}

class OmrExamTemplate {
  final String examCode;
  final double pageWidthPt;
  final double pageHeightPt;
  /// Radius, in page points, of the printed bubble circles — the decoder
  /// samples a region this size around each BubblePos, so it must match
  /// the actual printed geometry rather than being guessed independently.
  final double bubbleRadiusPt;
  final List<OmrCorner> cornerMarkers;
  final List<OmrSection> sections;
  const OmrExamTemplate({
    required this.examCode,
    required this.pageWidthPt,
    required this.pageHeightPt,
    required this.bubbleRadiusPt,
    required this.cornerMarkers,
    required this.sections,
  });
}
''';

String _formatFrac(double v) => v.toStringAsFixed(5);

String _emitTemplate(ExamLayout layout) {
  final exam = layout.exam;
  final varName = '_omr${exam.code}';
  final corners = _cornerMarkers(layout);
  final cornersDart = corners.map((c) => 'OmrCorner(${_formatFrac(c.$1 / kPageWidth)}, ${_formatFrac(c.$2 / kPageHeight)})').join(', ');

  // Merge all pages belonging to the same section back into one
  // OmrSection (its items map spans every page it was laid out across).
  final buffer = StringBuffer();
  buffer.writeln('final OmrExamTemplate $varName = OmrExamTemplate(');
  buffer.writeln('  examCode: "${exam.code}",');
  buffer.writeln('  pageWidthPt: $kPageWidth,');
  buffer.writeln('  pageHeightPt: $kPageHeight,');
  buffer.writeln('  bubbleRadiusPt: $kBubbleRadius,');
  buffer.writeln('  cornerMarkers: const [$cornersDart],');
  buffer.writeln('  sections: const [');
  for (final section in exam.sections) {
    buffer.writeln('    OmrSection(');
    buffer.writeln('      name: "${section.name}",');
    buffer.writeln('      itemCount: ${section.itemCount},');
    buffer.writeln('      items: {');
    final pagesForSection = layout.pages.where((p) => p.section == section);
    for (final page in pagesForSection) {
      for (final item in page.items) {
        final bubblesDart = item.bubbles
            .map((b) => 'BubblePos("${b.choice}", ${_formatFrac(b.x / kPageWidth)}, ${_formatFrac(b.y / kPageHeight)})')
            .join(', ');
        buffer.writeln('        ${item.itemNumber}: [$bubblesDart],');
      }
    }
    buffer.writeln('      },');
    buffer.writeln('    ),');
  }
  buffer.writeln('  ],');
  buffer.writeln(');');
  return buffer.toString();
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Future<void> main() async {
  // Paths are relative to this package's root (tool/), one level below the
  // main app root — this script is a standalone Dart package (tool/pubspec.yaml)
  // deliberately kept out of the main app's dependency graph.
  final answerSheetsDir = Directory('../answer_sheets')..createSync(recursive: true);

  final dartFile = StringBuffer();
  dartFile.writeln('// GENERATED by tool/generate_sheets.dart — do not hand-edit.');
  dartFile.writeln('// Bubble positions are fractions of the page (0.0-1.0), top-left origin,');
  dartFile.writeln('// A4 portrait (595.28 x 841.89pt), matching the printed PDFs in /answer_sheets.');
  dartFile.writeln('// Regenerate with: dart run tool/generate_sheets.dart');
  dartFile.writeln();
  dartFile.writeln(_schema);

  final mapEntries = <String>[];

  for (final exam in kExams) {
    final layout = _layoutExam(exam);

    final pdf = pw.Document();
    final regular = PdfFont.helvetica(pdf.document);
    final bold = PdfFont.helveticaBold(pdf.document);

    for (final page in layout.pages) {
      pdf.addPage(
        pw.Page(
          pageFormat: const PdfPageFormat(kPageWidth, kPageHeight),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.CustomPaint(
            size: const PdfPoint(kPageWidth, kPageHeight),
            painter: (canvas, size) => _paintPage(canvas, exam, page, layout, regular, bold),
          ),
        ),
      );
    }

    final bytes = await pdf.save();
    File('${answerSheetsDir.path}/${exam.code}.pdf').writeAsBytesSync(bytes);
    stdout.writeln('Wrote answer_sheets/${exam.code}.pdf (${layout.pages.length} page(s), content width ${layout.contentWidth.toStringAsFixed(1)}pt)');

    dartFile.writeln(_emitTemplate(layout));
    mapEntries.add('"${exam.code}": _omr${exam.code}');
  }

  dartFile.writeln('final Map<String, OmrExamTemplate> omrTemplates = {');
  for (final entry in mapEntries) {
    dartFile.writeln('  $entry,');
  }
  dartFile.writeln('};');

  File('../lib/core/omr/omr_templates.dart').writeAsStringSync(dartFile.toString());
  stdout.writeln('Wrote lib/core/omr/omr_templates.dart');
}
