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
// Page geometry. Paper size is per-exam (see ExamSpec.pageWidthPt/
// pageHeightPt below) — AT prints on A4; QTM/TAT print on "long" bond
// paper, matching NDMU's actual forms. "Long" here is the Philippine long
// bond paper size (8.5 x 13in), not US Legal (8.5 x 14in) — a distinct,
// smaller size despite the same name.
// ---------------------------------------------------------------------------

const double kA4Width = 595.28;
const double kA4Height = 841.89;
const double kLongWidth = 612; // 8.5in
const double kLongHeight = 936; // 13in

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
// Bubble grid geometry — sized close to the real official sheets' small,
// tight proportions (matching NDMU's actual QTM/TAT forms and the
// OLSAT/16PF-inspired AT/PT layouts), not enlarged for scan accuracy.
//
// An earlier version of this file enlarged bubbles relative to their
// printed letter, because the letter's own ink was making blank bubbles
// read as "maybe marked." That's no longer necessary: the decoder
// (_bubbleFillFraction in lib/core/omr/omr_decoder.dart) now samples an
// outer square minus an inner square around each bubble - isolating the
// ring where a pencil mark lands from the printed letter sitting in the
// center - independent of how small the bubble is. So sizing here can
// track the real sheets instead of working around a decoder limitation.
// ---------------------------------------------------------------------------

const double kChoicePitch = 15; // x spacing between adjacent choice bubbles
const double kRowPitch = 15; // y spacing between adjacent item rows
const double kColumnGap = 40; // extra x gap between one column and the next
const double kRowLabelWidth = 20; // space reserved for "12." row numbering

const double kBubbleRadius = 6;
const double kLetterFontSize = 6;
const int kRowsPerColumn = 30;

// ---------------------------------------------------------------------------
// Header block. Two kinds:
//  - simple: GuideGrade's own generic brand header (AT/PT — these are only
//    structurally inspired by third-party commercial tests, so they keep
//    generic branding rather than reproducing OLSAT/16PF's own).
//  - ndmu: the real NDMU Guidance Center letterhead + ID-field table +
//    scores block (QTM/TAT — NDMU's own documents, reproduced closely).
// Each exam reserves a fixed height for its own kind on every page, so its
// content bounding box — and therefore its corner markers — stays
// consistent regardless of how wide its bubble grid is.
// ---------------------------------------------------------------------------

enum HeaderKind { simple, ndmu }

const double kBrandRowHeight = 26;
const double kSubtitleRowHeight = 14;
const double kGapAfterSubtitle = 6;
const double kTableHeight = 34;
const double kGapAfterTable = 8;
const double kTitleRowHeight = 20;
const double kInstructionRowHeight = 12;
const double kGapBeforeGrid = 10;

const double kSimpleHeaderHeight =
    kBrandRowHeight +
    kSubtitleRowHeight +
    kGapAfterSubtitle +
    kTableHeight +
    kGapAfterTable +
    kTitleRowHeight +
    kInstructionRowHeight +
    kGapBeforeGrid;

// NDMU letterhead header: institutional heading box, 3-row ID table (Last
// Name/First Name/MI, School Last Attended, Address of School Last
// Attended), a Date/Birth/Age/Sex + Scores block, then the exam title.
const double kLetterheadHeight = 46;
const double kGapAfterLetterhead = 6;
const double kIdRowHeight = 22;
const int kIdRowCount = 3;
const double kGapAfterIdTable = 6;
const double kDateScoresHeight = 58;
const double kGapAfterDateScores = 8;
const double kNdmuTitleHeight = 28;
const double kNdmuInstructionHeight = 12;
const double kGapBeforeNdmuGrid = 8;

const double kNdmuHeaderHeight =
    kLetterheadHeight +
    kGapAfterLetterhead +
    kIdRowHeight * kIdRowCount +
    kGapAfterIdTable +
    kDateScoresHeight +
    kGapAfterDateScores +
    kNdmuTitleHeight +
    kNdmuInstructionHeight +
    kGapBeforeNdmuGrid;

double headerHeightFor(HeaderKind kind) => switch (kind) {
  HeaderKind.simple => kSimpleHeaderHeight,
  HeaderKind.ndmu => kNdmuHeaderHeight,
};

/// Row 30's bubble center sits `(kRowsPerColumn - 1) * kRowPitch` below row
/// 1's, plus bubble radius clearance below that. Same for every exam — only
/// the header above it varies.

double contentHeightFor(ExamSpec exam) =>
    headerHeightFor(exam.headerKind) + (exam.rowsPerColumn - 1) *
exam.rowPitch + 2 * exam.bubbleRadius;

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
// lib/core/omr/omr_templates.dart, except PT's "?" middle choice (almost
// certainly a lost-tooling artifact) is fixed to "b".
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
  final HeaderKind headerKind;
  final double pageWidthPt;
  final double pageHeightPt;

  /// Page geometry: how far the corner marks and bubble grid sit from the
  /// page edges, and how the grid itself is spaced. Defaults match every
  /// exam this tool has generated so far. A sheet with real, fixed
  /// physical spacing that this tool didn't draw (an existing printed
  /// form) overrides these to match its actual measurements instead.
  final double pageMargin;
  final double markerPad;
  final double choicePitch;
  final double rowPitch;
  final double columnGap;
  final double rowLabelWidth;
  final double bubbleRadius;
  final int rowsPerColumn;

  /// Row count for just the first column, if it differs from every other
  /// column — e.g. a samples/legend box eating part of the first column's
  /// space, common on real answer sheets. Null (the default) means every
  /// column, first included, uses [rowsPerColumn].
  final int? firstColumnRows;

  /// Direct override for [contentLeft]/[contentTop], for a sheet whose
  /// measured content origin doesn't decompose cleanly into
  /// pageMargin+markerPad (e.g. an existing printed form measured with a
  /// ruler, where only the final distance from the page edge is known).
  /// Null (the default) falls back to pageMargin + markerPad, as before.
  final double? contentLeftOverride;
  final double? contentTopOverride;

  double get contentLeft => contentLeftOverride ?? (pageMargin + markerPad);
  double get contentTop => contentTopOverride ?? (pageMargin + markerPad);

  /// Direct override for where the 4 corner anchor marks are (top-left,
  /// top-right, bottom-left, bottom-right — same order as everywhere
  /// else), in points from the page's top-left. Null (the default) falls
  /// back to the usual content-bounds-derived computation in
  /// [_cornerMarkers]. Set this for a sheet whose anchors were physically
  /// placed at known positions independent of content bounds (e.g. near
  /// the sheet's actual physical corners, like a normal registration
  /// mark, rather than hugging the bubble grid).
  final List<(double, double)>? cornerMarkersOverride;

  /// NDMU letterhead lines (only used when [headerKind] is
  /// [HeaderKind.ndmu]) — e.g. the center's name, university, and location.
  final List<String> letterheadLines;

  const ExamSpec(
      this.code,
      this.title,
      this.sections, {
        this.headerKind = HeaderKind.simple,
        this.pageWidthPt = kA4Width,
        this.pageHeightPt = kA4Height,
        this.pageMargin = kPageMargin,
        this.markerPad = kMarkerPad,
        this.choicePitch = kChoicePitch,
        this.rowPitch = kRowPitch,
        this.columnGap = kColumnGap,
        this.rowLabelWidth = kRowLabelWidth,
        this.bubbleRadius = kBubbleRadius,
        this.rowsPerColumn = kRowsPerColumn,
        this.firstColumnRows,
        this.contentLeftOverride,
        this.contentTopOverride,
        this.cornerMarkersOverride,
        this.letterheadLines = const [],
      });
}

final List<String> _atOdd = const ['A', 'B', 'C', 'D', 'E'];
final List<String> _atEven = const ['F', 'G', 'H', 'J', 'K'];
final List<String> _ptChoices = const ['a', 'b', 'c'];
final List<String> _abcd = const ['A', 'B', 'C', 'D'];
final List<String> _tf = const ['T', 'F'];

final List<ExamSpec> kExams = [
  ExamSpec('PT', 'Personality Profile (PT)', [
    SectionSpec('Personality Profile', 185, (n) => _ptChoices),
  ]),
  ExamSpec(
    'TAT',
    'Teaching Aptitude Test (TAT)',
    [
      SectionSpec('Test I', 30, (n) => _abcd),
      SectionSpec('Test II', 80, (n) => _tf),
      SectionSpec('Test III', 20, (n) => _tf),
    ],
    headerKind: HeaderKind.ndmu,
    pageWidthPt: kLongWidth,
    pageHeightPt: kLongHeight,
    letterheadLines: const [
      'Guidance, Honors, and Scholarship Center',
      'Notre Dame of Marbel University',
      'City of Koronadal, South Cotabato',
    ],
  ),
  ExamSpec(
    'QTM',
    'Qualifying Test in Mathematics (QTM)',
    [SectionSpec('Qualifying Test in Mathematics', 60, (n) => _abcd)],
    headerKind: HeaderKind.ndmu,
    pageWidthPt: kLongWidth,
    pageHeightPt: kLongHeight,
    letterheadLines: const [
      'Guidance and Testing Center',
      'NOTRE DAME OF MARBEL UNIVERSITY',
      'City of Koronadal, South Cotabato',
    ],
  ),
  // The Admission Test (AT) — a self-designed sheet, printed and laid out
  // entirely by this tool on standard A4 (matches the paper it's actually
  // printed on), the same way PT/QTM/TAT already are. An earlier version
  // instead tried to match a real, physically-anchored OLSAT answer sheet
  // NDMU had been administering — hand-measured with a ruler, then
  // corrected by curve-fitting against a single reference photo, with a
  // corner-marker position that was flagged provisional and never
  // independently confirmed (see git history). Every one of those numbers
  // was a potential source of systematic misalignment no amount of
  // decoder tuning could fix, since the ground truth itself was uncertain.
  // Printing our own sheet removes that uncertainty entirely: the PDF and
  // the decoder's bubble coordinates below come from the exact same
  // computation and can never disagree.
  //
  // Structure preserved from the original OLSAT-inspired design: 72
  // items, choices alternating A-E / F-K by odd/even item.
  //
  // The default kBubbleRadius/kChoicePitch/kRowPitch (sized for QTM/TAT's
  // dense multi-section grids) left this single 72-item section only 3
  // columns of 30 rows on an A4 page — every page's column count is
  // _maxColumnsFor's width-fitting max regardless of how many items
  // actually need to fill it (see _layoutExam: itemsPerPage is always
  // columnsPerPage * rowsPerColumn, and items fill columns sequentially,
  // not spread evenly), so with rowsPerColumn=30 the 3rd column only
  // needed 12 rows and the 4th went unused entirely — over half the page
  // printed blank on the right and along the bottom. rowsPerColumn: 18
  // uses exactly the 4 columns that fit this page width (72 / 4 = 18,
  // divides evenly, no partially-empty column), and the larger
  // bubbleRadius/choicePitch/rowPitch below scale the grid up to use most
  // of the remaining page instead of leaving it blank — verified by
  // rendering the regenerated PDF, not just computed on paper.
  ExamSpec(
    'AT',
    'Admission Test (AT) - OLSAT',
    [SectionSpec('Answer Document', 72, (n) => n.isOdd ? _atOdd : _atEven)],
    bubbleRadius: 8,
    choicePitch: 18,
    rowPitch: 30,
    rowsPerColumn: 18,
  ),
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

double _columnWidth(int choiceCount, double rowLabelWidth, double choicePitch) =>
    rowLabelWidth + (choiceCount - 1) * choicePitch;

/// Max columns that fit within the page's content-width budget for a given
/// per-item choice count.
int _maxColumnsFor(int choiceCount, ExamSpec exam) {
  final budget = exam.pageWidthPt - 2 * exam.pageMargin - 2 * exam.markerPad;
  final width = _columnWidth(choiceCount, exam.rowLabelWidth, exam.choicePitch);
  return ((budget + exam.columnGap) / (width + exam.columnGap)).floor();
}

/// NDMU letterhead headers (QTM/TAT) need real horizontal room for their
/// institutional heading and ID fields regardless of how narrow that
/// exam's bubble grid is (QTM's 2-column A-D grid is barely 170pt wide) —
/// the real forms' letterhead spans most of the page width. Without this,
/// "NOTRE DAME OF MARBEL UNIVERSITY" and the Date/Scores block overflow
/// past a grid-width-only content box.
const double kNdmuMinContentWidth = 440;

ExamLayout _layoutExam(ExamSpec exam) {
  final pages = <PagePlacement>[];
  double widestContent = exam.headerKind == HeaderKind.ndmu ? kNdmuMinContentWidth : 0;
  final firstColRows = exam.firstColumnRows ?? exam.rowsPerColumn;

  // Maps a 0-based item index on a page to its (column, row), letting the
  // first column be a different height than the rest (see
  // ExamSpec.firstColumnRows). When firstColRows == rowsPerColumn, this
  // reduces to the original indexOnPage ~/ rowsPerColumn / % rowsPerColumn
  // math exactly.
  //
  // A short first column is bottom-aligned, not top-aligned: on OLSAT, a
  // "SAMPLES" legend box occupies the *top* of column 1's space, so items
  // 1-8 sit at the same height as items 17-24, 33-40 etc. (the *second*
  // half of every other column), not aligned with 9-16 (the first half).
  final firstColumnRowOffset = exam.rowsPerColumn - firstColRows;
  (int, int) columnAndRow(int indexOnPage) {
    if (indexOnPage < firstColRows) return (0, firstColumnRowOffset + indexOnPage);
    final remaining = indexOnPage - firstColRows;
    return (1 + remaining ~/ exam.rowsPerColumn, remaining % exam.rowsPerColumn);
  }

  for (final section in exam.sections) {
    final choiceCount = section.choicesForItem(1).length;
    final columnsPerPage = _maxColumnsFor(choiceCount, exam);
    final itemsPerPage = firstColRows + (columnsPerPage - 1) * exam.rowsPerColumn;
    final pageCount = (section.itemCount / itemsPerPage).ceil();

    for (var pageIndex = 0; pageIndex < pageCount; pageIndex++) {
      final firstItem = pageIndex * itemsPerPage + 1;
      final lastItem = math.min(firstItem + itemsPerPage - 1, section.itemCount);
      final (lastCol, _) = columnAndRow(lastItem - firstItem);
      final columnsOnThisPage = lastCol + 1;
      final usedWidth = columnsOnThisPage * _columnWidth(choiceCount, exam.rowLabelWidth, exam.choicePitch) +
          (columnsOnThisPage - 1) * exam.columnGap;
      if (usedWidth > widestContent) widestContent = usedWidth;

      final items = <ItemPlacement>[];
      for (var itemNumber = firstItem; itemNumber <= lastItem; itemNumber++) {
        final indexOnPage = itemNumber - firstItem;
        final (col, row) = columnAndRow(indexOnPage);
        final columnX = exam.contentLeft +
            col * (_columnWidth(choiceCount, exam.rowLabelWidth, exam.choicePitch) + exam.columnGap) +
            exam.rowLabelWidth;
        final rowY = exam.contentTop + headerHeightFor(exam.headerKind) + row * exam.rowPitch;
        final choices = section.choicesForItem(itemNumber);
        final bubbles = [
          for (var i = 0; i < choices.length; i++) BubblePoint(choices[i], columnX + i * exam.choicePitch, rowY),
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
  final exam = layout.exam;
  if (exam.cornerMarkersOverride != null) return exam.cornerMarkersOverride!;
  final right = exam.contentLeft + layout.contentWidth + exam.markerPad;
  final bottom = exam.contentTop + contentHeightFor(exam) + exam.markerPad;
  return [(exam.pageMargin, exam.pageMargin), (right, exam.pageMargin), (exam.pageMargin, bottom), (right, bottom)];
}

// ---------------------------------------------------------------------------
// PDF drawing
// ---------------------------------------------------------------------------

void _paintPage(PdfGraphics canvas, ExamSpec exam, PagePlacement page, ExamLayout layout, PdfFont regular, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;

  // Corner markers: solid filled squares at all 4 corners. An earlier
  // version drew thin single-line ticks (2.5pt wide) at the top-right and
  // bottom-right corners instead — visually distinct, but with roughly a
  // fifth of the ink area of the solid squares, they were consistently the
  // weakest link in corner detection (easily broken up by ordinary photo
  // blur/JPEG softening). Same solid square everywhere removes that
  // asymmetry rather than continuing to work around it in the decoder.
  final corners = _cornerMarkers(layout);
  canvas.setColor(kBlack);
  for (final corner in corners) {
    canvas.drawRect(corner.$1 - kMarkerHalf, flip(corner.$2) - kMarkerHalf, kMarkerHalf * 2, kMarkerHalf * 2);
    canvas.fillPath();
  }

  switch (exam.headerKind) {
    case HeaderKind.simple:
      _paintSimpleHeader(canvas, exam, page, layout, regular, bold, flip);
    case HeaderKind.ndmu:
      _paintNdmuHeader(canvas, exam, page, layout, regular, bold, flip);
  }

  // Bubble grid. QTM/TAT (NDMU forms) draw slightly elongated ovals rather
  // than perfect circles, matching those sheets' actual bubble style; the
  // decoder samples square regions regardless of the drawn shape, so this
  // is purely cosmetic.
  final bubbleRx = exam.bubbleRadius;
  final bubbleRy = exam.headerKind == HeaderKind.ndmu ? exam.bubbleRadius * 0.8 : exam.bubbleRadius;
  for (final item in page.items) {
    canvas.setColor(kBlack);
    final labelX = item.bubbles.first.x - kRowLabelWidth;
    canvas.drawString(regular, 9, '${item.itemNumber}.', labelX, flip(item.bubbles.first.y) - 3);
    for (final bubble in item.bubbles) {
      canvas.setLineWidth(1);
      canvas.drawEllipse(bubble.x, flip(bubble.y), bubbleRx, bubbleRy);
      canvas.strokePath();
      canvas.setColor(kBlack);
      final metrics = bold.stringMetrics(bubble.choice) * kLetterFontSize;
      canvas.drawString(bold, kLetterFontSize, bubble.choice, bubble.x - metrics.advanceWidth / 2, flip(bubble.y) - metrics.ascent / 2);
    }
  }
}

/// GuideGrade's own generic brand header (AT/PT) — these are only
/// structurally inspired by third-party commercial tests (OLSAT/16PF), so
/// they keep GuideGrade's own branding rather than reproducing those
/// tests' names or logos.
void _paintSimpleHeader(
  PdfGraphics canvas,
  ExamSpec exam,
  PagePlacement page,
  ExamLayout layout,
  PdfFont regular,
  PdfFont bold,
  double Function(double) flip,
) {
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
}

/// NDMU's own official letterhead header (QTM/TAT) — institutional heading,
/// full ID-field table, and a Date/Birth/Age/Sex + Scores block, matching
/// the real forms these exam types are administered on today.
void _paintNdmuHeader(
  PdfGraphics canvas,
  ExamSpec exam,
  PagePlacement page,
  ExamLayout layout,
  PdfFont regular,
  PdfFont bold,
  double Function(double) flip,
) {
  var y = kContentTop;
  final width = layout.contentWidth;

  // Letterhead box.
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(kContentLeft, flip(y + kLetterheadHeight), width, kLetterheadHeight);
  canvas.strokePath();
  var ly = y + 13;
  for (var i = 0; i < exam.letterheadLines.length; i++) {
    final line = exam.letterheadLines[i];
    final size = i == 1 ? 12.0 : 8.0; // the university name (line 2) stands out
    final font = i == 1 ? bold : regular;
    final metrics = font.stringMetrics(line) * size;
    final textX = kContentLeft + (width - metrics.advanceWidth) / 2;
    canvas.setColor(i == 1 ? kNavy : kGray);
    canvas.drawString(font, size, line, textX, flip(ly));
    ly += size + 4;
  }
  y += kLetterheadHeight + kGapAfterLetterhead;

  // ID table: row 1 splits into Last Name / First Name / MI; rows 2-3 are
  // full-width (School Last Attended, Address of School Last Attended).
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  final idTableHeight = kIdRowHeight * kIdRowCount;
  canvas.drawRect(kContentLeft, flip(y + idTableHeight), width, idTableHeight);
  canvas.strokePath();
  for (var i = 1; i < kIdRowCount; i++) {
    final lineY = y + kIdRowHeight * i;
    canvas.drawLine(kContentLeft, flip(lineY), kContentLeft + width, flip(lineY));
    canvas.strokePath();
  }
  final nameCols = [('Last Name', width * 0.45), ('First Name', width * 0.4), ('MI', width * 0.15)];
  var colX = kContentLeft;
  for (final (label, w) in nameCols) {
    if (colX > kContentLeft) {
      canvas.drawLine(colX, flip(y), colX, flip(y + kIdRowHeight));
      canvas.strokePath();
    }
    canvas.setColor(kGray);
    canvas.drawString(regular, 7, label, colX + 3, flip(y + 9));
    colX += w;
  }
  canvas.setColor(kGray);
  canvas.drawString(regular, 7, 'School Last Attended', kContentLeft + 3, flip(y + kIdRowHeight + 9));
  canvas.drawString(regular, 7, 'Address of School Last Attended', kContentLeft + 3, flip(y + kIdRowHeight * 2 + 9));
  y += idTableHeight + kGapAfterIdTable;

  // Date/Birth/Age/Sex block (left) + exam-specific scores block (right).
  final leftWidth = width * 0.55;
  final rightX = kContentLeft + leftWidth + 10;
  final rightWidth = width - leftWidth - 10;

  canvas.setColor(kGray);
  canvas.drawString(regular, 7, 'Date Today:  Year _____  Month _____  Day _____', kContentLeft, flip(y + 10));
  canvas.drawString(regular, 7, 'Birth Date:  Year _____  Month _____  Day _____', kContentLeft, flip(y + 26));
  canvas.drawString(regular, 7, 'Age: _____   Sex:  M ( )   F ( )', kContentLeft, flip(y + 42));

  canvas.setLineWidth(0.75);
  if (exam.code == 'TAT') {
    canvas.setColor(kBlack);
    canvas.drawString(bold, 7, 'Raw', rightX + rightWidth * 0.45, flip(y + 8));
    canvas.drawString(bold, 7, 'Scaled', rightX + rightWidth * 0.75, flip(y + 8));
    const rows = ['Test I', 'Test II', 'Test III', 'Total'];
    for (var i = 0; i < rows.length; i++) {
      final rowY = y + 12 + i * 11.0;
      canvas.setColor(kGray);
      canvas.drawString(regular, 7, rows[i], rightX, flip(rowY + 8));
      canvas.drawRect(rightX + rightWidth * 0.42, flip(rowY + 10), rightWidth * 0.22, 10);
      canvas.strokePath();
      canvas.drawRect(rightX + rightWidth * 0.72, flip(rowY + 10), rightWidth * 0.22, 10);
      canvas.strokePath();
    }
  } else {
    canvas.setColor(kNavy);
    canvas.drawString(bold, 9, 'Scores', rightX, flip(y + 10));
    canvas.setColor(kGray);
    canvas.drawString(regular, 7, 'Raw Score', rightX, flip(y + 24));
    canvas.drawRect(rightX, flip(y + 38), rightWidth * 0.42, 12);
    canvas.strokePath();
    canvas.drawString(regular, 7, 'Standard Score', rightX + rightWidth * 0.5, flip(y + 24));
    canvas.drawRect(rightX + rightWidth * 0.5, flip(y + 38), rightWidth * 0.42, 12);
    canvas.strokePath();
    canvas.drawString(regular, 7, 'Test Booklet No.', rightX, flip(y + 54));
    canvas.drawRect(rightX, flip(y + kDateScoresHeight), rightWidth * 0.42, 12);
    canvas.strokePath();
  }
  y += kDateScoresHeight + kGapAfterDateScores;

  // Title: exam name, then "<section> — ANSWER SHEET" (section omitted
  // when it's just a restatement of the exam name, as for QTM's single
  // section named the same as the exam itself).
  final title1 = exam.title.replaceAll(RegExp(r'\s*\([A-Z]+\)$'), '').toUpperCase();
  final sectionDiffers = page.section.name.toUpperCase() != title1;
  final title2Parts = [
    if (sectionDiffers) page.section.name,
    if (page.pageCount > 1) 'ANSWER SHEET (Page ${page.pageNumber} of ${page.pageCount})' else 'ANSWER SHEET',
  ];
  canvas.setColor(kNavy);
  canvas.drawString(bold, 12, title1, kContentLeft, flip(y + 13));
  canvas.drawString(bold, 9, title2Parts.join(' - ').toUpperCase(), kContentLeft, flip(y + 26));
  y += kNdmuTitleHeight;

  canvas.setColor(kGray);
  canvas.drawString(regular, 7, 'Use a No. 2 pencil. Fill the circle completely.', kContentLeft, flip(y + 9));
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
  final cornersDart = corners.map((c) => 'OmrCorner(${_formatFrac(c.$1 / exam.pageWidthPt)}, ${_formatFrac(c.$2 / exam.pageHeightPt)})').join(', ');

  // Merge all pages belonging to the same section back into one
  // OmrSection (its items map spans every page it was laid out across).
  final buffer = StringBuffer();
  buffer.writeln('final OmrExamTemplate $varName = OmrExamTemplate(');
  buffer.writeln('  examCode: "${exam.code}",');
  buffer.writeln('  pageWidthPt: ${exam.pageWidthPt},');
  buffer.writeln('  pageHeightPt: ${exam.pageHeightPt},');
  buffer.writeln('  bubbleRadiusPt: ${exam.bubbleRadius},');
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
            .map((b) => 'BubblePos("${b.choice}", ${_formatFrac(b.x / exam.pageWidthPt)}, ${_formatFrac(b.y / exam.pageHeightPt)})')
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
  dartFile.writeln('// Bubble positions are fractions of the page (0.0-1.0), top-left origin —');
  dartFile.writeln('// page size varies per exam (see each OmrExamTemplate\'s pageWidthPt/');
  dartFile.writeln('// pageHeightPt), matching the printed PDFs in /answer_sheets.');
  dartFile.writeln('// Regenerate with: cd tool && dart run generate_sheets.dart');
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
          pageFormat: PdfPageFormat(exam.pageWidthPt, exam.pageHeightPt),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.CustomPaint(
            size: PdfPoint(exam.pageWidthPt, exam.pageHeightPt),
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
