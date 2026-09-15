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
import 'package:vector_math/vector_math_64.dart' show Matrix4;

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

/// AT only: half-size of its 6 "outer" markers — the 4 real corner anchors
/// plus the 2 extra mid-sheet dots that sit in line with them (above items
/// 37/61, see [_atEdgeFiducials]) — a tad bigger than the shared
/// [kMarkerHalf] TAT/QTM's corners still use. AT-specific (rather than
/// raising [kMarkerHalf] itself) so TAT/QTM's already-tuned corner search
/// is untouched.
const double kAtEdgeMarkerHalf = 7;

/// AT only: half-size of the 3 purely-decorative centered fiducials (top,
/// mid-grid, bottom — see [_atCenterFiducials]) — smaller than
/// [kAtEdgeMarkerHalf], so the 4 real anchors the decoder actually
/// searches for (plus the 2 edge-aligned dots that echo them) stay
/// visually the most prominent marks on the sheet.
const double kAtCenterMarkerHalf = 4.5;

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
//  - simple: two ID rows -- Last Name, then First Name/MI below it (AT/PT
//    — these are only structurally inspired by third-party
//    commercial tests, so they keep generic branding rather than
//    reproducing OLSAT/16PF's own). The brand block on top of that table
//    is either GuideGrade's own generic wordmark (PT) or NDMU's real
//    letterhead (AT, via ExamSpec.letterheadLines) — see
//    _paintSimpleHeader.
//  - ndmu: the real NDMU Guidance Center letterhead + full ID-field table +
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
// AT only: kGapAfterTable/kGapBeforeGrid trade space with each other, not
// with the header's total height (their sum is unchanged, so
// kSimpleHeaderHeight — and everything the grid below it is positioned
// from — doesn't move). Shrinking the gap above the title/instruction
// block and growing the one below it moves that block up and gives the
// grid's first row (item 1) real clearance from the instruction line
// above it, instead of nearly touching it.
const double kGapAfterTable = 2;
const double kTitleRowHeight = 20;
const double kInstructionRowHeight = 12;
const double kGapBeforeGrid = 16;

/// How much of the simple header's name-row height (see [kTableHeight]) is
/// the printed caption ("Last Name" etc) versus the box row underneath it —
/// shared between [_paintSimpleHeader] (where to draw the divider between
/// caption and boxes) and [_emitTemplate] (how much to clip off the top of
/// the OCR crop rect, so the two can never disagree about where the caption
/// ends and the handwriting/box area begins).
const double kNameCaptionHeight = 14;

/// AT only: the gap between the Last Name row and the First Name/MI row
/// below it (see [_paintSimpleHeader]/[_nameFieldBoxes]) — there is no
/// Exam Code/Batch/Date row any more; that space was reassigned to a
/// second full-height name row instead.
const double kAtGapBetweenIdRows = 2;

/// AT only: the gap kept between the First Name/MI row and the pencil
/// instruction line when [ExamSpec.titleInRightMargin] leaves the title's
/// own row blank (see [_paintSimpleHeader]) -- much smaller than
/// [kTitleRowHeight], since there's no title text to reserve room for here
/// any more.
const double kAtTitleMarginGap = 4;

/// AT only: how many individual per-letter boxes each name field is
/// subdivided into (see [_paintSimpleHeader]) — sized generously enough for
/// a real Filipino surname/given name, not just a few initials. Last Name
/// now has the ID table's full width to itself (its own row — see
/// _nameFieldBoxes), so it gets more boxes than First Name/MI, which share
/// the row below it.
const int kAtLastNameBoxes = 24;
const int kAtFirstNameBoxes = 20;
const int kAtMiBoxes = 2;

const double kSimpleHeaderHeight =
    kBrandRowHeight +
    kSubtitleRowHeight +
    kGapAfterSubtitle +
    kTableHeight + // Last Name row
    kAtGapBetweenIdRows +
    kTableHeight + // First Name/MI row
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

// Compact variant of the NDMU header — same fields, same reading order,
// just tighter row heights/gaps and smaller type. Used only where
// [ExamSpec.compactNdmuHeader] is set (currently TAT's single-page
// landscape layout, whose page has far less vertical room to spare than
// QTM's portrait one), so QTM keeps its current, already-shipped sizing
// untouched.
const double kCompactLetterheadHeight = 38;
const double kCompactGapAfterLetterhead = 3;
const double kCompactIdRowHeight = 15;
const double kCompactGapAfterIdTable = 3;
// Zero -- TAT-compact draws Date/Birth/Age inline in the ID table's
// School/Address rows instead (see _paintNdmuHeader), so there's no
// separate block here to reserve height for. Named zero rather than
// removed from kCompactNdmuHeaderHeight's sum so that sum still reads as
// "every section, in order."
const double kCompactDateScoresHeight = 0;
const double kCompactGapAfterDateScores = 6;
const double kCompactNdmuTitleHeight = 14;
const double kCompactNdmuInstructionHeight = 9;
const double kCompactGapBeforeNdmuGrid = 4;

const double kCompactNdmuHeaderHeight =
    kCompactLetterheadHeight +
    kCompactGapAfterLetterhead +
    kCompactIdRowHeight * kIdRowCount +
    kCompactGapAfterIdTable +
    kCompactDateScoresHeight +
    kCompactGapAfterDateScores +
    kCompactNdmuTitleHeight +
    kCompactNdmuInstructionHeight +
    kCompactGapBeforeNdmuGrid;

// ---------------------------------------------------------------------------
// QTM-only front-page redesign: 6 sections of 10 items in a 3-column x
// 2-row grid, filled column-major (see kExams' QTM entry and
// _layoutQtmGrid) instead of the generic engine's single continuous grid.
// School Last Attended/Address of School Last Attended/Date Today/Birth
// Date/Age/Sex/Scores move to a back page (_paintQtmBackPage); the front
// header shrinks to just the letterhead + a two-row boxed Last Name/(First
// Name+MI) ID table, mirroring AT's own name-box redesign (see
// _paintSimpleHeader) but implemented separately here rather than shared,
// so this can't regress AT's already-verified layout.
// ---------------------------------------------------------------------------

const int kQtmGridCols = 3;
const int kQtmGridRows = 2;
const double kQtmSectionRowGap = 34;

const double kQtmGapBetweenIdRows = 2;
const int kQtmLastNameBoxes = 24;
const int kQtmFirstNameBoxes = 20;
const int kQtmMiBoxes = 2;

/// The gap kept between the First Name/MI row and the pencil instruction
/// line when [ExamSpec.titleInRightMargin] leaves the title's own row
/// blank (see [_paintQtmHeader]) — same idea as AT's [kAtTitleMarginGap].
const double kQtmTitleMarginGap = 4;

const double kQtmHeaderHeight =
    kLetterheadHeight +
    kGapAfterLetterhead +
    kTableHeight + // Last Name row
    kQtmGapBetweenIdRows +
    kTableHeight + // First Name/MI row
    kGapAfterIdTable +
    kNdmuTitleHeight +
    kNdmuInstructionHeight +
    kGapBeforeNdmuGrid;

double headerHeightFor(ExamSpec exam) {
  // Matches both "QTM" itself and the "QTM_Section N" mini-ExamSpecs
  // _layoutQtmGrid builds internally (see its comment on why those need
  // this exact value, not the generic kNdmuHeaderHeight their headerKind
  // would otherwise resolve to).
  if (exam.code.startsWith('QTM')) return kQtmHeaderHeight;
  return switch (exam.headerKind) {
    HeaderKind.simple => kSimpleHeaderHeight,
    HeaderKind.ndmu => exam.compactNdmuHeader ? kCompactNdmuHeaderHeight : kNdmuHeaderHeight,
  };
}

/// Row 30's bubble center sits `(kRowsPerColumn - 1) * kRowPitch` below row
/// 1's, plus bubble radius clearance below that. Same for every exam — only
/// the header above it varies.

double contentHeightFor(ExamSpec exam) =>
    headerHeightFor(exam) + (exam.rowsPerColumn - 1) *
exam.rowPitch + 2 * exam.bubbleRadius;

/// The actual vertical radius bubbles are drawn with — QTM/TAT (NDMU
/// forms) draw slightly flattened ovals rather than true circles (see
/// _paintItems), matching those sheets' real bubble style. Single source
/// of truth for both the PDF drawing and the emitted template's
/// bubbleRadiusYPt, so the decoder's sample region can never disagree
/// with what's actually printed — an earlier version assumed this
/// distinction was purely cosmetic (the decoder always sampled a square
/// sized to the horizontal radius), which diluted a genuinely filled
/// oval bubble's measured fill by roughly half, confirmed against a real
/// scan where it was enough to make every marked item read ambiguous.
double bubbleRadiusYFor(ExamSpec exam) =>
    exam.headerKind == HeaderKind.ndmu ? exam.bubbleRadius * 0.8 : exam.bubbleRadius;

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
  /// mark, rather than hugging the bubble grid) — or, like AT's 2x3
  /// section grid (see [_atCornerMarkers]), whose content bounds don't
  /// decompose into the generic engine's single-grid [contentHeightFor]
  /// math at all. A function rather than a plain list since it needs the
  /// exam's own fields (bubbleRadius, rowPitch, etc.) to compute from,
  /// which don't exist yet at the point this ExamSpec literal is written.
  final List<(double, double)> Function(ExamSpec exam)? cornerMarkersOverride;

  /// NDMU letterhead lines (only used when [headerKind] is
  /// [HeaderKind.ndmu]) — e.g. the center's name, university, and location.
  final List<String> letterheadLines;

  /// Extra visual gap, in points, between an item number's own right edge
  /// and its first bubble's actual left edge (accounting for
  /// [bubbleRadius], so the gap looks the same regardless of bubble size).
  /// Null (the default) keeps the original behavior: the label is drawn
  /// flush against the left edge of the [rowLabelWidth] space reserved for
  /// it, so how much visual gap that leaves depends on the label text's
  /// own width (a 1-digit item number ends up with more breathing room
  /// than a 2-digit one). Setting this instead right-aligns every label to
  /// a consistent gap regardless of digit count — purely a draw-position
  /// change, doesn't touch [rowLabelWidth] or bubble positions at all.
  final double? labelGapPt;

  /// When true, the printed header title is just [title] on its own —
  /// the section name that's otherwise always appended (see
  /// [_paintSimpleHeader]) is left off. Doesn't touch [SectionSpec.name]
  /// itself, which the app still uses at runtime for scoring/answer-key
  /// grouping — this only changes what's drawn on the printed page.
  final bool suppressSectionInTitle;

  /// Uses the compact NDMU header sizing (see kCompactNdmuHeaderHeight)
  /// instead of the normal one. Only meaningful when [headerKind] is
  /// [HeaderKind.ndmu] — for a page with much less vertical room to spare
  /// (TAT's single-page landscape layout), so the grid below it can be
  /// bigger instead of most of the page going to the header.
  final bool compactNdmuHeader;

  /// Stable identifier for this exact printed geometry, hand-bumped
  /// whenever this exam's fiducial/bubble/field layout changes (see
  /// [OmrExamTemplate.templateVersion] for why: it's what stops an old
  /// scan's overlay from silently being redrawn with a newer sheet's
  /// coordinates).
  final String templateVersion;

  /// AT only: skips drawing the title/instruction lines in their normal
  /// horizontal spot in [_paintSimpleHeader] (the space reserved for them
  /// — kTitleRowHeight/kInstructionRowHeight — is left blank, not
  /// reclaimed, so nothing else moves) and instead draws them rotated 90°
  /// in the blank margin strip beside the top-right corner marker (see
  /// [_paintAtRotatedTitle]) — that strip exists because AT's grid doesn't
  /// use the page's full available width (see kAtGridCols's cells), so it
  /// was sitting unused.
  final bool titleInRightMargin;

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
        this.labelGapPt,
        this.suppressSectionInTitle = false,
        this.compactNdmuHeader = false,
        this.titleInRightMargin = false,
        required this.templateVersion,
      });
}

final List<String> _atOdd = const ['A', 'B', 'C', 'D', 'E'];
final List<String> _atEven = const ['F', 'G', 'H', 'J', 'K'];
final List<String> _abcd = const ['A', 'B', 'C', 'D'];
final List<String> _tf = const ['T', 'F'];

final List<ExamSpec> kExams = [
  ExamSpec(
    'TAT',
    'Teaching Aptitude Test (TAT)',
    [
      SectionSpec('Test I', 30, (n) => _abcd),
      SectionSpec('Test II', 80, (n) => _tf),
      SectionSpec('Test III', 20, (n) => _tf),
    ],
    headerKind: HeaderKind.ndmu,
    // Landscape long-bond, swapped from the paper's usual portrait
    // orientation (kLongWidth x kLongHeight) -- see _layoutTatLandscape
    // below for why: this is the one exam whose 3 sections all sit on a
    // single physical page side by side rather than one page per section,
    // and doing that needs the wider dimension as the page's width.
    pageWidthPt: kLongHeight,
    pageHeightPt: kLongWidth,
    letterheadLines: const [
      'Guidance, Honors, and Scholarship Center',
      'Notre Dame of Marbel University',
      'City of Koronadal, South Cotabato',
    ],
    // compactNdmuHeader trims the header from 238pt down to ~164pt (see
    // kCompactNdmuHeaderHeight) -- landscape long-bond is only 612pt tall
    // total, so the normal QTM-sized header alone was eating nearly 40% of
    // the page before a single bubble got drawn. The freed-up ~74pt goes
    // straight to the grid below, which is what let bubbleRadius/
    // choicePitch come back up to exactly match AT/QTM's own (8/26) --
    // an earlier version of this layout had to shrink those below AT's
    // numbers just to fit; with the compact header there's enough room
    // (see _layoutTatLandscape's fit math) not to need that trade-off.
    // rowPitch 25 (vs AT's 27) is the one number still slightly tighter,
    // needed to fit 15 rows/column in the remaining space -- still a 9pt
    // real edge gap, well above the ~2pt gap that caused AT's cross-bubble
    // bleed bug (see AT's own comment below).
    compactNdmuHeader: true,
    bubbleRadius: 8,
    choicePitch: 26,
    rowPitch: 25,
    rowsPerColumn: 15,
    columnGap: 24,
    labelGapPt: 6,
    templateVersion: 'TAT-v1',
  ),
  ExamSpec(
    'QTM',
    'Qualifying Test in Mathematics (QTM)',
    // 6 sections of 10 items each (still 60 total). Printed/keyed item
    // numbers are one continuous 1-60 sequence across all 6, filled
    // column-major -- Left column: 1-10 then 11-20, Middle: 21-30 then
    // 31-40, Right: 41-50 then 51-60 -- see _layoutQtmGrid's
    // _offsetItemNumbers use.
    [
      for (var i = 1; i <= 6; i++) SectionSpec('Section $i', 10, (n) => _abcd),
    ],
    headerKind: HeaderKind.ndmu,
    pageWidthPt: kLongWidth,
    pageHeightPt: kLongHeight,
    letterheadLines: const [
      'Guidance and Testing Center',
      'NOTRE DAME OF MARBEL UNIVERSITY',
      'City of Koronadal, South Cotabato',
    ],
    // choicePitch/bubbleRadius unchanged from before (still match AT's own
    // bubble look). rowPitch tightened from the old single-grid 40 down to
    // fit 2 stacked 10-row blocks per column instead of one 15-row block --
    // see _qtmCellHeight's fit math (kQtmHeaderHeight + 2*cellHeight +
    // kQtmSectionRowGap comfortably inside kLongHeight, verified against
    // the regenerated PDF's actual fill, not computed on paper alone).
    // columnGap widened well past the default 40 -- like AT, the 3-column
    // grid doesn't need the page's full available width to stay legible,
    // and the strip that leaves on the right is exactly where
    // _paintQtmRotatedTitle puts the rotated title, same trick AT uses.
    bubbleRadius: 8,
    choicePitch: 26,
    rowPitch: 33,
    rowsPerColumn: 10,
    columnGap: 85,
    cornerMarkersOverride: _qtmCornerMarkers,
    labelGapPt: 6,
    titleInRightMargin: true,
    templateVersion: 'QTM-redesign-v1',
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
  // divides evenly, no partially-empty column). That first fix used
  // choicePitch: 18 with bubbleRadius: 8, leaving only a 2pt (~0.7mm) gap
  // between adjacent printed bubble *edges* — the decoder's ink-sampling
  // square for each bubble is sized to exactly match its radius, with no
  // built-in margin, so at a 0.7mm real-world gap ordinary photo/warp
  // imprecision was enough for one bubble's printed circle outline to
  // bleed into its neighbor's sample square. That inflates every bubble's
  // ink reading a little, including unmarked ones next to a marked one,
  // which shrinks the marked-vs-runner-up margin sheet-wide — confirmed
  // against real scanned photos of a fully answered sheet: corner
  // detection and the perspective warp were both pixel-accurate (every
  // sample dot landed dead-center on its bubble), yet every single item
  // still came back "ambiguous," which is exactly what universal
  // cross-bubble bleed produces and a geometry problem would not.
  //
  // 3 columns of 24 (still divides 72 evenly, still fits on one page)
  // frees up enough width for choicePitch: 26 instead of 18 — a ~10pt
  // (~3.5mm) edge gap, comparable to a real printed OMR sheet's spacing
  // rather than the print run's minimum legible size.
  ExamSpec(
    'AT',
    'Admission Test (AT)',
    // 6 sections of 12 items each (still 72 total). Printed/keyed item
    // numbers stay a single continuous 1-72 sequence across all 6 (see
    // _layoutAtGrid's _offsetItemNumbers) — only the visual grouping and
    // scoring/answer-key structure are split into sections, matching the
    // odd/even A-E/F-K alternation each local SectionSpec item n computes
    // (n is still 1-12 here; _offsetItemNumbers shifts the *printed*/keyed
    // number afterward, not this choice pattern) against the section's own
    // local position, same alternation the original single-section sheet
    // used. Arranged 3x2 on the page by _layoutAtGrid/_paintAtGridPage
    // instead of the generic engine's single continuous grid.
    [
      for (var i = 1; i <= 6; i++)
        SectionSpec('Section $i', 12, (n) => n.isOdd ? _atOdd : _atEven),
    ],
    bubbleRadius: 8,
    choicePitch: 26,
    // Tighter than a single-grid AT's 27 (and TAT's own 25) -- needed so 2
    // full 12-row section columns plus the mid-grid gap (kAtSectionRowGap)
    // fit under the header on one A4 page. bubbleRadius/choicePitch are
    // untouched (same bubble look as before) -- only row-to-row spacing
    // shrinks, and 24pt still clears twice the 8pt bubble radius with an
    // 8pt real edge gap, well above the ~2pt gap that caused AT's original
    // cross-bubble bleed bug (see the comment above, about choicePitch).
    rowPitch: 23,
    rowsPerColumn: 12,
    cornerMarkersOverride: _atCornerMarkers,
    // Stays on the plain HeaderKind.simple layout -- only the brand block's
    // *content* changes: _paintSimpleHeader draws these letterhead lines
    // instead of the "Guide"+"Grade" wordmark whenever letterheadLines is
    // non-empty, in the exact same fixed vertical budget, so nothing below
    // it (the ID table, title, bubble grid) moves at all.
    letterheadLines: const [
      'Guidance and Testing Center',
      'NOTRE DAME OF MARBEL UNIVERSITY',
      'City of Koronadal, South Cotabato',
    ],
    // Printed header reads just "Admission Test (AT)" -- no "- OLSAT", no
    // per-section suffix (which section name _paintAtGridPage's synthetic
    // headerPage picks doesn't matter because of this). SectionSpec.name
    // above is untouched, so scoring/answer-key grouping at runtime is
    // unaffected -- this only changes what's drawn.
    suppressSectionInTitle: true,
    // A consistent, deliberate gap between each item number and its own
    // bubble -- the original layout (label flush against the reserved
    // rowLabelWidth zone) put 1- and 2-digit numbers at different
    // distances from the bubble and left barely any gap at all for the
    // widest ones. Purely a label draw-position change: bubble positions
    // and rowLabelWidth are untouched.
    labelGapPt: 6,
    // The title/instruction move into the blank margin strip beside the
    // top-right corner marker instead (see _paintAtRotatedTitle) -- the
    // grid's 3x2 section layout doesn't use the page's full width, leaving
    // that strip otherwise empty.
    titleInRightMargin: true,
    templateVersion: 'AT-redesign-v1',
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
        final rowY = exam.contentTop + headerHeightFor(exam) + row * exam.rowPitch;
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

/// Extra horizontal gap between one section's zone and the next, on TAT's
/// combined landscape page -- separate from [ExamSpec.columnGap], which
/// only spaces columns *within* one section's own grid.
const double kTatZoneGap = 32;

/// Extra vertical room, below the NDMU header's natural bottom edge,
/// reserved for each zone's own "TEST I/II/III" label on TAT's combined
/// landscape page -- see [_layoutTatLandscape].
const double kTatZoneLabelHeight = 20;

/// TAT-only: lays out all 3 sections (Test I/II/III) side by side on ONE
/// physical landscape page, instead of the generic engine's one-page-per-
/// section behavior every other exam (including TAT's own former portrait
/// layout) uses. [_layoutExam] always starts a section's columns at
/// [ExamSpec.contentLeft] and gives it a fresh page — there's no way to
/// tell it "keep going, just further right on the same page" without
/// reworking it for every exam. Since TAT is the only exam that currently
/// needs a multi-section shared page, this builds it directly instead:
/// one independent mini-[ExamSpec] per section, each pinned to its own
/// horizontal slice of the page via [ExamSpec.contentLeftOverride], laid
/// out with the proven [_layoutExam] column/row math, then stitched back
/// into one combined [ExamLayout] whose 3 [PagePlacement]s keep their
/// original [SectionSpec] identity (so [_emitTemplate]'s per-section
/// grouping still works) but render onto a single PDF page.
ExamLayout _layoutTatLandscape(ExamSpec exam) {
  double sectionWidth(SectionSpec section, ExamSpec mini) {
    final choiceCount = section.choicesForItem(1).length;
    final cols = (section.itemCount / mini.rowsPerColumn).ceil();
    return cols * _columnWidth(choiceCount, mini.rowLabelWidth, mini.choicePitch) + (cols - 1) * mini.columnGap;
  }

  final pages = <PagePlacement>[];
  var nextLeft = exam.contentLeft;
  for (final section in exam.sections) {
    final mini = ExamSpec(
      '${exam.code}_${section.name}',
      section.name,
      [section],
      headerKind: exam.headerKind, // keeps rowY's header-height offset correct
      compactNdmuHeader: exam.compactNdmuHeader,
      pageWidthPt: exam.pageWidthPt,
      pageHeightPt: exam.pageHeightPt,
      choicePitch: exam.choicePitch,
      rowPitch: exam.rowPitch,
      columnGap: exam.columnGap,
      rowLabelWidth: exam.rowLabelWidth,
      bubbleRadius: exam.bubbleRadius,
      rowsPerColumn: exam.rowsPerColumn,
      contentLeftOverride: nextLeft,
      // Shifted down from the header's natural bottom edge to leave room
      // for this zone's own section-name label (see _paintTatLandscapePage).
      contentTopOverride: exam.contentTop + kTatZoneLabelHeight,
      templateVersion: exam.templateVersion,
    );
    final miniLayout = _layoutExam(mini);
    pages.addAll(miniLayout.pages);
    nextLeft += sectionWidth(section, mini) + kTatZoneGap;
  }
  // Combined content width, for _cornerMarkers to size the shared page's
  // markers to every zone at once -- not any individual mini-layout's own
  // (ndmu-header-floored) contentWidth.
  final combinedWidth = nextLeft - kTatZoneGap - exam.contentLeft;
  return ExamLayout(exam, pages, combinedWidth);
}

/// Paints TAT's combined landscape page: corner markers + the NDMU header
/// once (spanning the full combined width), then each section's own
/// zone label + bubble grid, side by side. Companion to
/// [_layoutTatLandscape] — see its comment for why this exam needs a
/// dedicated paint path instead of the generic [_paintPage].
void _paintTatLandscapePage(PdfGraphics canvas, ExamSpec exam, ExamLayout layout, PdfFont regular, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;

  canvas.setColor(kBlack);
  for (final corner in _cornerMarkers(layout)) {
    canvas.drawRect(corner.$1 - kMarkerHalf, flip(corner.$2) - kMarkerHalf, kMarkerHalf * 2, kMarkerHalf * 2);
    canvas.fillPath();
  }

  // Synthetic page just to drive _paintNdmuHeader's title text — section
  // name set to match the exam title (minus its "(XX)" suffix) so the
  // header's own "section differs from title" logic cleanly omits a
  // redundant suffix, same as QTM's single self-named section does today.
  final title1 = exam.title.replaceAll(RegExp(r'\s*\([A-Z]+\)$'), '').toUpperCase();
  final headerPage = PagePlacement(SectionSpec(title1, 0, (n) => const []), 1, 1, const []);
  _paintNdmuHeader(canvas, exam, headerPage, layout, regular, bold, flip);

  // Sits near the top of the kTatZoneLabelHeight gap reserved below the
  // header, not the bottom -- a bigger gap alone isn't enough once you
  // account for real glyph height (an 8pt label baseline placed too close
  // to the grid still visually clips the first row's bubbles).
  final headerBottom = exam.contentTop + headerHeightFor(exam);
  for (final page in layout.pages) {
    canvas.setColor(kNavy);
    final zoneLeft = page.items.first.bubbles.first.x - exam.rowLabelWidth;
    canvas.drawString(bold, 7, page.section.name.toUpperCase(), zoneLeft, flip(headerBottom + 9));
    _paintItems(canvas, page.items, exam, regular, bold, flip);
  }
}

/// Paints AT's combined 2x3-section-grid page: corner markers + extra
/// decorative fiducials + the simple header once, then each section's own
/// bubble column. Companion to [_layoutAtGrid] — see its comment.
void _paintAtGridPage(PdfGraphics canvas, ExamSpec exam, ExamLayout layout, PdfFont regular, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;

  void drawMarker((double, double) point, double half) {
    canvas.drawRect(point.$1 - half, flip(point.$2) - half, half * 2, half * 2);
    canvas.fillPath();
  }

  canvas.setColor(kBlack);
  // 6 "outer" markers -- the 4 real corner anchors plus the 2 extra dots
  // that sit in line with them (above items 37/61) -- drawn a tad bigger
  // than the 3 purely-decorative centered ones below, so the sheet's own
  // perimeter reads as the most prominent set of marks.
  for (final corner in _cornerMarkers(layout)) {
    drawMarker(corner, kAtEdgeMarkerHalf);
  }
  for (final marker in _atEdgeFiducials(exam)) {
    drawMarker(marker, kAtEdgeMarkerHalf);
  }
  for (final marker in _atCenterFiducials(exam)) {
    drawMarker(marker, kAtCenterMarkerHalf);
  }

  // Synthetic page just to drive _paintSimpleHeader's title text --
  // suppressSectionInTitle is already set for AT, so which section this
  // dummy page names never shows up in the printed title.
  final headerPage = PagePlacement(exam.sections.first, 1, 1, const []);
  _paintSimpleHeader(canvas, exam, headerPage, layout, regular, bold, flip);
  if (exam.titleInRightMargin) {
    _paintAtRotatedTitle(canvas, exam, bold);
  }

  for (final page in layout.pages) {
    _paintItems(canvas, page.items, exam, regular, bold, flip);
  }
}

/// AT only: draws the exam title rotated -90° (reading top-to-bottom) in
/// the blank margin strip beside the top-right corner marker — instead of
/// its normal horizontal spot in the header (see
/// [ExamSpec.titleInRightMargin], which also skips drawing it there). The
/// pencil instruction stays in its usual horizontal spot (below the First
/// Name/MI row — see [_paintSimpleHeader]); only the title moves.
/// The margin strip is otherwise empty because AT's 3x2 section grid
/// doesn't use the page's full available width (see [_atGridWidth]).
void _paintAtRotatedTitle(PdfGraphics canvas, ExamSpec exam, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;

  final rightCorner = exam.contentLeft + _atGridWidth(exam) + exam.markerPad;
  final titleX = rightCorner + kAtEdgeMarkerHalf + 9;
  // Top of the title -- level with the grid's first row (item 25's row,
  // same headerBottom every section-row-0 item sits on), reading downward
  // (toward bigger topLeftY) from there alongside items 25-36. topLeftY is
  // the text's own bottom-left corner before rotation, which becomes its
  // TOP-most point after the -90° turn.
  final startY = exam.contentTop + headerHeightFor(exam);

  canvas.setColor(kNavy);
  canvas.saveContext();
  canvas.setTransform(Matrix4.identity()
    ..translateByDouble(titleX, flip(startY), 0, 1)
    ..rotateZ(-math.pi / 2));
  canvas.drawString(bold, 11, exam.title.toUpperCase(), 0, 0);
  canvas.restoreContext();
}

/// QTM's redesigned front-page header: the same NDMU letterhead box as
/// before, then two boxed ID rows (Last Name full width; First Name/MI
/// sharing the row below it — see [_qtmNameFieldBoxes]), then the title
/// and pencil instruction. Everything the old header also drew — School
/// Last Attended, Address of School Last Attended, Date Today, Birth
/// Date, Age, Sex, Scores — moves to [_paintQtmBackPage] instead. A
/// dedicated function rather than an extension of [_paintNdmuHeader] (used
/// by TAT too) so TAT's own header logic is completely untouched.
void _paintQtmHeader(
  PdfGraphics canvas,
  ExamSpec exam,
  ExamLayout layout,
  PdfFont regular,
  PdfFont bold,
  double Function(double) flip,
) {
  var y = exam.contentTop;
  final width = layout.contentWidth;

  // Letterhead -- no bordered box (unlike TAT/QTM's old _paintNdmuHeader
  // letterhead), just the centered lines directly on the page.
  var ly = y + 13;
  for (var i = 0; i < exam.letterheadLines.length; i++) {
    final line = exam.letterheadLines[i];
    final size = i == 1 ? 12.0 : 8.0; // the university name (line 2) stands out
    final font = i == 1 ? bold : regular;
    final metrics = font.stringMetrics(line) * size;
    final textX = exam.contentLeft + (width - metrics.advanceWidth) / 2;
    canvas.setColor(i == 1 ? kNavy : kGray);
    canvas.drawString(font, size, line, textX, flip(ly));
    ly += size + 4;
  }
  y += kLetterheadHeight + kGapAfterLetterhead;

  // Two boxed ID rows: Last Name full width, then First Name/MI below it
  // -- same per-letter-box idea as AT's _paintSimpleHeader, duplicated
  // here rather than shared (see this function's own doc comment).
  final nameBoxes = _qtmNameFieldBoxes(layout);

  void drawBoxedRow(double rowY, List<(String, double, int)> columns) {
    canvas.setColor(kBlack);
    canvas.setLineWidth(1);
    canvas.drawRect(exam.contentLeft, flip(rowY + kTableHeight), width, kTableHeight);
    canvas.strokePath();
    var colX = exam.contentLeft;
    for (final (label, w, boxCount) in columns) {
      canvas.setLineWidth(1);
      canvas.drawLine(colX, flip(rowY), colX, flip(rowY + kTableHeight));
      canvas.strokePath();
      canvas.setColor(kGray);
      canvas.drawString(regular, 8, label, colX + 3, flip(rowY + 10));
      canvas.setColor(kBlack);
      canvas.setLineWidth(0.75);
      canvas.drawLine(colX, flip(rowY + kNameCaptionHeight), colX + w, flip(rowY + kNameCaptionHeight));
      canvas.strokePath();
      final boxWidth = w / boxCount;
      for (var i = 1; i < boxCount; i++) {
        final bx = colX + boxWidth * i;
        canvas.drawLine(bx, flip(rowY + kNameCaptionHeight), bx, flip(rowY + kTableHeight));
        canvas.strokePath();
      }
      colX += w;
    }
  }

  drawBoxedRow(y, [('Last Name', nameBoxes.lastName.width, kQtmLastNameBoxes)]);
  y += kTableHeight + kQtmGapBetweenIdRows;
  drawBoxedRow(y, [
    ('First Name', nameBoxes.firstName.width, kQtmFirstNameBoxes),
    ('MI', nameBoxes.middleInitial.width, kQtmMiBoxes),
  ]);
  y += kTableHeight + kGapAfterIdTable;

  // Title (+ page indicator). Skipped here when titleInRightMargin is set
  // (QTM, like AT) -- _paintQtmRotatedTitle draws it instead, rotated in
  // the right margin strip freed up by widening columnGap (see kExams'
  // QTM entry). The space itself stays reserved (y still advances) so
  // nothing below moves.
  if (!exam.titleInRightMargin) {
    canvas.setColor(kNavy);
    canvas.drawString(bold, 12, exam.title.toUpperCase(), exam.contentLeft, flip(y + 13));
  }
  // Small gap instead of the title's full row height when titleInRightMargin
  // leaves this row blank -- same trick as AT's kAtTitleMarginGap, so the
  // instruction below sits close to the First Name/MI row instead of
  // leaving a tall blank gap where the title used to be.
  y += exam.titleInRightMargin ? kQtmTitleMarginGap : kNdmuTitleHeight;

  canvas.setColor(kGray);
  canvas.drawString(regular, 7, 'Use a No. 2 pencil. Fill the circle completely.', exam.contentLeft, flip(y + 9));
}

/// Paints QTM's combined 3x2-section-grid page: corner markers, the
/// redesigned header, then each section's own bubble column. Companion to
/// [_layoutQtmGrid] — see its comment.
void _paintQtmGridPage(PdfGraphics canvas, ExamSpec exam, ExamLayout layout, PdfFont regular, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;

  void drawMarker((double, double) point, double half) {
    canvas.drawRect(point.$1 - half, flip(point.$2) - half, half * 2, half * 2);
    canvas.fillPath();
  }

  canvas.setColor(kBlack);
  // 6 "outer" markers -- the 4 real corner anchors plus the 2 extra dots
  // that sit in line with them -- drawn a tad bigger than the 3 purely-
  // decorative centered ones below, matching AT's own scheme (see
  // _atEdgeFiducials/_atCenterFiducials's comments).
  for (final corner in _cornerMarkers(layout)) {
    drawMarker(corner, kAtEdgeMarkerHalf);
  }
  for (final marker in _qtmEdgeFiducials(exam)) {
    drawMarker(marker, kAtEdgeMarkerHalf);
  }
  for (final marker in _qtmCenterFiducials(exam)) {
    drawMarker(marker, kAtCenterMarkerHalf);
  }

  _paintQtmHeader(canvas, exam, layout, regular, bold, flip);
  if (exam.titleInRightMargin) {
    _paintQtmRotatedTitle(canvas, exam, bold);
  }

  for (final page in layout.pages) {
    _paintItems(canvas, page.items, exam, regular, bold, flip);
  }
}

/// QTM only: draws the exam title rotated -90° (reading top-to-bottom) in
/// the margin strip freed up by widening columnGap (see kExams' QTM
/// entry) — instead of its normal horizontal spot in the header (see
/// [ExamSpec.titleInRightMargin], which also skips drawing it there in
/// [_paintQtmHeader]). Mirrors AT's own [_paintAtRotatedTitle].
void _paintQtmRotatedTitle(PdfGraphics canvas, ExamSpec exam, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;

  final rightCorner = exam.contentLeft + _qtmGridWidth(exam) + exam.markerPad;
  final titleX = rightCorner + kAtEdgeMarkerHalf + 9;
  // Top of the title -- level with the grid's first row, reading downward
  // from there. topLeftY is the text's own bottom-left corner before
  // rotation, which becomes its TOP-most point after the -90° turn.
  final startY = exam.contentTop + headerHeightFor(exam);

  canvas.setColor(kNavy);
  canvas.saveContext();
  canvas.setTransform(Matrix4.identity()
    ..translateByDouble(titleX, flip(startY), 0, 1)
    ..rotateZ(-math.pi / 2));
  canvas.drawString(bold, 11, exam.title.toUpperCase(), 0, 0);
  canvas.restoreContext();
}

/// QTM's back page: the fields the redesigned front page no longer has
/// room for (School Last Attended, Address of School Last Attended, Date
/// Today, Birth Date, Age, Sex, Scores) — filled in by hand, never
/// scanned/decoded (no corner markers, not part of OmrExamTemplate/
/// _emitTemplate at all). Mirrors AT's own back-page Score Record (see
/// [_paintAtScoreRecordPage]) in spirit, just with QTM's own, simpler set
/// of fields.
void _paintQtmBackPage(PdfGraphics canvas, ExamSpec exam, PdfFont regular, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;
  final contentWidth = exam.pageWidthPt - exam.contentLeft - exam.markerPad - exam.pageMargin;
  var y = exam.contentTop;

  canvas.setColor(kNavy);
  canvas.drawString(bold, 13, 'Additional Information', exam.contentLeft, flip(y + 13));
  y += 26;

  // School Last Attended / Address of School Last Attended -- open-line
  // fields, same bordered-table style as the front page's old ID rows.
  const infoRows = ['School Last Attended', 'Address of School Last Attended'];
  const infoRowHeight = 24.0;
  final infoTableHeight = infoRowHeight * infoRows.length;
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(exam.contentLeft, flip(y + infoTableHeight), contentWidth, infoTableHeight);
  canvas.strokePath();
  for (var i = 1; i < infoRows.length; i++) {
    final lineY = y + infoRowHeight * i;
    canvas.drawLine(exam.contentLeft, flip(lineY), exam.contentLeft + contentWidth, flip(lineY));
    canvas.strokePath();
  }
  for (var i = 0; i < infoRows.length; i++) {
    canvas.setColor(kGray);
    canvas.drawString(regular, 9, infoRows[i], exam.contentLeft + 6, flip(y + infoRowHeight * i + 15));
  }
  y += infoTableHeight + 20;

  // Date Today / Birth Date / Age -- bordered table, same style as the
  // School/Address one above (label column + 3 more columns; the Date
  // rows use those 3 for Year/Month/Day, the Age row repurposes them for
  // the age value and Sex).
  const dateRows = ['Date Today', 'Birth Date', 'Age'];
  const dateRowHeight = 24.0;
  final dateTableHeight = dateRowHeight * dateRows.length;
  final dateLabelWidth = contentWidth * 0.28;
  final dateColWidth = (contentWidth - dateLabelWidth) / 3;
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(exam.contentLeft, flip(y + dateTableHeight), contentWidth, dateTableHeight);
  canvas.strokePath();
  for (var i = 1; i < dateRows.length; i++) {
    final lineY = y + dateRowHeight * i;
    canvas.drawLine(exam.contentLeft, flip(lineY), exam.contentLeft + contentWidth, flip(lineY));
    canvas.strokePath();
  }
  for (var i = 1; i < 4; i++) {
    final lineX = exam.contentLeft + dateLabelWidth + dateColWidth * (i - 1);
    canvas.drawLine(lineX, flip(y), lineX, flip(y + dateTableHeight));
    canvas.strokePath();
  }
  for (var i = 0; i < dateRows.length; i++) {
    final rowY = y + dateRowHeight * i;
    canvas.setColor(kGray);
    canvas.drawString(regular, 9, dateRows[i], exam.contentLeft + 6, flip(rowY + 15));
    final entries = i < 2 ? const ['Year _____', 'Month _____', 'Day _____'] : const ['_____ yrs.', 'Sex: M ( )', 'F ( )'];
    for (var c = 0; c < 3; c++) {
      final colX = exam.contentLeft + dateLabelWidth + dateColWidth * c;
      canvas.drawString(regular, 9, entries[c], colX + 6, flip(rowY + 15));
    }
  }
  y += dateTableHeight + 20;

  // Scores.
  canvas.setColor(kNavy);
  canvas.drawString(bold, 12, 'Scores', exam.contentLeft, flip(y + 12));
  y += 20;
  const scoreRows = ['Raw Score', 'Standard Score', 'Test Booklet No.'];
  const scoreRowHeight = 22.0;
  const scoreEntryWidth = 110.0;
  final scoreLabelWidth = contentWidth - scoreEntryWidth;
  final scoreTableHeight = scoreRowHeight * scoreRows.length;
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(exam.contentLeft, flip(y + scoreTableHeight), contentWidth, scoreTableHeight);
  canvas.strokePath();
  for (var i = 1; i < scoreRows.length; i++) {
    final lineY = y + scoreRowHeight * i;
    canvas.drawLine(exam.contentLeft, flip(lineY), exam.contentLeft + contentWidth, flip(lineY));
    canvas.strokePath();
  }
  final scoreEntryX = exam.contentLeft + scoreLabelWidth;
  canvas.drawLine(scoreEntryX, flip(y), scoreEntryX, flip(y + scoreTableHeight));
  canvas.strokePath();
  for (var i = 0; i < scoreRows.length; i++) {
    canvas.setColor(kGray);
    canvas.drawString(regular, 9, scoreRows[i], exam.contentLeft + 6, flip(y + scoreRowHeight * i + 15));
  }
}

/// The 4 corner marker points (top-left-origin, points), sized to the
/// widest page this exam actually uses so every page's content — including
/// narrower sections in a multi-page exam like TAT — stays safely inside a
/// single template-level marker rectangle.
List<(double, double)> _cornerMarkers(ExamLayout layout) {
  final exam = layout.exam;
  if (exam.cornerMarkersOverride != null) return exam.cornerMarkersOverride!(exam);
  final right = exam.contentLeft + layout.contentWidth + exam.markerPad;
  final bottom = exam.contentTop + contentHeightFor(exam) + exam.markerPad;
  return [(exam.pageMargin, exam.pageMargin), (right, exam.pageMargin), (exam.pageMargin, bottom), (right, bottom)];
}

/// AT only: the 6 "Section N" sections (see kExams' AT entry) are arranged
/// 3 columns x 2 rows on one page instead of the generic engine's one-
/// section-per-page behavior — same reason and same technique as
/// [_layoutTatLandscape] (see its comment), just a 2D grid instead of a
/// single row. Each cell is one section's own single column of
/// [ExamSpec.rowsPerColumn] items (12), sized by [_atCellWidth]/
/// [_atCellHeight].
const int kAtGridCols = 3;
const int kAtGridRows = 2;

/// Vertical gap between grid row 1 and row 2 — also where the extra
/// mid-sheet fiducials sit (see [_atEdgeFiducials]/[_atCenterFiducials]).
const double kAtSectionRowGap = 36;

double _atCellWidth(ExamSpec exam) =>
    _columnWidth(5, exam.rowLabelWidth, exam.choicePitch); // AT: always 5 choices/item
double _atCellHeight(ExamSpec exam) =>
    (exam.rowsPerColumn - 1) * exam.rowPitch + 2 * exam.bubbleRadius;
double _atGridWidth(ExamSpec exam) =>
    kAtGridCols * _atCellWidth(exam) + (kAtGridCols - 1) * exam.columnGap;
double _atGridHeight(ExamSpec exam) =>
    kAtGridRows * _atCellHeight(exam) + (kAtGridRows - 1) * kAtSectionRowGap;

/// AT's corner-marker override (see [ExamSpec.cornerMarkersOverride]) — the
/// generic [_cornerMarkers]/[contentHeightFor] math assumes one continuous
/// grid below the header, which doesn't describe AT's 2-row section grid,
/// so this computes the real bottom-right bound directly from the grid's
/// own geometry instead.
List<(double, double)> _atCornerMarkers(ExamSpec exam) {
  final right = exam.contentLeft + _atGridWidth(exam) + exam.markerPad;
  final bottom = exam.contentTop + headerHeightFor(exam) + _atGridHeight(exam) + exam.markerPad;
  return [
    (exam.pageMargin, exam.pageMargin),
    (right, exam.pageMargin),
    (exam.pageMargin, bottom),
    (right, bottom),
  ];
}

/// AT only: the 2 extra mid-sheet fiducials that sit in line with the 4
/// real corner anchors (above items 37/61 — same x as [_atCornerMarkers],
/// not the grid's own left/right content edge, which sits kMarkerPad
/// further in) so they form one straight vertical line down each side of
/// the page with the corners above/below them, matching the reference
/// design. Drawn at [kAtEdgeMarkerHalf], same as the corners — see
/// [_atCenterFiducials] for the 3 smaller, purely-decorative ones.
List<(double, double)> _atEdgeFiducials(ExamSpec exam) {
  final gridWidth = _atGridWidth(exam);
  final cellHeight = _atCellHeight(exam);
  final headerBottom = exam.contentTop + headerHeightFor(exam);
  final left = exam.pageMargin;
  final right = exam.contentLeft + gridWidth + exam.markerPad;
  final midY = headerBottom + cellHeight + kAtSectionRowGap / 2;
  return [(left, midY), (right, midY)];
}

/// AT only: 3 extra square fiducials beyond the 4 real corner-anchor
/// markers and the 2 edge-aligned ones (see [_atEdgeFiducials]) — purely
/// decorative/visual (matching the reference design), never part of
/// [ExamSpec.cornerMarkersOverride]/[OmrExamTemplate.cornerMarkers], so the
/// decoder (which always expects exactly 4 corner markers — see
/// omr_decoder_native.dart's quadrant-based corner search) never sees or
/// relies on them. One above the grid, one between grid row 1 and row 2
/// (grid-center, between the two edge-aligned dots), one below the grid.
/// Drawn smaller, at [kAtCenterMarkerHalf].
List<(double, double)> _atCenterFiducials(ExamSpec exam) {
  final gridWidth = _atGridWidth(exam);
  final cellHeight = _atCellHeight(exam);
  final headerBottom = exam.contentTop + headerHeightFor(exam);
  final center = exam.contentLeft + gridWidth / 2;
  // Clear of both the grid's first bubble row below (whose bubbles reach up
  // to bubbleRadius above headerBottom) and the instruction line above --
  // kGapBeforeGrid alone (10pt) isn't enough clearance for a 12pt marker
  // plus an 8pt bubble radius, which is what put an earlier version of this
  // dot on top of item 13's row; centering it in the instruction row's own
  // band (headerBottom - 16) was still only a 2pt gap above the bubble row,
  // visually crowded. Raised further so its bottom edge clears the bubble
  // row by a real margin, sitting level with the instruction line's own
  // text rather than right on top of the grid. That row's text is
  // left-aligned and short, well clear of this marker's centered x
  // position either way.
  final topY = headerBottom - 20;
  final midY = headerBottom + cellHeight + kAtSectionRowGap / 2;
  final bottomY = headerBottom + 2 * cellHeight + kAtSectionRowGap + exam.markerPad / 2;
  return [(center, topY), (center, midY), (center, bottomY)];
}

/// Shifts every item's printed/keyed number by [offset] — used so AT's 6
/// sections read as one continuous 1-72 sequence (13, 14, ... in Section 2,
/// not a restart at 1) even though each is still laid out and scored as its
/// own [SectionSpec]/[OmrSection]. Bubble positions are untouched.
PagePlacement _offsetItemNumbers(PagePlacement page, int offset) {
  return PagePlacement(
    page.section,
    page.pageNumber,
    page.pageCount,
    [for (final item in page.items) ItemPlacement(item.itemNumber + offset, item.bubbles)],
  );
}

ExamLayout _layoutAtGrid(ExamSpec exam) {
  final cellWidth = _atCellWidth(exam);
  final cellHeight = _atCellHeight(exam);
  final pages = <PagePlacement>[];
  var itemOffset = 0;
  for (var i = 0; i < exam.sections.length; i++) {
    final row = i ~/ kAtGridCols;
    final col = i % kAtGridCols;
    final section = exam.sections[i];
    final mini = ExamSpec(
      '${exam.code}_${section.name}',
      section.name,
      [section],
      headerKind: exam.headerKind,
      pageWidthPt: exam.pageWidthPt,
      pageHeightPt: exam.pageHeightPt,
      choicePitch: exam.choicePitch,
      rowPitch: exam.rowPitch,
      columnGap: exam.columnGap,
      rowLabelWidth: exam.rowLabelWidth,
      bubbleRadius: exam.bubbleRadius,
      rowsPerColumn: exam.rowsPerColumn,
      // Relative to exam.contentTop, not the header's bottom edge -- the
      // mini's own _layoutExam call re-adds headerHeightFor(mini) itself
      // (equal to headerHeightFor(exam), same headerKind), same trick
      // _layoutTatLandscape's mini specs use (see its comment).
      contentLeftOverride: exam.contentLeft + col * (cellWidth + exam.columnGap),
      contentTopOverride: exam.contentTop + row * (cellHeight + kAtSectionRowGap),
      templateVersion: exam.templateVersion,
    );
    pages.addAll(_layoutExam(mini).pages.map((p) => _offsetItemNumbers(p, itemOffset)));
    itemOffset += section.itemCount;
  }
  return ExamLayout(exam, pages, _atGridWidth(exam));
}

double _qtmCellWidth(ExamSpec exam) =>
    _columnWidth(4, exam.rowLabelWidth, exam.choicePitch); // QTM: always 4 choices/item (A-D)
double _qtmCellHeight(ExamSpec exam) =>
    (exam.rowsPerColumn - 1) * exam.rowPitch + 2 * exam.bubbleRadius;
double _qtmGridWidth(ExamSpec exam) =>
    kQtmGridCols * _qtmCellWidth(exam) + (kQtmGridCols - 1) * exam.columnGap;
double _qtmGridHeight(ExamSpec exam) =>
    kQtmGridRows * _qtmCellHeight(exam) + (kQtmGridRows - 1) * kQtmSectionRowGap;

/// QTM's corner-marker override (see [ExamSpec.cornerMarkersOverride]) —
/// same reasoning as [_atCornerMarkers]: the generic [_cornerMarkers]/
/// [contentHeightFor] math assumes one continuous grid below the header,
/// which doesn't describe QTM's 2-row section grid either.
List<(double, double)> _qtmCornerMarkers(ExamSpec exam) {
  final right = exam.contentLeft + _qtmGridWidth(exam) + exam.markerPad;
  final bottom = exam.contentTop + headerHeightFor(exam) + _qtmGridHeight(exam) + exam.markerPad;
  return [
    (exam.pageMargin, exam.pageMargin),
    (right, exam.pageMargin),
    (exam.pageMargin, bottom),
    (right, bottom),
  ];
}

/// QTM only: the 6 "Section N" sections (see kExams' QTM entry) are
/// arranged 3 columns x 2 rows, filled COLUMN-major (Left column gets
/// items 1-10 then 11-20, Middle 21-30 then 31-40, Right 41-50 then
/// 51-60) — unlike AT's row-major 3x2 grid (see [_layoutAtGrid]), per the
/// requested "Left/Middle/Right, above/below" reading order. Otherwise the
/// same technique: one mini-[ExamSpec] per section, pinned to its grid
/// cell via [ExamSpec.contentLeftOverride]/[contentTopOverride], laid out
/// with [_layoutExam], then globally renumbered with [_offsetItemNumbers]
/// so the printed/keyed item numbers read as one continuous 1-60 sequence.
ExamLayout _layoutQtmGrid(ExamSpec exam) {
  final cellWidth = _qtmCellWidth(exam);
  final cellHeight = _qtmCellHeight(exam);
  final pages = <PagePlacement>[];
  var itemOffset = 0;
  for (var i = 0; i < exam.sections.length; i++) {
    final col = i ~/ kQtmGridRows;
    final row = i % kQtmGridRows;
    final section = exam.sections[i];
    final mini = ExamSpec(
      '${exam.code}_${section.name}',
      section.name,
      [section],
      headerKind: exam.headerKind,
      pageWidthPt: exam.pageWidthPt,
      pageHeightPt: exam.pageHeightPt,
      choicePitch: exam.choicePitch,
      rowPitch: exam.rowPitch,
      columnGap: exam.columnGap,
      rowLabelWidth: exam.rowLabelWidth,
      bubbleRadius: exam.bubbleRadius,
      rowsPerColumn: exam.rowsPerColumn,
      // Relative to exam.contentTop, not the header's bottom edge -- the
      // mini's own _layoutExam call re-adds headerHeightFor(mini) itself
      // (equal to headerHeightFor(exam) since headerHeightFor special-cases
      // any "QTM"-prefixed code), same trick _layoutAtGrid's mini specs use.
      contentLeftOverride: exam.contentLeft + col * (cellWidth + exam.columnGap),
      contentTopOverride: exam.contentTop + row * (cellHeight + kQtmSectionRowGap),
      templateVersion: exam.templateVersion,
    );
    pages.addAll(_layoutExam(mini).pages.map((p) => _offsetItemNumbers(p, itemOffset)));
    itemOffset += section.itemCount;
  }
  return ExamLayout(exam, pages, _qtmGridWidth(exam));
}

/// QTM's Last Name/First Name/MI box geometry — same two-row idea as AT's
/// [_nameFieldBoxes] HeaderKind.simple branch (Last Name gets its own
/// full-width row; First Name/MI share the row below it), but computed
/// separately since QTM's header (letterhead + these two rows only, no
/// School/Address/Date/Scores) no longer matches the generic
/// HeaderKind.ndmu layout the shared [_nameFieldBoxes] assumes.
({_FieldBox lastName, _FieldBox firstName, _FieldBox middleInitial}) _qtmNameFieldBoxes(ExamLayout layout) {
  final exam = layout.exam;
  final lastY = exam.contentTop + kLetterheadHeight + kGapAfterLetterhead;
  final firstMiY = lastY + kTableHeight + kQtmGapBetweenIdRows;
  final tableWidth = layout.contentWidth;
  final firstWidth = tableWidth * 0.85;
  final miWidth = tableWidth * 0.15;
  return (
    lastName: (x: exam.contentLeft, y: lastY, width: tableWidth, height: kTableHeight),
    firstName: (x: exam.contentLeft, y: firstMiY, width: firstWidth, height: kTableHeight),
    middleInitial: (x: exam.contentLeft + firstWidth, y: firstMiY, width: miWidth, height: kTableHeight),
  );
}

/// QTM only: the 2 extra fiducials that sit in line with the 4 real corner
/// anchors, at the row-gap between each column's "above" and "below"
/// block — same idea as AT's [_atEdgeFiducials], reusing its
/// [kAtEdgeMarkerHalf] sizing (both real corners and these draw at that
/// size for QTM too — see [_paintQtmGridPage]).
List<(double, double)> _qtmEdgeFiducials(ExamSpec exam) {
  final gridWidth = _qtmGridWidth(exam);
  final cellHeight = _qtmCellHeight(exam);
  final headerBottom = exam.contentTop + headerHeightFor(exam);
  final left = exam.pageMargin;
  final right = exam.contentLeft + gridWidth + exam.markerPad;
  final midY = headerBottom + cellHeight + kQtmSectionRowGap / 2;
  return [(left, midY), (right, midY)];
}

/// QTM only: 3 extra square fiducials beyond the 4 real corner-anchor
/// markers and the 2 edge-aligned ones (see [_qtmEdgeFiducials]) — purely
/// decorative/visual, never part of [OmrExamTemplate.cornerMarkers] (see
/// [_atCenterFiducials]'s doc comment for why that's safe). One above the
/// grid, one at the row-gap (grid-center, between the two edge-aligned
/// dots), one below the grid. Drawn smaller, at [kAtCenterMarkerHalf].
List<(double, double)> _qtmCenterFiducials(ExamSpec exam) {
  final gridWidth = _qtmGridWidth(exam);
  final cellHeight = _qtmCellHeight(exam);
  final headerBottom = exam.contentTop + headerHeightFor(exam);
  final center = exam.contentLeft + gridWidth / 2;
  // Same clearance reasoning as AT's _atCenterFiducials: comfortably above
  // the grid's first bubble row, not squeezed into the instruction gap.
  final topY = headerBottom - 20;
  final midY = headerBottom + cellHeight + kQtmSectionRowGap / 2;
  final bottomY = headerBottom + 2 * cellHeight + kQtmSectionRowGap + exam.markerPad / 2;
  return [(center, topY), (center, midY), (center, bottomY)];
}

/// The extra interior registration marks emitted into
/// [OmrExamTemplate.interiorFiducials] for exams that print them — reuses
/// the exact same position functions the PDF painters draw from
/// ([_atEdgeFiducials]/[_atCenterFiducials]/[_qtmEdgeFiducials]/
/// [_qtmCenterFiducials]), so the emitted template and the printed sheet
/// can never disagree about where these marks are. Empty for any exam that
/// doesn't print them (TAT, and any future exam that isn't AT/QTM) — the
/// decoder's mesh-correction stage is entirely opt-in per template (see
/// [OmrExamTemplate.interiorFiducials]'s doc comment).
/// (role name matching `OmrFiducialRole`'s enum values, x, y in page
/// points, half-size in page points) — a plain tuple rather than the real
/// `OmrFiducial` type, since this tool is its own standalone package (see
/// its pubspec) and never imports the app's omr_templates.dart; `_schema`
/// above is only ever emitted as generated text, never compiled here.
List<(String, double, double, double)> _interiorFiducialsFor(ExamSpec exam) {
  List<(double, double)> edges;
  List<(double, double)> centers;
  if (exam.code == 'AT') {
    edges = _atEdgeFiducials(exam);
    centers = _atCenterFiducials(exam);
  } else if (exam.code == 'QTM') {
    edges = _qtmEdgeFiducials(exam);
    centers = _qtmCenterFiducials(exam);
  } else {
    return const [];
  }
  return [
    ('dividerLeft', edges[0].$1, edges[0].$2, kAtEdgeMarkerHalf),
    ('dividerRight', edges[1].$1, edges[1].$2, kAtEdgeMarkerHalf),
    ('centerAboveAnswers', centers[0].$1, centers[0].$2, kAtCenterMarkerHalf),
    ('centerAtDivider', centers[1].$1, centers[1].$2, kAtCenterMarkerHalf),
    ('centerBelowAnswers', centers[2].$1, centers[2].$2, kAtCenterMarkerHalf),
  ];
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

  _paintItems(canvas, page.items, exam, regular, bold, flip);
}

/// Draws item-number labels + bubble ovals for one list of placed items.
/// Shared by every per-section page ([_paintPage]) and by TAT's combined
/// single-page landscape layout ([_paintTatLandscapePage]), which draws
/// this once per section-zone on the same page.
void _paintItems(
  PdfGraphics canvas,
  List<ItemPlacement> items,
  ExamSpec exam,
  PdfFont regular,
  PdfFont bold,
  double Function(double) flip,
) {
  // QTM/TAT (NDMU forms) draw slightly elongated ovals rather than perfect
  // circles, matching those sheets' actual bubble style. Not just cosmetic
  // — the decoder samples a region sized to bubbleRadiusYFor(exam), so
  // this and _emitTemplate's bubbleRadiusYPt must always agree with what's
  // actually drawn here.
  final bubbleRx = exam.bubbleRadius;
  final bubbleRy = bubbleRadiusYFor(exam);
  for (final item in items) {
    canvas.setColor(kBlack);
    final labelStr = '${item.itemNumber}.';
    final double labelX;
    if (exam.labelGapPt != null) {
      // Right-align: every label ends the same fixed distance from the
      // bubble's actual left edge, regardless of how many digits the
      // item number has (a left-aligned label of varying width, the
      // original behavior below, left a different -- and for the widest
      // numbers, barely-there -- gap per item).
      final labelWidth = (regular.stringMetrics(labelStr) * 9).advanceWidth;
      labelX = item.bubbles.first.x - exam.bubbleRadius - exam.labelGapPt! - labelWidth;
    } else {
      labelX = item.bubbles.first.x - kRowLabelWidth;
    }
    canvas.drawString(regular, 9, labelStr, labelX, flip(item.bubbles.first.y) - 3);
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

/// The Last Name / First Name column boxes in the ID table's name row —
/// top-left-origin points, same coordinate convention as bubble positions
/// and corner markers (see [_cornerMarkers]). [_paintSimpleHeader] and
/// [_paintNdmuHeader] draw these two columns' widths from here rather than
/// each hardcoding its own fractions, and [_emitTemplate] reads the same
/// values to record [OmrExamTemplate.lastNameFieldRect]/[firstNameFieldRect]
/// — one shared computation so the printed box and the crop rect a future
/// OCR step reads from a scan can never drift apart.
typedef _FieldBox = ({double x, double y, double width, double height});

({_FieldBox lastName, _FieldBox firstName, _FieldBox middleInitial}) _nameFieldBoxes(ExamLayout layout) {
  final exam = layout.exam;
  switch (exam.headerKind) {
    case HeaderKind.simple:
      // Last Name gets its own full-width row; First Name/MI share the row
      // below it (Exam Code/Batch/Date were removed entirely -- see
      // _paintSimpleHeader). MI only ever holds 1-2 letters, so it gets a
      // narrow slice of that second row; the rest goes to First Name.
      final lastY = exam.contentTop + kBrandRowHeight + kSubtitleRowHeight + kGapAfterSubtitle;
      final firstMiY = lastY + kTableHeight + kAtGapBetweenIdRows;
      final tableWidth = layout.contentWidth;
      final firstWidth = tableWidth * 0.85;
      final miWidth = tableWidth * 0.15;
      return (
        lastName: (x: exam.contentLeft, y: lastY, width: tableWidth, height: kTableHeight),
        firstName: (x: exam.contentLeft, y: firstMiY, width: firstWidth, height: kTableHeight),
        middleInitial: (x: exam.contentLeft + firstWidth, y: firstMiY, width: miWidth, height: kTableHeight),
      );
    case HeaderKind.ndmu:
      final compact = exam.compactNdmuHeader;
      final width = layout.contentWidth;
      final headerWidth = compact ? math.min(width, 620.0) : width;
      final letterheadHeight = compact ? kCompactLetterheadHeight : kLetterheadHeight;
      final idRowHeight = compact ? kCompactIdRowHeight : kIdRowHeight;
      final y = exam.contentTop + letterheadHeight + (compact ? kCompactGapAfterLetterhead : kGapAfterLetterhead);
      final lastWidth = headerWidth * 0.45;
      final firstWidth = headerWidth * 0.4;
      final miWidth = headerWidth * 0.15;
      return (
        lastName: (x: exam.contentLeft, y: y, width: lastWidth, height: idRowHeight),
        firstName: (x: exam.contentLeft + lastWidth, y: y, width: firstWidth, height: idRowHeight),
        middleInitial: (x: exam.contentLeft + lastWidth + firstWidth, y: y, width: miWidth, height: idRowHeight),
      );
  }
}

/// AT/PT's header — structurally the same two-row ID table (Last Name,
/// then First Name/MI below it) either way, but the brand block on
/// top is either GuideGrade's own generic wordmark (PT — only
/// structurally inspired by a third-party commercial test, so it keeps
/// GuideGrade's own branding rather than reproducing that test's name or
/// logo) or NDMU's real letterhead (AT — swapped in via
/// [ExamSpec.letterheadLines], reusing the field [_paintNdmuHeader]
/// already uses for the same purpose on QTM/TAT). Either way the brand
/// block consumes exactly [kBrandRowHeight] + [kSubtitleRowHeight] +
/// [kGapAfterSubtitle], so the ID table/title/grid below it never moves.
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
  if (exam.letterheadLines.isEmpty) {
    canvas.setColor(kRedOrange);
    canvas.drawString(bold, 20, 'Guide', kContentLeft, flip(y + 20));
    final guideWidth = (bold.stringMetrics('Guide') * 20).advanceWidth;
    canvas.setColor(kGreen);
    canvas.drawString(bold, 20, 'Grade', kContentLeft + guideWidth, flip(y + 20));
    y += kBrandRowHeight;

    canvas.setColor(kGray);
    canvas.drawString(regular, 10, 'Guidance and Testing Center', kContentLeft, flip(y + 10));
    y += kSubtitleRowHeight + kGapAfterSubtitle;
  } else {
    var ly = y + 10;
    for (var i = 0; i < exam.letterheadLines.length; i++) {
      final line = exam.letterheadLines[i];
      final size = i == 1 ? 11.0 : 8.0;
      final font = i == 1 ? bold : regular;
      final metrics = font.stringMetrics(line) * size;
      canvas.setColor(i == 1 ? kNavy : kGray);
      canvas.drawString(font, size, line, kContentLeft + (layout.contentWidth - metrics.advanceWidth) / 2, flip(ly));
      ly += size + 3;
    }
    y += kBrandRowHeight + kSubtitleRowHeight + kGapAfterSubtitle;
  }

  // Two boxed rows -- Last Name on its own full-width row, then First
  // Name/MI sharing the row below it (Exam Code/Batch/Date were removed
  // entirely). Each field is subdivided into individual per-letter boxes
  // (kAtLastNameBoxes etc). Widths come from _nameFieldBoxes (shared with
  // _emitTemplate's OCR crop rect) rather than being hardcoded here a
  // second time; the crop rect itself is untouched by the box subdivision
  // (still the field's full bounding box minus the caption strip — see
  // kNameCaptionHeight), since OCR reads the whole cropped word at once
  // regardless of the printed box lines.
  final tableWidth = layout.contentWidth;
  final nameBoxes = _nameFieldBoxes(layout);

  void drawBoxedRow(double rowY, List<(String, double, int)> columns) {
    canvas.setColor(kBlack);
    canvas.setLineWidth(1);
    canvas.drawRect(kContentLeft, flip(rowY + kTableHeight), tableWidth, kTableHeight);
    canvas.strokePath();
    var colX = kContentLeft;
    for (final (label, w, boxCount) in columns) {
      canvas.setLineWidth(1);
      canvas.drawLine(colX, flip(rowY), colX, flip(rowY + kTableHeight));
      canvas.strokePath();
      canvas.setColor(kGray);
      canvas.drawString(regular, 8, label, colX + 3, flip(rowY + 10));
      canvas.setColor(kBlack);
      canvas.setLineWidth(0.75);
      canvas.drawLine(colX, flip(rowY + kNameCaptionHeight), colX + w, flip(rowY + kNameCaptionHeight));
      canvas.strokePath();
      final boxWidth = w / boxCount;
      for (var i = 1; i < boxCount; i++) {
        final bx = colX + boxWidth * i;
        canvas.drawLine(bx, flip(rowY + kNameCaptionHeight), bx, flip(rowY + kTableHeight));
        canvas.strokePath();
      }
      colX += w;
    }
  }

  drawBoxedRow(y, [('Last Name', nameBoxes.lastName.width, kAtLastNameBoxes)]);
  y += kTableHeight + kAtGapBetweenIdRows;
  drawBoxedRow(y, [
    ('First Name', nameBoxes.firstName.width, kAtFirstNameBoxes),
    ('MI', nameBoxes.middleInitial.width, kAtMiBoxes),
  ]);
  y += kTableHeight + kGapAfterTable;

  // Title (+ page indicator for multi-page sections). Skipped here when
  // titleInRightMargin is set (AT) -- _paintAtRotatedTitle draws it instead,
  // rotated in the top-right margin strip. The space itself stays reserved
  // (y still advances) so nothing below moves.
  if (!exam.titleInRightMargin) {
    canvas.setColor(kNavy);
    final sectionSuffix = exam.suppressSectionInTitle ? '' : ' - ${page.section.name}';
    final title = page.pageCount > 1 ? '${exam.title}$sectionSuffix (Page ${page.pageNumber} of ${page.pageCount})' : '${exam.title}$sectionSuffix';
    canvas.drawString(bold, 13, title, kContentLeft, flip(y + 15));
  }
  // When titleInRightMargin leaves this row blank (AT), only a small gap
  // is kept here instead of the title's full row height -- the instruction
  // below sits right under the First Name/MI row instead of leaving
  // a tall blank gap where the title used to be. The header's total
  // reserved height (kSimpleHeaderHeight) is untouched either way, so the
  // grid's position doesn't move -- the freed space just becomes extra
  // blank margin above the grid instead.
  y += exam.titleInRightMargin ? kAtTitleMarginGap : kTitleRowHeight;

  // Unlike the title, the pencil instruction always stays in its normal
  // spot here (right below the First Name/MI row) even when
  // titleInRightMargin moves the title itself into the margin.
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
  final headerTop = kContentTop;
  var y = kContentTop;
  final width = layout.contentWidth;
  final compact = exam.compactNdmuHeader;
  // Compact mode (TAT's landscape page) never stretches the header box to
  // the full grid width -- the grid spans wide because it has 130 items'
  // worth of real content to fill that space with; the header's actual
  // content (a few short ID-field lines) doesn't, and stretching it out
  // just leaves those lines sitting in a lot of dead space instead of
  // reading as a compact, well-proportioned block the way AT/QTM's own
  // headers do (TAT only leaves a narrow strip free on the right for a
  // separate, compact scores panel -- see the scores block below).
  final headerWidth = compact ? math.min(width, 620.0) : width;

  final letterheadHeight = compact ? kCompactLetterheadHeight : kLetterheadHeight;
  final idRowHeight = compact ? kCompactIdRowHeight : kIdRowHeight;
  final dateScoresHeight = compact ? kCompactDateScoresHeight : kDateScoresHeight;
  final titleHeight = compact ? kCompactNdmuTitleHeight : kNdmuTitleHeight;

  // Letterhead box.
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(kContentLeft, flip(y + letterheadHeight), headerWidth, letterheadHeight);
  canvas.strokePath();
  var ly = y + (compact ? 11 : 13);
  for (var i = 0; i < exam.letterheadLines.length; i++) {
    final line = exam.letterheadLines[i];
    // the university name (line 2) stands out
    final size = compact ? (i == 1 ? 11.0 : 8.0) : (i == 1 ? 12.0 : 8.0);
    final font = i == 1 ? bold : regular;
    final metrics = font.stringMetrics(line) * size;
    final textX = kContentLeft + (headerWidth - metrics.advanceWidth) / 2;
    canvas.setColor(i == 1 ? kNavy : kGray);
    canvas.drawString(font, size, line, textX, flip(ly));
    ly += size + (compact ? 2 : 4);
  }
  y += letterheadHeight + (compact ? kCompactGapAfterLetterhead : kGapAfterLetterhead);

  // ID table: row 1 splits into Last Name / First Name / MI; rows 2-3 are
  // full-width (School Last Attended, Address of School Last Attended).
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  final idTableHeight = idRowHeight * kIdRowCount;
  canvas.drawRect(kContentLeft, flip(y + idTableHeight), headerWidth, idTableHeight);
  canvas.strokePath();
  for (var i = 1; i < kIdRowCount; i++) {
    final lineY = y + idRowHeight * i;
    canvas.drawLine(kContentLeft, flip(lineY), kContentLeft + headerWidth, flip(lineY));
    canvas.strokePath();
  }
  final labelOffset = compact ? 8.0 : 9.0;
  // Last Name/First Name widths come from _nameFieldBoxes (shared with
  // _emitTemplate's OCR crop rect) rather than being hardcoded here again.
  final nameBoxes = _nameFieldBoxes(layout);
  final nameCols = [
    ('Last Name', nameBoxes.lastName.width),
    ('First Name', nameBoxes.firstName.width),
    ('MI', nameBoxes.middleInitial.width),
  ];
  var colX = kContentLeft;
  for (final (label, w) in nameCols) {
    if (colX > kContentLeft) {
      canvas.drawLine(colX, flip(y), colX, flip(y + idRowHeight));
      canvas.strokePath();
    }
    canvas.setColor(kGray);
    canvas.drawString(regular, 8, label, colX + 3, flip(y + labelOffset));
    colX += w;
  }
  canvas.setColor(kGray);
  canvas.drawString(regular, 8, 'School Last Attended', kContentLeft + 3, flip(y + idRowHeight + labelOffset));
  canvas.drawString(regular, 8, 'Address of School Last Attended', kContentLeft + 3, flip(y + idRowHeight * 2 + labelOffset));
  if (compact) {
    // TAT-compact only: Date/Birth/Age fields fit in the School/Address
    // rows' own leftover width, positioned well clear of each row's own
    // label -- fieldStartX leaves a real writing zone (not just the label
    // itself) for the examinee to actually fill in the school name and
    // address in, not just enough room for the label text to not clip.
    const fieldStartXRel = 300.0;
    final fieldStartX = kContentLeft + fieldStartXRel;

    // Vertical border marking where the writing zone ends and the
    // Date/Birth/Age fields begin -- anchored to the same row boundaries
    // as the table's own horizontal lines so it reads as a real table
    // cell, not a line floating independently of the grid it's part of.
    canvas.setColor(kBlack);
    canvas.setLineWidth(1);
    canvas.drawLine(fieldStartX - 10, flip(y + idRowHeight), fieldStartX - 10, flip(y + idRowHeight * kIdRowCount));
    canvas.strokePath();

    const labelColW = 50.0, yearColW = 52.0, monthColW = 58.0, dayColW = 45.0;
    void drawDateFields(String label, double rowY) {
      canvas.setColor(kGray);
      var fx = fieldStartX;
      canvas.drawString(regular, 7, label, fx, flip(rowY));
      fx += labelColW;
      canvas.drawString(regular, 7, 'Year ___', fx, flip(rowY));
      fx += yearColW;
      canvas.drawString(regular, 7, 'Month ___', fx, flip(rowY));
      fx += monthColW;
      canvas.drawString(regular, 7, 'Day ___', fx, flip(rowY));
    }

    drawDateFields('Date Today:', y + idRowHeight + labelOffset);
    drawDateFields('Birth Date:', y + idRowHeight * 2 + labelOffset);
    canvas.drawString(
      regular,
      7,
      'Age: ___  Sex: M ( ) F ( )',
      fieldStartX + labelColW + yearColW + monthColW + dayColW + 12,
      flip(y + idRowHeight * 2 + labelOffset),
    );
  }
  y += idTableHeight;
  final idTableBottomY = y;
  y += compact ? kCompactGapAfterIdTable : kGapAfterIdTable;

  // TAT-compact only: a separate scores panel in the top-right, using the
  // width freed up by capping the letterhead/ID box (see headerWidth) --
  // spans the same vertical range as the letterhead+ID box to its left,
  // rather than being squeezed into the date/birth row's height like
  // QTM's does, since there's a full column of height available for it
  // here.
  if (compact && exam.code == 'TAT') {
    final scoresX = kContentLeft + headerWidth + 24;
    // A compact side panel, not a second wide block -- the letterhead/ID
    // box (headerWidth) is the one that stretches to use the width; this
    // is just Raw/Scaled numbers, capped modestly regardless of how much
    // width happens to be left over.
    final scoresWidth = math.min(math.max(width - headerWidth - 24, 0.0), 150.0);
    final scoresHeight = idTableBottomY - headerTop;
    canvas.setColor(kBlack);
    canvas.setLineWidth(1);
    canvas.drawRect(scoresX, flip(headerTop + scoresHeight), scoresWidth, scoresHeight);
    canvas.strokePath();
    const rows = ['Test I', 'Test II', 'Test III', 'Total'];
    final rowPitch = (scoresHeight - 14) / rows.length;
    canvas.drawString(bold, 7, 'Raw', scoresX + scoresWidth * 0.32, flip(headerTop + 10));
    canvas.drawString(bold, 7, 'Scaled', scoresX + scoresWidth * 0.68, flip(headerTop + 10));
    for (var i = 0; i < rows.length; i++) {
      final rowY = headerTop + 15 + i * rowPitch;
      canvas.setColor(kGray);
      canvas.drawString(regular, 7, rows[i], scoresX + 4, flip(rowY + rowPitch * 0.65));
      canvas.setLineWidth(0.75);
      canvas.drawRect(scoresX + scoresWidth * 0.22, flip(rowY + rowPitch * 0.88), scoresWidth * 0.22, rowPitch * 0.65);
      canvas.strokePath();
      canvas.drawRect(scoresX + scoresWidth * 0.6, flip(rowY + rowPitch * 0.88), scoresWidth * 0.22, rowPitch * 0.65);
      canvas.strokePath();
    }
  }

  // Date/Birth/Age/Sex block -- QTM-only: TAT-compact already drew these
  // fields inline in the ID table's School/Address rows above, positioned
  // with a real writing zone before them (see there), so there's nothing
  // left to draw in this row for TAT.
  final leftWidth = headerWidth * 0.55;
  final rightX = kContentLeft + leftWidth + 10;
  final rightWidth = headerWidth - leftWidth - 10;

  if (!compact) {
    canvas.setColor(kGray);
    canvas.drawString(regular, 7, 'Date Today:  Year _____  Month _____  Day _____', kContentLeft, flip(y + 10));
    canvas.drawString(regular, 7, 'Birth Date:  Year _____  Month _____  Day _____', kContentLeft, flip(y + 26));
    canvas.drawString(regular, 7, 'Age: _____   Sex:  M ( )   F ( )', kContentLeft, flip(y + 42));
  }

  canvas.setLineWidth(0.75);
  if (exam.code == 'TAT') {
    // Compact TAT already drew its scores panel above; nothing left to
    // draw here.
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
    canvas.drawRect(rightX, flip(y + dateScoresHeight), rightWidth * 0.42, 12);
    canvas.strokePath();
  }
  y += dateScoresHeight + (compact ? kCompactGapAfterDateScores : kGapAfterDateScores);

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
  if (compact) {
    // No second "ANSWER SHEET" line here -- TAT's title is already
    // unambiguous on its own (there's no other section name it could be
    // confused with), so that line was purely decorative weight the
    // compact header doesn't have room to spend.
    canvas.drawString(bold, 12, title1, kContentLeft, flip(y + 10));
  } else {
    canvas.drawString(bold, 12, title1, kContentLeft, flip(y + 13));
    canvas.drawString(bold, 9, title2Parts.join(' - ').toUpperCase(), kContentLeft, flip(y + 26));
  }
  y += titleHeight;

  canvas.setColor(kGray);
  canvas.drawString(regular, compact ? 6 : 7, 'Use a No. 2 pencil. Fill the circle completely.', kContentLeft, flip(y + (compact ? 7 : 9)));
}

/// AT's back-page "Score Record" — printed on the reverse of the bubble
/// sheet, filled in by hand by whoever grades it (raw scores, percentiles,
/// etc.), never scanned/decoded by the app itself (no corner markers, not
/// part of OmrExamTemplate/_emitTemplate at all).
///
/// AT is only ever *structurally* inspired by OLSAT-style score-record
/// forms — same functional layout (score-category boxes, a Total/Verbal/
/// Nonverbal results table, a Cluster Analysis table), using standard
/// psychometric terminology (Raw Score, Percentile Rank, Stanine — used
/// industry-wide, not any one publisher's IP) — but never that publisher's
/// name, logo, copyright notice, or their own proprietary named scores/
/// product codes. See tool/generate_sheets.dart's header-kind comment for
/// the same policy already applied to AT's front page.
void _paintAtScoreRecordPage(PdfGraphics canvas, ExamSpec exam, PdfFont regular, PdfFont bold) {
  double flip(double topLeftY) => exam.pageHeightPt - topLeftY;
  final contentWidth = exam.pageWidthPt - kContentLeft - exam.markerPad - exam.pageMargin;

  // No letterhead, no title -- just the tables, starting right at the top
  // of the page.
  var y = kContentTop;

  // ID table.
  const idRows = ['Date', 'Name', 'Examiner', 'School', 'Date of Birth', 'Gender', 'Grade', 'Age (years/months)'];
  const idRowHeight = 18.0;
  final idTableHeight = idRowHeight * idRows.length;
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(kContentLeft, flip(y + idTableHeight), contentWidth, idTableHeight);
  canvas.strokePath();
  for (var i = 1; i < idRows.length; i++) {
    final lineY = y + idRowHeight * i;
    canvas.drawLine(kContentLeft, flip(lineY), kContentLeft + contentWidth, flip(lineY));
    canvas.strokePath();
  }
  for (var i = 0; i < idRows.length; i++) {
    canvas.setColor(kGray);
    canvas.drawString(regular, 9, idRows[i], kContentLeft + 6, flip(y + idRowHeight * i + 12));
  }
  y += idTableHeight + 16;

  // Score-category boxes -- same bordered-table style as the Scores/
  // Cluster Analysis tables below (one label column, one score-entry
  // column), rather than individually-positioned floating boxes, so every
  // row's box lines up under the same left edge with no per-row math to
  // get wrong.
  const scoreBoxRows = ['Verbal Comprehension', 'Verbal Reasoning', 'Figural Reasoning', 'Quantitative Reasoning', 'Total'];
  const scoreBoxRowHeight = 20.0;
  const scoreBoxEntryWidth = 90.0;
  final scoreBoxLabelWidth = contentWidth - scoreBoxEntryWidth;
  final scoreBoxTableHeight = scoreBoxRowHeight * scoreBoxRows.length;
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(kContentLeft, flip(y + scoreBoxTableHeight), contentWidth, scoreBoxTableHeight);
  canvas.strokePath();
  for (var i = 1; i < scoreBoxRows.length; i++) {
    final lineY = y + scoreBoxRowHeight * i;
    canvas.drawLine(kContentLeft, flip(lineY), kContentLeft + contentWidth, flip(lineY));
    canvas.strokePath();
  }
  final scoreBoxEntryX = kContentLeft + scoreBoxLabelWidth;
  canvas.drawLine(scoreBoxEntryX, flip(y), scoreBoxEntryX, flip(y + scoreBoxTableHeight));
  canvas.strokePath();
  for (var i = 0; i < scoreBoxRows.length; i++) {
    final rowTop = y + scoreBoxRowHeight * i;
    final isTotal = scoreBoxRows[i] == 'Total';
    canvas.setColor(isTotal ? kNavy : kGray);
    canvas.drawString(isTotal ? bold : regular, 9, scoreBoxRows[i], kContentLeft + 6, flip(rowTop + 13));
  }
  y += scoreBoxTableHeight + 18;

  // Scores table: Total / Verbal / Nonverbal columns x Raw Score /
  // Percentile Rank / Stanine rows.
  canvas.setColor(kNavy);
  canvas.drawString(bold, 11, 'Scores', kContentLeft, flip(y + 11));
  y += 18;
  const scoreCols = ['', 'Total', 'Verbal', 'Nonverbal'];
  const scoreRows = ['Raw Score', 'Percentile Rank', 'Stanine'];
  const scoreLabelWidth = 120.0;
  final scoreColWidth = (contentWidth - scoreLabelWidth) / 3;
  const scoreRowHeight = 20.0;
  final scoreTableHeight = scoreRowHeight * (scoreRows.length + 1);
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(kContentLeft, flip(y + scoreTableHeight), contentWidth, scoreTableHeight);
  canvas.strokePath();
  for (var i = 1; i <= scoreRows.length; i++) {
    final lineY = y + scoreRowHeight * i;
    canvas.drawLine(kContentLeft, flip(lineY), kContentLeft + contentWidth, flip(lineY));
    canvas.strokePath();
  }
  for (var i = 1; i < scoreCols.length; i++) {
    final lineX = kContentLeft + scoreLabelWidth + scoreColWidth * (i - 1);
    canvas.drawLine(lineX, flip(y), lineX, flip(y + scoreTableHeight));
    canvas.strokePath();
  }
  canvas.setColor(kGray);
  for (var c = 1; c < scoreCols.length; c++) {
    final colX = kContentLeft + scoreLabelWidth + scoreColWidth * (c - 1);
    final metrics = bold.stringMetrics(scoreCols[c]) * 9;
    canvas.drawString(bold, 9, scoreCols[c], colX + (scoreColWidth - metrics.advanceWidth) / 2, flip(y + 13));
  }
  for (var r = 0; r < scoreRows.length; r++) {
    canvas.drawString(regular, 9, scoreRows[r], kContentLeft + 6, flip(y + scoreRowHeight * (r + 1) + 13));
  }
  y += scoreTableHeight + 6;
  canvas.setColor(kGray);
  canvas.drawString(regular, 7, 'Verbal = Verbal Comprehension + Verbal Reasoning', kContentLeft, flip(y + 8));
  canvas.drawString(regular, 7, 'Nonverbal = Figural Reasoning + Quantitative Reasoning', kContentLeft, flip(y + 18));
  y += 30;

  // Cluster Analysis table: Number Right / Below Average / Average / Above
  // Average columns x category rows (sub-categories indented).
  canvas.setColor(kNavy);
  canvas.drawString(bold, 11, 'Cluster Analysis', kContentLeft, flip(y + 11));
  y += 18;
  const clusterCols = ['', 'Number Right', 'Below Average', 'Average', 'Above Average'];
  const clusterRows = [
    ('Total', false),
    ('Verbal', false),
    ('Verbal Comprehension', true),
    ('Verbal Reasoning', true),
    ('Nonverbal', false),
    ('Figural Reasoning', true),
    ('Quantitative Reasoning', true),
  ];
  const clusterLabelWidth = 150.0;
  final clusterColWidth = (contentWidth - clusterLabelWidth) / 4;
  const clusterRowHeight = 18.0;
  final clusterTableHeight = clusterRowHeight * (clusterRows.length + 1);
  canvas.setColor(kBlack);
  canvas.setLineWidth(1);
  canvas.drawRect(kContentLeft, flip(y + clusterTableHeight), contentWidth, clusterTableHeight);
  canvas.strokePath();
  for (var i = 1; i <= clusterRows.length; i++) {
    final lineY = y + clusterRowHeight * i;
    canvas.drawLine(kContentLeft, flip(lineY), kContentLeft + contentWidth, flip(lineY));
    canvas.strokePath();
  }
  for (var i = 1; i < clusterCols.length; i++) {
    final lineX = kContentLeft + clusterLabelWidth + clusterColWidth * (i - 1);
    canvas.drawLine(lineX, flip(y), lineX, flip(y + clusterTableHeight));
    canvas.strokePath();
  }
  canvas.setColor(kGray);
  for (var c = 1; c < clusterCols.length; c++) {
    final colX = kContentLeft + clusterLabelWidth + clusterColWidth * (c - 1);
    final metrics = bold.stringMetrics(clusterCols[c]) * 8;
    canvas.drawString(bold, 8, clusterCols[c], colX + (clusterColWidth - metrics.advanceWidth) / 2, flip(y + 12));
  }
  for (var r = 0; r < clusterRows.length; r++) {
    final (label, indented) = clusterRows[r];
    canvas.drawString(regular, 9, label, kContentLeft + (indented ? 16 : 6), flip(y + clusterRowHeight * (r + 1) + 12));
  }
  y += clusterTableHeight + 20;

  // Footer -- GuideGrade/NDMU only, no publisher name or copyright notice.
  canvas.setColor(kGray);
  canvas.drawString(regular, 7, 'GuideGrade - Guidance Automated Test Diagnostic Checking', kContentLeft, flip(y));
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

/// One of the extra interior registration marks a redesigned sheet prints
/// beyond its 4 corner anchors — a left/right pair straddling the
/// horizontal divider between answer blocks, plus 3 smaller marks on the
/// page's vertical centerline (above the answers, at the divider, below
/// the answers). Unlike [OmrCorner] (always exactly 4, used to fit the
/// sheet's main perspective homography), a template may have zero of
/// these (legacy sheets, TAT) — see [OmrExamTemplate.interiorFiducials].
enum OmrFiducialRole {
  dividerLeft,
  dividerRight,
  centerAboveAnswers,
  centerAtDivider,
  centerBelowAnswers,
}

class OmrFiducial {
  final OmrFiducialRole role;
  final double xFrac;
  final double yFrac;
  /// Half the printed square's side length, in page points — its search
  /// window size differs from the 4 main corners' (see kAtCenterMarkerHalf
  /// vs kAtEdgeMarkerHalf), so the decoder needs it per-mark rather than
  /// assuming one fixed size for every fiducial on the page.
  final double halfSizePt;
  const OmrFiducial(this.role, this.xFrac, this.yFrac, this.halfSizePt);
}

/// A fractional bounding box (0.0-1.0 of the page, top-left origin — same
/// convention as [BubblePos]/[OmrCorner]). Used only to crop a printed
/// hand-written field (Last Name / First Name) out of a perspective-
/// corrected scan for on-device OCR; never used for bubble scoring.
class OmrFieldRect {
  final double xFrac;
  final double yFrac;
  final double widthFrac;
  final double heightFrac;
  const OmrFieldRect(this.xFrac, this.yFrac, this.widthFrac, this.heightFrac);
}

class OmrExamTemplate {
  final String examCode;
  /// Stable identifier for this exact printed geometry — bumped by hand in
  /// kExams whenever a sheet's fiducial/bubble/field layout changes (not
  /// on every regeneration run). Persisted onto each [LocalScan] at scan
  /// time so a later geometry change can never be silently applied when
  /// re-reading an older scan's overlay (see ScannedImageViewerScreen).
  final String templateVersion;
  final double pageWidthPt;
  final double pageHeightPt;
  /// Horizontal radius, in page points, of the printed bubbles — the
  /// decoder samples a region this size around each BubblePos, so it must
  /// match the actual printed geometry rather than being guessed
  /// independently.
  final double bubbleRadiusPt;
  /// Vertical radius — equal to [bubbleRadiusPt] for a true circle (AT/PT),
  /// smaller for QTM/TAT's flattened NDMU-style ovals. Sampling a region
  /// sized to [bubbleRadiusPt] in both directions on an oval bubble
  /// dilutes a genuinely filled bubble's measured fill with blank paper
  /// above/below the actual printed shape — significant enough on its own
  /// to make real marks misread as ambiguous.
  final double bubbleRadiusYPt;
  final List<OmrCorner> cornerMarkers;
  /// Extra interior registration marks beyond the 4 [cornerMarkers] — see
  /// [OmrFiducial]. Empty for a template with no such marks printed
  /// (legacy sheets, TAT): the decoder's local mesh-correction stage is
  /// skipped entirely for those, falling back to the single global
  /// homography exactly as before this field existed.
  final List<OmrFiducial> interiorFiducials;
  final List<OmrSection> sections;
  /// Where the printed, hand-written Last Name / First Name / MI boxes are
  /// on the sheet — see [OmrFieldRect].
  final OmrFieldRect lastNameFieldRect;
  final OmrFieldRect firstNameFieldRect;
  final OmrFieldRect middleInitialFieldRect;
  const OmrExamTemplate({
    required this.examCode,
    required this.templateVersion,
    required this.pageWidthPt,
    required this.pageHeightPt,
    required this.bubbleRadiusPt,
    required this.bubbleRadiusYPt,
    required this.cornerMarkers,
    this.interiorFiducials = const [],
    required this.sections,
    required this.lastNameFieldRect,
    required this.firstNameFieldRect,
    required this.middleInitialFieldRect,
  });
}
''';

String _formatFrac(double v) => v.toStringAsFixed(5);

String _emitTemplate(ExamLayout layout) {
  final exam = layout.exam;
  final varName = '_omr${exam.code}';
  final corners = _cornerMarkers(layout);
  final cornersDart = corners.map((c) => 'OmrCorner(${_formatFrac(c.$1 / exam.pageWidthPt)}, ${_formatFrac(c.$2 / exam.pageHeightPt)})').join(', ');
  final interiorFiducials = _interiorFiducialsFor(exam);
  final interiorFiducialsDart = interiorFiducials
      .map((f) =>
          'OmrFiducial(OmrFiducialRole.${f.$1}, ${_formatFrac(f.$2 / exam.pageWidthPt)}, ${_formatFrac(f.$3 / exam.pageHeightPt)}, ${f.$4})')
      .join(', ');
  // QTM's redesigned header uses its own two-row boxed layout (see
  // _qtmNameFieldBoxes), not the generic HeaderKind.ndmu geometry
  // _nameFieldBoxes assumes (which still describes TAT's single combined
  // row correctly).
  final nameBoxes = exam.code == 'QTM' ? _qtmNameFieldBoxes(layout) : _nameFieldBoxes(layout);
  String fieldRectDart(_FieldBox box) =>
      'OmrFieldRect(${_formatFrac(box.x / exam.pageWidthPt)}, ${_formatFrac(box.y / exam.pageHeightPt)}, '
      '${_formatFrac(box.width / exam.pageWidthPt)}, ${_formatFrac(box.height / exam.pageHeightPt)})';
  // Keep the full width: handwriting can start below the printed caption.
  // Captions are removed by name_ocr_cleanup.dart after recognition.
  //
  // AT/QTM are the exception: _paintSimpleHeader/_paintQtmHeader draw their
  // Last Name/First Name/MI captions on their own line at the TOP of the
  // box (baseline `y + 10`, 8pt Helvetica -- see the `drawString(regular,
  // 8, label, colX + 3, flip(y + 10))` calls), with the handwriting filling
  // the rest of the box beneath it, rather than continuing on the same line
  // right after the caption (that inline style is what TAT's
  // _paintNdmuHeader still draws, and cleanNameOcrText's post-recognition
  // stripping already handles fine -- confirmed on real AT scans that OCR
  // was instead recognizing the caption itself as part of the name). Clip
  // only the top kNameCaptionHeight off these three name fields -- covers
  // the 10pt baseline plus a small margin for descender/antialiasing,
  // deliberately not more, so a tall handwritten ascender starting right
  // under the caption doesn't get cut off by the crop itself. Left edge,
  // width, and bottom edge are untouched. Same constant the header painters
  // use to draw the caption/box-row divider, so the crop and the printed
  // divider line can never disagree.
  _FieldBox clipCaptionTop(_FieldBox box) => (exam.code != 'AT' && exam.code != 'QTM')
      ? box
      : (
          x: box.x,
          y: box.y + kNameCaptionHeight,
          width: box.width,
          height: box.height - kNameCaptionHeight,
        );

  // Merge all pages belonging to the same section back into one
  // OmrSection (its items map spans every page it was laid out across).
  final buffer = StringBuffer();
  buffer.writeln('final OmrExamTemplate $varName = OmrExamTemplate(');
  buffer.writeln('  examCode: "${exam.code}",');
  buffer.writeln('  templateVersion: "${exam.templateVersion}",');
  buffer.writeln('  pageWidthPt: ${exam.pageWidthPt},');
  buffer.writeln('  pageHeightPt: ${exam.pageHeightPt},');
  buffer.writeln('  bubbleRadiusPt: ${exam.bubbleRadius},');
  buffer.writeln('  bubbleRadiusYPt: ${bubbleRadiusYFor(exam)},');
  buffer.writeln('  cornerMarkers: const [$cornersDart],');
  buffer.writeln('  interiorFiducials: const [$interiorFiducialsDart],');
  buffer.writeln('  lastNameFieldRect: const ${fieldRectDart(clipCaptionTop(nameBoxes.lastName))},');
  buffer.writeln('  firstNameFieldRect: const ${fieldRectDart(clipCaptionTop(nameBoxes.firstName))},');
  buffer.writeln('  middleInitialFieldRect: const ${fieldRectDart(clipCaptionTop(nameBoxes.middleInitial))},');
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
    // TAT: all 3 sections share one physical landscape page instead of
    // each getting its own — see _layoutTatLandscape's comment. AT/QTM:
    // all 6 sections share one physical page in a 3x2 grid — see
    // _layoutAtGrid's/_layoutQtmGrid's comments.
    final isTatLandscape = exam.code == 'TAT';
    final isAtGrid = exam.code == 'AT';
    final isQtmGrid = exam.code == 'QTM';
    final layout = isTatLandscape
        ? _layoutTatLandscape(exam)
        : isAtGrid
            ? _layoutAtGrid(exam)
            : isQtmGrid
                ? _layoutQtmGrid(exam)
                : _layoutExam(exam);

    final pdf = pw.Document();
    final regular = PdfFont.helvetica(pdf.document);
    final bold = PdfFont.helveticaBold(pdf.document);

    if (isTatLandscape) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(exam.pageWidthPt, exam.pageHeightPt),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.CustomPaint(
            size: PdfPoint(exam.pageWidthPt, exam.pageHeightPt),
            painter: (canvas, size) => _paintTatLandscapePage(canvas, exam, layout, regular, bold),
          ),
        ),
      );
    } else if (isAtGrid) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(exam.pageWidthPt, exam.pageHeightPt),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.CustomPaint(
            size: PdfPoint(exam.pageWidthPt, exam.pageHeightPt),
            painter: (canvas, size) => _paintAtGridPage(canvas, exam, layout, regular, bold),
          ),
        ),
      );
    } else if (isQtmGrid) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(exam.pageWidthPt, exam.pageHeightPt),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.CustomPaint(
            size: PdfPoint(exam.pageWidthPt, exam.pageHeightPt),
            painter: (canvas, size) => _paintQtmGridPage(canvas, exam, layout, regular, bold),
          ),
        ),
      );
    } else {
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
    }

    // AT only: a back-page Score Record, printed on the reverse of the
    // bubble sheet -- purely informational (filled in by hand after
    // grading), never scanned, so it's added straight to the PDF here with
    // no corner markers and no bearing on layout/_emitTemplate at all.
    if (exam.code == 'AT') {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(exam.pageWidthPt, exam.pageHeightPt),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.CustomPaint(
            size: PdfPoint(exam.pageWidthPt, exam.pageHeightPt),
            painter: (canvas, size) => _paintAtScoreRecordPage(canvas, exam, regular, bold),
          ),
        ),
      );
    }

    // QTM only: a back page for the fields the redesigned front page no
    // longer has room for (School Last Attended, Date/Birth/Age/Sex,
    // Scores) -- same reasoning as AT's Score Record above.
    if (exam.code == 'QTM') {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat(exam.pageWidthPt, exam.pageHeightPt),
          margin: pw.EdgeInsets.zero,
          build: (context) => pw.CustomPaint(
            size: PdfPoint(exam.pageWidthPt, exam.pageHeightPt),
            painter: (canvas, size) => _paintQtmBackPage(canvas, exam, regular, bold),
          ),
        ),
      );
    }

    final bytes = await pdf.save();
    File('${answerSheetsDir.path}/${exam.code}.pdf').writeAsBytesSync(bytes);
    final physicalPageCount = isTatLandscape || isAtGrid || isQtmGrid ? 1 : layout.pages.length;
    stdout.writeln('Wrote answer_sheets/${exam.code}.pdf ($physicalPageCount page(s), content width ${layout.contentWidth.toStringAsFixed(1)}pt)');

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
