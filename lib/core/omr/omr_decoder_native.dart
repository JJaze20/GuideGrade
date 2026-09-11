import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/omr_scan_result.dart';
import 'omr_alignment_check.dart';
import 'omr_templates.dart';

/// One search region for a single corner: a tight [stage1] box around the
/// template-expected marker position, the full photo-[quadrant] as the
/// fallback, and the point candidate distance is scored against.
typedef _QuadrantSearch = ({
  cv.Rect stage1,
  cv.Rect quadrant,
  double anchorX,
  double anchorY,
});

/// A candidate blob considered for a corner but not chosen — kept for the
/// debug overlay so a bad pick (or a near-miss) can be understood.
class _RejectedCandidate {
  /// Bounding box in full-image coordinates.
  final cv.Rect bboxGlobal;
  final double squareness;
  final double score;

  /// `area` | `aspect` | `fill_ratio` | `contrast` | `low_squareness` |
  /// `inside_grid` | `geom_inconsistent` | `outscored`.
  final String reason;

  const _RejectedCandidate(
    this.bboxGlobal,
    this.squareness,
    this.score,
    this.reason,
  );
}

/// Outcome of searching one quadrant for its corner square.
class _MarkerSearchResult {
  /// Moment-centroid of the winning square in full-image coordinates, or
  /// null when nothing cleared the [CornerConfidence.low] bar.
  final cv.Point2f? centroid;

  /// Winning blob's bounding box in full-image coordinates.
  final cv.Rect? bboxGlobal;
  final CornerConfidence confidence;
  final double squareness;
  final double contrast;
  final double anchorDistance;
  final List<_RejectedCandidate> rejected;

  const _MarkerSearchResult({
    required this.centroid,
    required this.bboxGlobal,
    required this.confidence,
    required this.squareness,
    required this.contrast,
    required this.anchorDistance,
    required this.rejected,
  });

}

/// Result of [OmrDecoder]'s `_refineCorners` — the four fiducial centroids
/// plus everything the callers / debug viz need about how sure it is.
class _RefineResult {
  /// TL, TR, BL, BR — CV centroids of the real printed squares (a rescued
  /// corner is still a detected blob, just lower confidence).
  final List<cv.Point2f> corners;
  final List<CornerConfidence> confidence;
  final AlignmentVerdict verdict;

  /// TL, TR, BL, BR — the Stage-1 search boxes, for the debug overlay.
  final List<cv.Rect> stage1Regions;

  /// TL, TR, BL, BR — rejected candidates per corner, for the debug overlay.
  final List<List<_RejectedCandidate>> rejectedPerCorner;

  /// A one-line "corner X recovered from geometry" note, or null.
  final String? note;

  const _RefineResult({
    required this.corners,
    required this.confidence,
    required this.verdict,
    required this.stage1Regions,
    required this.rejectedPerCorner,
    required this.note,
  });
}

/// Decodes a photographed answer sheet into marked choices, using the
/// fiducial corner markers in [OmrExamTemplate.cornerMarkers] to correct for
/// skew/perspective before sampling each [BubblePos].
///
/// Native (Android/iOS/desktop) implementation — backed by opencv_dart,
/// which requires dart:ffi and a compiled native OpenCV library, neither of
/// which exist on Web. This file is only ever selected for compilation on
/// platforms where dart:io is available (see omr_decoder.dart's conditional
/// export); Web gets omr_decoder_web.dart instead.
class OmrDecoder {
  const OmrDecoder();

  /// How far each corner's search region extends past the photo's exact
  /// midpoint into the opposite half, as a fraction of that dimension —
  /// gives a corner mark sitting close to the frame's center (a small or
  /// off-center sheet) room to still fall inside its own quadrant, without
  /// searching so much of the photo that unrelated marks or clutter
  /// routinely cross into the wrong quadrant. See [_quadrantsFor].
  static const double _quadrantOverlapFrac = 0.12;

  /// Canonical pixels per PDF point when warping the sheet flat. Bubble
  /// sampling geometry below is tuned against this scale.
  static const double _canonicalPxPerPt = 2.0;

  /// Canonical pixels per PDF point used only for [cropNameFields] — much
  /// higher than [_canonicalPxPerPt]. Confirmed on a real device scan that
  /// cropping straight from a [_canonicalPxPerPt]-scale rectified image
  /// gave name-field crops as small as ~200x68px: fine for OCR-ing the
  /// crisp printed field label, but too low-resolution for the actual
  /// handwritten answer to be recognized at all. [_canonicalPxPerPt] itself
  /// is tuned for bubble sampling and shared by scoring — bumped up here
  /// only, in a warp this method runs independently (see its doc comment),
  /// rather than raising the shared constant and risking a scoring
  /// regression for a display-only OCR suggestion.
  static const double _ocrCanonicalPxPerPt = 6.0;

  /// CLAHE clip limit, per exam code — how aggressively contrast gets
  /// re-normalized before thresholding (see the CLAHE comment in
  /// [decode]). Not a single global value: confirmed against real scans
  /// that different exams' real captures needed different amounts of
  /// correction. QTM's scan was evenly lit, so a low clip limit (1.2) was
  /// enough and kept ordinary sensor/JPEG noise in blank paper from being
  /// amplified into a speckled ink map. AT's scan had a genuine page-wide
  /// lighting gradient (visibly darker on one side in the raw photo), and
  /// that same low clip limit left it uncorrected — the flagged items
  /// tracked the gradient almost exactly (42% flagged in the darkest
  /// column vs 21% in the brightest). AT needs the stronger correction the
  /// original clipLimit 2 provided; defaulting everything else to that
  /// same 2 until each is individually confirmed against a real scan,
  /// rather than assuming QTM's tuning generalizes.
  static double _claheClipLimitFor(String examCode) => switch (examCode) {
    'QTM' => 1.2,
    _ => 2.0,
  };

  /// Block size (must be odd) for the adaptive threshold that binarizes the
  /// warped sheet before bubble sampling. Large enough to span several
  /// bubbles so it tracks slow lighting gradients across the page rather
  /// than reacting to a single bubble, small enough to still adapt to
  /// vignetting/uneven light within the sheet.
  static const int _adaptiveThresholdBlockSize = 45;

  /// Constant subtracted from the local adaptive-threshold mean; higher
  /// values require darker pixels to count as "ink".
  static const double _adaptiveThresholdC = 12;

  /// Low-light adaptive tuning: "normal" mean brightness (0-255) a well-lit
  /// captured sheet reads at, measured on the same grayscale Mat CLAHE is
  /// about to run on (or, for [_findMarkerInRegion], on that corner's own
  /// local search ROI — its own light can differ from the rest of the page,
  /// e.g. a shadow or silhouette over just one corner). At or above this,
  /// [_darknessFactor] is 0 and every adaptive helper below returns its
  /// input unchanged — the existing per-exam-tuned CLAHE/threshold values
  /// this project's daylight accuracy (AT ~94%, QTM ~95%) was measured
  /// against are a mathematical no-op case of this, not a separate path.
  /// Below it, correction scales in proportionally. Not yet calibrated
  /// against a real low-light scan — a reasonable starting point pending
  /// the on-device validation in the low-light accuracy plan's Phase 3, not
  /// a final tuned value the way the per-exam constants above are.
  static const double _referenceBrightness = 170.0;

  /// How far below [_referenceBrightness] the adaptive scaling below
  /// saturates at its maximum adjustment. Also pending real-scan
  /// calibration.
  static const double _maxDarknessRange = 100.0;

  /// 0 at/above [_referenceBrightness], ramping linearly to 1 at
  /// [_referenceBrightness] - [_maxDarknessRange] and clamped there for
  /// anything darker still — how far into "dark" territory a measured mean
  /// brightness reads, for scaling CLAHE/threshold parameters
  /// proportionally to how dark the actual photo is rather than as a hard
  /// on/off switch at some arbitrary cutoff.
  static double _darknessFactor(double meanBrightness) =>
      ((_referenceBrightness - meanBrightness) / _maxDarknessRange).clamp(0.0, 1.0);

  /// Scales a CLAHE clip limit up to double at maximum measured darkness,
  /// unchanged at/above [_referenceBrightness] — stronger local-contrast
  /// stretching for a genuinely dim or shadowed photo, where the existing
  /// fixed per-exam clip limits (tuned against normally-lit scans) don't
  /// pull the paper-vs-ink gap open far enough on their own.
  static double _adaptiveClipLimit(double base, double meanBrightness) =>
      base * (1 + _darknessFactor(meanBrightness));

  /// Scales the adaptive-threshold C constant down to half at maximum
  /// measured darkness, unchanged at/above [_referenceBrightness] — a more
  /// permissive "is this ink" decision for when CLAHE alone hasn't fully
  /// closed a dim photo's paper-vs-ink gap back to a normally-lit one's.
  static double _adaptiveThresholdCFor(double base, double meanBrightness) =>
      base * (1 - _darknessFactor(meanBrightness) * 0.5);

  /// How much the perspective-corrected grayscale is downscaled before its
  /// background-illumination field is estimated (see [_normalizeIllumination]).
  /// A modest blur on an image this much smaller is a very large-radius blur
  /// at full resolution — the whole point — at a fraction of the cost, which
  /// matters when this runs on every scanned page on a phone.
  static const int _illumDownscaleDiv = 8;

  /// The brightness blank paper is rescaled back toward after the background
  /// division in [_normalizeIllumination], clamped to this band. Too high and
  /// a region slightly below its local background clips to pure white (a
  /// faint mark lost); too low and the whole page drifts toward the
  /// threshold. The window sits a little under mid-8-bit so there is headroom
  /// above blank paper for the division to land in.
  static const double _illumTargetLevelMin = 170;
  static const double _illumTargetLevelMax = 230;

  /// Large-scale illumination normalization, applied to the perspective-
  /// corrected grayscale image *after* the warp and *before* CLAHE /
  /// adaptive thresholding.
  ///
  /// A cast shadow, a silhouette, or an uneven LED wash is a
  /// low-spatial-frequency, roughly multiplicative change: it scales the
  /// light coming off a broad area of the page, with the fine detail that
  /// actually matters (printed text, fiducial marks, a shaded bubble)
  /// riding on top of it. Dividing the image by a heavily-smoothed estimate
  /// of that background cancels the broad term while leaving the fine
  /// detail, because a large-radius blur cannot be pulled down much by
  /// features that are tiny next to its kernel — so after this, a big
  /// shadow reads mostly as "same paper, same brightness" while text and
  /// marks stay dark.
  ///
  /// The background is estimated cheaply: downscale ~[_illumDownscaleDiv]x,
  /// Gaussian-blur at that reduced scale, upscale back.
  ///
  /// Best-effort and strictly non-destructive. On an empty or non-8-bit
  /// input, a degenerate background estimate, an implausible result, or any
  /// OpenCV error it returns [gray] *itself* — so `identical(result, gray)`
  /// is true, the caller does not double-free, and the pipeline downstream
  /// is byte-for-byte what it was before whenever normalization could not
  /// help. Every intermediate Mat allocated here is disposed here; only a
  /// newly-created return value becomes the caller's to dispose.
  static cv.Mat _normalizeIllumination(cv.Mat gray) {
    if (gray.isEmpty || gray.channels != 1) return gray;

    cv.Mat? small;
    cv.Mat? smallBlurred;
    cv.Mat? background;
    cv.Mat? result;
    var keepResult = false;
    try {
      final w = gray.width;
      final h = gray.height;

      // Never shrink below a floor, or the blur below has no room to erase
      // page content and the upscale just reproduces the input.
      final downW = math.max(64, w ~/ _illumDownscaleDiv);
      final downH = math.max(64, h ~/ _illumDownscaleDiv);
      small = cv.resize(gray, (downW, downH), interpolation: cv.INTER_AREA);

      // Odd kernel ~1/3 of the downscaled short side: strong enough at this
      // scale to erase text and whole clusters of bubbles, so only the
      // lighting field survives into the estimate. Capped so an unusually
      // large page can't make this needlessly slow.
      final k = ((math.min(downW, downH) ~/ 3) | 1).clamp(11, 151);
      smallBlurred = cv.gaussianBlur(small, (k, k), 0);

      background =
          cv.resize(smallBlurred, (w, h), interpolation: cv.INTER_LINEAR);

      final bgMeanScalar = background.mean();
      final double bgMean;
      try {
        bgMean = bgMeanScalar.val1;
      } finally {
        bgMeanScalar.dispose();
      }
      // A near-black background estimate would make the division meaningless
      // (OpenCV maps divide-by-~0 to 0 anyway) — nothing useful to do.
      if (bgMean < 1.0) return gray;

      final target =
          bgMean.clamp(_illumTargetLevelMin, _illumTargetLevelMax);

      // Per pixel: saturate_cast<uchar>(target * gray / background). Output
      // type defaults to the 8-bit input type.
      result = cv.divide(gray, background, scale: target);

      final (rMeanScalar, rStdScalar) = cv.meanStdDev(result);
      final double rMean;
      final double rStd;
      try {
        rMean = rMeanScalar.val1;
        rStd = rStdScalar.val1;
      } finally {
        rMeanScalar.dispose();
        rStdScalar.dispose();
      }
      // A good result keeps a mostly-white sheet bright with real spread
      // (paper vs. ink). If it came out far too dark or bright, or collapsed
      // toward a single shade, discard it rather than hand the rest of the
      // pipeline something worse than the raw warp.
      if (rMean < 30 || rMean > 250 || rStd < 3) {
        return gray;
      }

      keepResult = true;
      return result;
    } catch (_) {
      return gray;
    } finally {
      small?.dispose();
      smallBlurred?.dispose();
      background?.dispose();
      if (!keepResult) result?.dispose();
    }
  }

  /// Absolute floor an item's best-filled bubble must clear before it's
  /// even considered for marking, used only as a last-resort sanity check
  /// (see [_readBubbles]) — everything with 3+ choices decides "is
  /// anything marked here" by comparing the best bubble against the
  /// *other bubbles in that same item*, not this constant. That change
  /// (see [_readBubbles]'s doc comment) is what replaced this floor as the
  /// primary decision after real scans confirmed it: with a single global
  /// constant, a photo with any whole-sheet contrast compression (uneven
  /// or dim lighting — confirmed against real photos, not assumed) pushed
  /// every bubble's fill up together, so blank items crossed this floor
  /// and genuinely marked items failed to clear it by enough over their
  /// row-mates. A same-row, same-lighting comparison isn't affected by
  /// that whole-photo shift at all. Kept low (below the old 0.28) since it
  /// only needs to catch "no real ink signal anywhere," not do the actual
  /// discrimination.
  static const double _blankFillFloor = 0.15;

  /// The gap an item's best bubble must open over the single runner-up to
  /// be trusted as "only one choice looks marked" rather than ambiguous —
  /// checked for every item regardless of choice count, after
  /// [_markPresenceGap] has already decided something is there at all.
  ///
  /// Per exam code rather than one fixed value, same reasoning as
  /// [_claheClipLimitFor]: confirmed against a real AT scan that even its
  /// correctly-read items typically show as a moderately-shaded ring
  /// rather than a solid filled disc (a real difference in how that sheet
  /// gets marked, not a decoder issue — see the CLAHE/inkmap comparison
  /// this was diagnosed from). AT also compares 5 choices per item
  /// (QTM/TAT compare 2-4), so its runner-up is drawn from a bigger pool
  /// and has more chances to land close to the real mark by chance alone.
  /// Both push a fixed 0.15 margin into flagging genuine single marks on
  /// AT more often than it should.
  ///
  /// QTM confirmed against a real scan to need the same kind of loosening,
  /// just less of it: a real sheet showed roughly a fifth to a third of
  /// its items marked as a thin, hollow-centered ring rather than a solid
  /// disc (compared directly against clearly-solid marks elsewhere on the
  /// same sheet, at the same ink density) — a consistent feature of how
  /// that exam-taker marks, not isolated light spots.
  ///
  /// Pushed further to match AT's 0.10 exactly after 0.12 still left a
  /// consistent handful flagged (items 6/7/9/22/53/56 on every one of 4
  /// re-scans) — checked those against clearly-unflagged items on the same
  /// sheet at this point and the difference isn't an obvious light-vs-
  /// solid split any more, just a small margin either side of whatever
  /// threshold is set. That's a sign real gains here are running out —
  /// if 0.10 doesn't clear these either, that's evidence they're
  /// genuinely marginal rather than a fixable tuning gap, not a reason to
  /// keep lowering further.
  static double _ambiguousMarginFor(String examCode) => switch (examCode) {
    'AT' => 0.10,
    'QTM' => 0.10,
    _ => 0.15,
  };

  /// The gap an item's best bubble must open over the lowest of its own
  /// row's *other* bubbles ([_readBubbles]'s 3+-choice path) to count as
  /// "something is marked here at all" — deliberately smaller than
  /// [_ambiguousMargin]. A real scan showed why the two needs are
  /// different: one genuinely shaded bubble read as a solid, dense mark in
  /// the ink map (comfortably clearing 0.15), while a second, equally real
  /// but more lightly shaded bubble on the same sheet produced visibly
  /// less ink density in the same ink map — real, not noise, just fainter
  /// pencil pressure — and fell just short of that same 0.15 gap, so it
  /// read as confidently blank instead of even being flagged. Detecting
  /// "is anything here" should be more sensitive than deciding "is it
  /// unambiguous" — a light-but-real mark should fall through to the
  /// ambiguous check below (get flagged for review) rather than being
  /// missed outright, which [_ambiguousMargin] alone couldn't do since it
  /// was being asked to do both jobs at once.
  static const double _markPresenceGap = 0.08;

  /// A fiducial blob must be at least this many gray levels darker than the
  /// local background to count as a real mark (not a shadow edge). Still a
  /// hard gate; also feeds `contrastScore` in the combined candidate score.
  static const double _markerMinContrast = 20;

  /// Cheap early reject: a candidate whose contour area fills less than this
  /// fraction of its axis-aligned bounding box is background texture, not a
  /// mark. Deliberately loose — a genuinely rotated square fills its
  /// *axis-aligned* box only ~0.5 — so real discrimination is the
  /// rotation-invariant `rectangularity` (contour area / min-area-rect
  /// area) inside the squareness score, not this.
  static const double _markerMinFillRatio = 0.35;

  /// Cheap early reject: a candidate more elongated than this (longer side /
  /// shorter side) is a table line or a run of header text, not a square.
  static const double _markerMaxAspect = 8.0;

  // Circularity (4*pi*area/perimeter^2) is no longer a hard ceiling — at
  // print pixel scale, corner-rounding from blur+dilate pushed the *real*
  // square (ideal ~0.785) over any single ceiling while ragged bubbles
  // slipped under it. `_squarenessOf` scores it as a band instead: a
  // blurred, dilated small printed square measures ~0.68-0.93 (full
  // score), a filled pencil disc ~0.95-1.0 (scored down), a ragged/merged
  // blob well below 0.68 (scored down).

  /// Minimum squareness score for a candidate to be accepted as a
  /// [CornerConfidence.confident] fiducial, and (lower bar) as
  /// [CornerConfidence.low] / rescue-eligible. See `_squarenessOf`.
  static const double _markerMinSquarenessConfident = 0.62;
  static const double _markerMinSquarenessLow = 0.42;

  /// Stage-1 search box half-extent, as a fraction of the shorter image
  /// dimension, centered on the template-expected corner (see
  /// [_quadrantsFor]). A miss here just falls through to the full-quadrant
  /// Stage-2 search — this is a prior, never a boundary.
  static const double _stage1HalfExtentFrac = 0.12;

  /// Padding added around the answer-grid bounding box (fraction of page)
  /// when testing whether a candidate maps *inside* the grid — a strong
  /// signal it's a shaded bubble, not a corner square. Capped low: PT
  /// prints its bottom markers only ~0.04 page-height below the grid, so a
  /// larger pad would swallow them.
  static const double _gridBboxPadFrac = 0.02;

  /// How far (fraction of page) a candidate may sit from where the affine
  /// transform through the other three confident corners predicts, before
  /// it's rejected as geometrically inconsistent with a real fiducial.
  static const double _affineToleranceFrac = 0.06;

  /// TEMPORARY diagnostic switch for fiducial-marker selection. When true,
  /// [_refineCorners] and [_findMarkerInRegion] print `[OMR FIDUCIAL DEBUG]`
  /// lines describing every candidate blob, the anchors, and the winners.
  /// Purely observational — no threshold, filter, or selection decision
  /// reads this or the extra metrics it logs. Remove once fiducial
  /// classification is retuned.
  static const bool _kFiducialDebug = true;

  /// TEMPORARY. Synchronous stdout (not debugPrint, whose throttle can drop
  /// the tail when the decode isolate tears down) — every line reaches
  /// logcat as `I/flutter`.
  // ignore: avoid_print
  static void _fidLog(String line) => print('[OMR FIDUCIAL DEBUG] $line');

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  /// Applies a 2x3 affine matrix (as returned by `cv.getAffineTransform2f`)
  /// to one point — a plain Dart multiply, no Mat allocation.
  static (double, double) _applyAffine(cv.Mat affine, double x, double y) {
    final a00 = affine.atNum(0, 0).toDouble();
    final a01 = affine.atNum(0, 1).toDouble();
    final a02 = affine.atNum(0, 2).toDouble();
    final a10 = affine.atNum(1, 0).toDouble();
    final a11 = affine.atNum(1, 1).toDouble();
    final a12 = affine.atNum(1, 2).toDouble();
    return (a00 * x + a01 * y + a02, a10 * x + a11 * y + a12);
  }

  /// True when 3 points are close enough to collinear that fitting an
  /// affine through them would be numerically unstable — the triangle
  /// they form has a tiny area relative to the span between them.
  static bool _nearCollinear(List<cv.Point2f> pts) {
    final (x0, y0) = (pts[0].x, pts[0].y);
    final (x1, y1) = (pts[1].x, pts[1].y);
    final (x2, y2) = (pts[2].x, pts[2].y);
    final cross = (x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0);
    final span = math.max(
      1.0,
      math.max((x1 - x0).abs() + (y1 - y0).abs(),
          (x2 - x0).abs() + (y2 - y0).abs()),
    );
    return cross.abs() / span < 4.0;
  }

  /// Hermite ramp: 0 at/below [a], 1 at/above [b], smooth in between.
  static double _smoothstep(double a, double b, double x) {
    if (b <= a) return x >= b ? 1 : 0;
    final t = _clamp01((x - a) / (b - a));
    return t * t * (3 - 2 * t);
  }

  /// Squareness ∈ [0,1] for one candidate blob — how much it looks like the
  /// printed solid black corner square rather than a shaded/hollow answer
  /// bubble, a letter-filled ring, a bubble merged with a row label, text,
  /// or a shadow edge.
  ///
  /// A blurred, dilated ~15-20 px printed square scores ~0.9: it stays a
  /// solid convex filled rotated-rect (`rectangularity` ~0.9+, `inkDensity`
  /// ~1, `solidity` ~0.95), and its `circularity` lands ~0.78-0.93 — inside
  /// the band, exactly the range a lone ceiling wrongly rejected. A filled
  /// pencil disc scores ~0.2 (circularity ~0.97+, rectangularity ~pi/4). A
  /// hollow / lightly-shaded ring scores ~0.15 (low `inkDensity`). A bubble
  /// fused with its row-number label scores ~0.2 (low `solidity`, high
  /// vertex count, often aspect > 1.6).
  static double _squarenessOf({
    required double rectangularity, // contourArea / minAreaRect area
    required int approxVerts, // approxPolyDP vertex count (<=0 = unknown)
    required double inkDensity, // dark px inside the contour / contour area
    required double solidity, // contourArea / convexHull area
    required double circularity, // 4*pi*area/perimeter^2
    required double aspect, // longSide / shortSide of the bbox
    required double extent, // contourArea / bbox area
  }) {
    final sqrRect = _clamp01((rectangularity - 0.60) / 0.35);
    final sqrInk = _smoothstep(0.55, 0.80, inkDensity);
    final sqrSolid = _clamp01((solidity - 0.80) / 0.15);
    final double sqrCirc;
    if (circularity >= 0.68 && circularity <= 0.93) {
      sqrCirc = 1.0;
    } else if (circularity < 0.68) {
      sqrCirc = _clamp01((circularity - 0.45) / 0.23);
    } else {
      sqrCirc = _clamp01((1.02 - circularity) / 0.09);
    }
    final double sqrVerts;
    if (approxVerts <= 0) {
      sqrVerts = 0.5;
    } else if (approxVerts <= 4) {
      sqrVerts = 1.0 - (4 - approxVerts) * 0.25;
    } else if (approxVerts <= 6) {
      sqrVerts = 1.0 - (approxVerts - 4) * 0.25;
    } else {
      sqrVerts = _clamp01(1.0 - (approxVerts - 6) * 0.15);
    }
    final sqrAspect = _clamp01((1.60 - aspect) / 0.60);
    final sqrExtent = _smoothstep(0.35, 0.75, extent);

    return _clamp01(
      0.24 * sqrRect +
          0.22 * sqrInk +
          0.16 * sqrSolid +
          0.16 * sqrCirc +
          0.12 * sqrVerts +
          0.06 * sqrAspect +
          0.04 * sqrExtent,
    );
  }

  /// The answer grid's bounding box in page fractions (min/max of every
  /// [BubblePos], expanded by the bubble radius and a small pad). Every
  /// exam's four corner markers sit strictly outside this by construction
  /// (see tool/generate_sheets.dart) — so a candidate that maps inside it
  /// is a shaded bubble, not a corner. Memoized per exam code.
  static final Map<String, ({double x0, double y0, double x1, double y1})>
      _gridBboxCache = {};

  static ({double x0, double y0, double x1, double y1}) _answerGridBboxFrac(
    OmrExamTemplate t,
  ) {
    return _gridBboxCache.putIfAbsent(t.examCode, () {
      var x0 = 1.0, y0 = 1.0, x1 = 0.0, y1 = 0.0;
      for (final section in t.sections) {
        for (final item in section.items.values) {
          for (final b in item) {
            if (b.xFrac < x0) x0 = b.xFrac;
            if (b.xFrac > x1) x1 = b.xFrac;
            if (b.yFrac < y0) y0 = b.yFrac;
            if (b.yFrac > y1) y1 = b.yFrac;
          }
        }
      }
      final rx = t.bubbleRadiusPt / t.pageWidthPt + _gridBboxPadFrac;
      final ry = t.bubbleRadiusYPt / t.pageHeightPt + _gridBboxPadFrac;
      return (x0: x0 - rx, y0: y0 - ry, x1: x1 + rx, y1: y1 + ry);
    });
  }

  /// Inner sample radius as a fraction of the outer bubble sample radius.
  /// The printed choice letter sits in this center zone; subtracting its
  /// ink contribution from the outer reading isolates pencil marks in the
  /// bubble ring. Sized against the sheet generator's current geometry
  /// (`kBubbleRadius: 6, kLetterFontSize: 6` in tool/generate_sheets.dart,
  /// bold): a wide glyph like "W" or "M" has an advance width close to
  /// 0.85x its font size, so half-width ≈ 0.42x the bubble radius — 0.4
  /// left letters like that poking just outside the exclusion zone,
  /// reading as ink on an otherwise-blank bubble. 0.6 covers every glyph
  /// with margin while still leaving most of the ring (64% of the sample
  /// area) free to detect an actual pencil mark.
  static const double _bubbleInnerSampleFrac = 0.6;

  /// Cheap alignment check for right after a photo is captured: does the
  /// same image load + corner search as [decode], but skips the perspective
  /// warp and bubble sampling, so it's reasonable to run on every capture
  /// rather than only at full-decode time.
  AlignmentCheck locateCorners(String imagePath, OmrExamTemplate template) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) {
        return const AlignmentCheck.misaligned(
          'Could not read the captured photo.',
        );
      }
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        return _checkAlignment(gray, template);
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Same alignment check as [locateCorners], but against a live camera
  /// preview frame instead of a captured file — cheap enough to run
  /// periodically while framing, for the on-screen guide's live
  /// per-corner feedback. [lumaBytes] is the Y (luma) plane of a YUV
  /// camera frame, already 8-bit grayscale with no color conversion
  /// needed. [bytesPerRow] may exceed [width] (row padding, common on
  /// Android camera buffers) — the extra columns are cropped off.
  ///
  /// Returns each of the 4 fiducial marks' [CornerConfidence], independently,
  /// in [top-left, top-right, bottom-left, bottom-right] order — unlike
  /// [locateCorners], this doesn't require all 4 to form a plausible
  /// rectangle together, since each corner's own viewfinder needs to react
  /// on its own as the user moves the sheet, not just an aggregate
  /// pass/fail. No geometry cross-check runs here (that needs ≥3 confident
  /// corners and is heavier) — the post-capture pass is authoritative.
  ///
  /// Searches the same way [_refineCorners] does (see [_quadrantsFor],
  /// [_findMarkerInRegion]) — a tight template-expected box first, the full
  /// photo quadrant if that misses — so the live guide and the post-capture
  /// gate can never disagree about whether a mark is findable in a frame.
  List<CornerConfidence> checkCornersFromLuma(
    Uint8List lumaBytes,
    int width,
    int height,
    int bytesPerRow,
    OmrExamTemplate template,
  ) {
    final full = cv.Mat.fromList(
      height,
      bytesPerRow,
      cv.MatType.CV_8UC1,
      lumaBytes,
    );
    try {
      final gray = bytesPerRow == width
          ? full
          : full.region(cv.Rect(0, 0, width, height));
      try {
        final pageQuad = _detectPageQuad(gray);
        final searches =
            _quadrantsFor(gray.width, gray.height, pageQuad, template);
        return [
          for (final s in searches)
            _bestOf(
              _findMarkerInRegion(gray, s.stage1, s.anchorX, s.anchorY),
              () => _findMarkerInRegion(gray, s.quadrant, s.anchorX, s.anchorY),
            ).confidence,
        ];
      } finally {
        if (!identical(gray, full)) gray.dispose();
      }
    } finally {
      full.dispose();
    }
  }

  /// Stage 1 → Stage 2: if [stage1Result] already found a confident square,
  /// use it (skip the more expensive full-quadrant search entirely). Else
  /// run [stage2] and keep whichever of the two is better (confident beats
  /// low beats none; a tie prefers the higher combined evidence).
  _MarkerSearchResult _bestOf(
    _MarkerSearchResult stage1Result,
    _MarkerSearchResult Function() stage2,
  ) {
    if (stage1Result.confidence == CornerConfidence.confident) {
      return stage1Result;
    }
    final stage2Result = stage2();
    int rank(CornerConfidence c) => switch (c) {
      CornerConfidence.confident => 2,
      CornerConfidence.low => 1,
      CornerConfidence.none => 0,
    };
    final r1 = rank(stage1Result.confidence);
    final r2 = rank(stage2Result.confidence);
    if (r2 != r1) return r2 > r1 ? stage2Result : stage1Result;
    return stage2Result.squareness >= stage1Result.squareness
        ? stage2Result
        : stage1Result;
  }

  /// Used by [locateCorners] (the post-capture gate). A [_RefineResult]
  /// with [AlignmentVerdict.green] or [AlignmentVerdict.yellow] both count
  /// as `aligned` — yellow means a usable quad was still produced (see
  /// [_refineCorners]'s Stage 4), just with a corner recovered by geometry
  /// rather than crisply detected.
  AlignmentCheck _checkAlignment(cv.Mat gray, OmrExamTemplate template) {
    try {
      final (oriented, refine, _) = _orientAndFindCorners(gray, template);
      if (!identical(oriented, gray)) oriented.dispose();
      if (refine.verdict == AlignmentVerdict.green) {
        return const AlignmentCheck.aligned();
      }
      return AlignmentCheck.degraded(refine.note, refine.confidence);
    } on StateError catch (e) {
      return AlignmentCheck.misaligned(e.message);
    }
  }

  /// Reads [imagePath] against [template] and returns the decoded marks.
  /// Throws a [StateError] with a user-facing message if the sheet couldn't
  /// be read or aligned.
  OmrScanResult decode(String imagePath, OmrExamTemplate template) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) {
        throw StateError('Could not read the captured photo at $imagePath.');
      }
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        final (oriented, refine, _) = _orientAndFindCorners(gray, template);
        final corners = refine.corners;
        try {
          final canonicalWidth = (template.pageWidthPt * _canonicalPxPerPt)
              .round();
          final canonicalHeight = (template.pageHeightPt * _canonicalPxPerPt)
              .round();

          // The 4 fiducial marks are printed at their own template-recorded
          // fractional page positions (template.cornerMarkers), not
          // necessarily near the page's literal (0,0)-(1,1) edges — a narrow
          // bubble grid (e.g. QTM's 2-column layout) leaves the marks well
          // inside the page. Mapping them to the canonical rect's literal
          // corners instead of their own fractional positions would stretch
          // that marker sub-rectangle to fill the whole canonical page,
          // throwing every BubblePos.xFrac/yFrac sample (computed as a
          // fraction of the *true* page, in _readBubbles) off by however far
          // the marks sit from the true edges — proportionally worse the
          // narrower the printed content is.
          final dstCorners = cv.VecPoint2f.fromList([
            for (final corner in template.cornerMarkers)
              cv.Point2f(
                corner.xFrac * canonicalWidth,
                corner.yFrac * canonicalHeight,
              ),
          ]);
          final srcCorners = cv.VecPoint2f.fromList(corners);
          final transform = cv.getPerspectiveTransform2f(
            srcCorners,
            dstCorners,
          );
          try {
            final warped = cv.warpPerspective(oriented, transform, (
              canonicalWidth,
              canonicalHeight,
            ));
            // Declared out here so the `finally` below can dispose it; it is
            // assigned as the first statement inside the `try`.
            cv.Mat? normalizedGray;
            try {
              // Illumination normalization runs first, on the raw warp:
              // divide out a large-scale estimate of the lighting/shadow
              // field so a strong cast shadow or an uneven LED wash reaches
              // the CLAHE + threshold stages below as a roughly evenly-lit
              // page, which is what their (fixed and darkness-adaptive)
              // margins already assume. Best-effort — [_normalizeIllumination]
              // returns `warped` itself on any failure, so `identical`
              // short-circuits every use below and the pipeline is unchanged
              // whenever normalization couldn't help.
              normalizedGray = _normalizeIllumination(warped);

              // A cast shadow (a hand, phone, or object between the light
              // source and the sheet) doesn't just darken the pixels under
              // it — a camera's auto-exposure reacts to a large dark region
              // in frame by adjusting overall exposure, which compresses
              // paper-vs-ink contrast across the *whole* photo, not just the
              // shadowed part (confirmed against a real scan: every item
              // read ambiguous, including ones nowhere near the shadow).
              // _adaptiveThresholdC's fixed margin assumes normal contrast;
              // it has no way to compensate for a photo-wide compression
              // like that. CLAHE re-normalizes local contrast per tile
              // before thresholding — the same technique already used for
              // corner-mark detection (_findMarkerInRegion) — so a
              // shadow-compressed region gets its contrast restored instead
              // of staying flattened into the ambiguous zone. clipLimit is
              // lower and the tile grid coarser than the corner search uses,
              // since this runs across the whole dense page (bubble grid +
              // header text) rather than one small ROI, and the goal here is
              // countering a slow, page-scale exposure/shadow gradient, not
              // maximizing fine local contrast.
              //
              // clipLimit is per exam code (see _claheClipLimitFor) rather
              // than one fixed value — confirmed against real scans that
              // different exams' captures need different amounts of
              // correction, and a value tuned for one can regress another.
              // The post-CLAHE blur is widened from 3x3 to 5x5 for everyone:
              // confirmed against a real scan that CLAHE, applied to an
              // almost-flat tile of blank paper (most of this page), can
              // stretch ordinary sensor/JPEG noise in that tile into a
              // visibly speckled black/white pattern after thresholding —
              // blurring more afterward reduces how much of that amplified
              // per-pixel noise survives into the ink map, where it inflates
              // a blank neighbor bubble's fill reading enough to erode a
              // genuine mark's margin over it.
              //
              // Both the clip limit and the threshold constant are then
              // additionally scaled for how dark this particular photo
              // measures (see _adaptiveClipLimit/_adaptiveThresholdCFor) —
              // a no-op at/above _referenceBrightness, so a normally-lit
              // capture goes through this exact same per-exam-tuned path as
              // before; only a measurably dim/shadowed one gets the extra
              // correction.
              //
              // Brightness is measured on `warped` (the *un*-normalized warp)
              // on purpose: the darkness-adaptive scaling keeps its exact
              // prior trigger behavior, and only the pixels routed *through*
              // CLAHE/threshold change — those come from `normalizedGray`.
              final warpedMeanScalar = warped.mean();
              double warpedBrightness;
              try {
                warpedBrightness = warpedMeanScalar.val1;
              } finally {
                warpedMeanScalar.dispose();
              }
              // Low light usually means the camera compensated with a
              // higher ISO, which means more sensor noise going into CLAHE
              // — exactly the noise-amplification risk the comment above
              // already describes, just worse than what the post-CLAHE
              // blur alone was tuned to absorb. An edge-preserving
              // bilateral filter ahead of CLAHE, strength scaled by how
              // dark this photo measures, tamps that down before it ever
              // reaches CLAHE — skipped entirely (claheInput stays
              // identical to warped) at/above _referenceBrightness, so a
              // normally-lit capture never pays this filter's real cost
              // (bilateral filtering is meaningfully slower than a plain
              // blur).
              final darkness = _darknessFactor(warpedBrightness);
              final claheInput = darkness > 0
                  ? cv.bilateralFilter(
                      normalizedGray, 5, 50 * darkness, 50 * darkness)
                  : normalizedGray;
              try {
                final clahe = cv.createCLAHE(
                  clipLimit: _adaptiveClipLimit(_claheClipLimitFor(template.examCode), warpedBrightness),
                  tileGridSize: (8, 8),
                );
                try {
                  final normalized = clahe.apply(claheInput);
                  try {
                    final blurred = cv.gaussianBlur(normalized, (5, 5), 0);
                    try {
                      final inkMap = cv.adaptiveThreshold(
                        blurred,
                        255,
                        cv.ADAPTIVE_THRESH_GAUSSIAN_C,
                        cv.THRESH_BINARY_INV,
                        _adaptiveThresholdBlockSize,
                        _adaptiveThresholdCFor(_adaptiveThresholdC, warpedBrightness),
                      );
                      try {
                        return _readBubbles(
                          inkMap,
                          template,
                          canonicalWidth,
                          canonicalHeight,
                        );
                      } finally {
                        inkMap.dispose();
                      }
                    } finally {
                      blurred.dispose();
                    }
                  } finally {
                    normalized.dispose();
                  }
                } finally {
                  clahe.dispose();
                }
              } finally {
                if (!identical(claheInput, normalizedGray)) {
                  claheInput.dispose();
                }
              }
            } finally {
              // Only a *new* Mat from _normalizeIllumination is ours to free;
              // on its bail path it hands back `warped`, disposed just below.
              if (normalizedGray != null &&
                  !identical(normalizedGray, warped)) {
                normalizedGray.dispose();
              }
              warped.dispose();
            }
          } finally {
            transform.dispose();
            srcCorners.dispose();
            dstCorners.dispose();
          }
        } finally {
          if (!identical(oriented, gray)) oriented.dispose();
        }
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Produces a perspective-corrected COLOR copy of [imagePath], saved to
  /// [outputPath], for UI display only (e.g. drawing a per-item graded
  /// overlay at each [BubblePos]'s exact fractional page position — see
  /// ScannedImageViewerScreen). Returns [outputPath] on success, or null if
  /// the sheet's corners couldn't be found in this photo. (Returns a path,
  /// not a `dart:io` `File`, only so this method's signature can be mirrored
  /// in omr_decoder_web.dart without needing a dart:io import there — that
  /// file must stay import-free of dart:io/dart:ffi to keep `flutter build
  /// web` compiling.)
  ///
  /// Deliberately entirely separate from [decode]: this does its own
  /// `imread`, its own grayscale conversion, and its own
  /// [_orientAndFindCorners] call rather than sharing any Mat or
  /// intermediate value with a `decode()` run — so this method cannot, even
  /// in principle, change what `decode()` reads off a sheet. It exists
  /// purely so a caller can additionally have a display-quality rectified
  /// image; it plays no part in scoring. (A prior attempt at this same
  /// overlay feature instead added a color-warp branch *inside* `decode()`
  /// itself, sharing its corner search — that was reverted after the user
  /// reported a possible accuracy regression that was never root-caused.
  /// Keeping this fully outside `decode()` removes that risk by
  /// construction, at the cost of finding the corners twice per scan.)
  String? rectifyForOverlay(
    String imagePath,
    OmrExamTemplate template,
    String outputPath,
  ) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) return null;
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        cv.Mat oriented;
        _RefineResult refine;
        int? rotationCode;
        try {
          (oriented, refine, rotationCode) = _orientAndFindCorners(
            gray,
            template,
          );
        } on StateError {
          return null;
        }
        final corners = refine.corners;
        try {
          // Color must be rotated the same way [oriented] was, so the
          // corners found against the (possibly rotated) grayscale image
          // still line up with what gets warped here.
          final orientedSrc = rotationCode == null
              ? src
              : cv.rotate(src, rotationCode);
          try {
            final canonicalWidth = (template.pageWidthPt * _canonicalPxPerPt)
                .round();
            final canonicalHeight =
                (template.pageHeightPt * _canonicalPxPerPt).round();
            final dstCorners = cv.VecPoint2f.fromList([
              for (final corner in template.cornerMarkers)
                cv.Point2f(
                  corner.xFrac * canonicalWidth,
                  corner.yFrac * canonicalHeight,
                ),
            ]);
            final srcCorners = cv.VecPoint2f.fromList(corners);
            final transform = cv.getPerspectiveTransform2f(
              srcCorners,
              dstCorners,
            );
            try {
              final warped = cv.warpPerspective(orientedSrc, transform, (
                canonicalWidth,
                canonicalHeight,
              ));
              try {
                cv.imwrite(outputPath, warped);
                return outputPath;
              } finally {
                warped.dispose();
              }
            } finally {
              transform.dispose();
              srcCorners.dispose();
              dstCorners.dispose();
            }
          } finally {
            if (!identical(orientedSrc, src)) orientedSrc.dispose();
          }
        } finally {
          if (!identical(oriented, gray)) oriented.dispose();
        }
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Crops the Last Name / First Name / MI boxes (see
  /// [OmrExamTemplate.lastNameFieldRect]/[firstNameFieldRect]/
  /// [middleInitialFieldRect]) for on-device OCR (see NameOcrService)
  /// directly out of [imagePath] — the original captured photo, not a
  /// rectified/display copy. Runs its own corner search and perspective
  /// warp at [_ocrCanonicalPxPerPt] (much higher than [rectifyForOverlay]'s
  /// [_canonicalPxPerPt]) so the handwritten answer itself has enough real
  /// pixels to be recognizable — see [_ocrCanonicalPxPerPt]'s doc comment
  /// for why a shared low-res rectified copy wasn't good enough. Purely a
  /// display/suggestion input, same isolation as [rectifyForOverlay]: its
  /// own `imread`/corner search/warp, sharing no Mat or intermediate value
  /// with [decode] or [rectifyForOverlay] — never touches scoring. Returns
  /// all three written paths, or null if the sheet's corners couldn't be
  /// found in this photo.
  ({String lastName, String firstName, String middleInitial})? cropNameFields(
    String imagePath,
    OmrExamTemplate template, {
    required String lastNameOutPath,
    required String firstNameOutPath,
    required String middleInitialOutPath,
  }) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) return null;
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        cv.Mat oriented;
        _RefineResult refine;
        int? rotationCode;
        try {
          (oriented, refine, rotationCode) = _orientAndFindCorners(gray, template);
        } on StateError {
          return null;
        }
        final corners = refine.corners;
        try {
          final orientedSrc = rotationCode == null ? src : cv.rotate(src, rotationCode);
          try {
            final canonicalWidth = (template.pageWidthPt * _ocrCanonicalPxPerPt).round();
            final canonicalHeight = (template.pageHeightPt * _ocrCanonicalPxPerPt).round();
            final dstCorners = cv.VecPoint2f.fromList([
              for (final corner in template.cornerMarkers)
                cv.Point2f(corner.xFrac * canonicalWidth, corner.yFrac * canonicalHeight),
            ]);
            final srcCorners = cv.VecPoint2f.fromList(corners);
            final transform = cv.getPerspectiveTransform2f(srcCorners, dstCorners);
            try {
              final warped = cv.warpPerspective(orientedSrc, transform, (canonicalWidth, canonicalHeight));
              try {
                void writeField(OmrFieldRect field, String outPath) {
                  final rect = _clampedRect(
                    field.xFrac * canonicalWidth,
                    field.yFrac * canonicalHeight,
                    (field.xFrac + field.widthFrac) * canonicalWidth,
                    (field.yFrac + field.heightFrac) * canonicalHeight,
                    canonicalWidth,
                    canonicalHeight,
                  );
                  final roi = warped.region(rect);
                  try {
                    // Pencil handwriting has much lower/uneven contrast
                    // against paper than the crisp printed field label —
                    // confirmed on a real scan (via a temporary raw-OCR-text
                    // log) that ML Kit's text *detector* can fail to flag a
                    // faint handwritten line as text at all, rather than
                    // misreading it, so the printed label gets recognized
                    // and the handwriting is silently dropped before
                    // recognition ever runs. CLAHE re-normalizes local
                    // contrast (same technique already used before
                    // thresholding for bubble detection) to close that gap
                    // before handing the crop to OCR — small tile grid since
                    // this crop is much smaller than a full page, clip limit
                    // matching the other small-ROI CLAHE use
                    // (_findMarkerInRegion). A light blur afterward tamps
                    // down the noise CLAHE can amplify in an otherwise
                    // near-blank paper region.
                    final grayRoi = cv.cvtColor(roi, cv.COLOR_BGR2GRAY);
                    try {
                      final clahe = cv.createCLAHE(clipLimit: 3, tileGridSize: (4, 4));
                      try {
                        final enhanced = clahe.apply(grayRoi);
                        try {
                          final blurred = cv.gaussianBlur(enhanced, (3, 3), 0);
                          try {
                            cv.imwrite(outPath, blurred);
                          } finally {
                            blurred.dispose();
                          }
                        } finally {
                          enhanced.dispose();
                        }
                      } finally {
                        clahe.dispose();
                      }
                    } finally {
                      grayRoi.dispose();
                    }
                  } finally {
                    roi.dispose();
                  }
                }

                writeField(template.lastNameFieldRect, lastNameOutPath);
                writeField(template.firstNameFieldRect, firstNameOutPath);
                writeField(template.middleInitialFieldRect, middleInitialOutPath);
                return (
                  lastName: lastNameOutPath,
                  firstName: firstNameOutPath,
                  middleInitial: middleInitialOutPath,
                );
              } finally {
                warped.dispose();
              }
            } finally {
              transform.dispose();
              srcCorners.dispose();
              dstCorners.dispose();
            }
          } finally {
            if (!identical(orientedSrc, src)) orientedSrc.dispose();
          }
        } finally {
          if (!identical(oriented, gray)) oriented.dispose();
        }
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Debug-only: writes two annotated JPEGs to [outputDir] — the detected
  /// corner markers drawn on the original photo, and the full expected
  /// bubble grid drawn on the warped/aligned image — so a misread sheet can
  /// be diagnosed by looking at where the decoder actually thinks things
  /// are, instead of guessing from decoded results alone. [outputDir] must
  /// already exist and be writable.
  void saveDebugVisualization(
    String imagePath,
    OmrExamTemplate template,
    String outputDir,
    int pageIndex,
  ) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) return;
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        cv.Mat oriented;
        _RefineResult refine;
        int? rotationCode;
        try {
          (oriented, refine, rotationCode) = _orientAndFindCorners(
            gray,
            template,
          );
        } on StateError catch (e) {
          // Corner detection itself failed — still write the raw photo so
          // framing/lighting/orientation can be inspected, plus the exact
          // error, instead of silently producing no debug output for
          // precisely the failing case that needs to be seen.
          cv.imwrite('$outputDir/sheet${pageIndex}_FAILED.jpg', src);
          File(
            '$outputDir/sheet${pageIndex}_error.txt',
          ).writeAsStringSync(e.message);
          return;
        }
        final corners = refine.corners;
        try {
          // For a landscape template that needed a rotation to align (see
          // _orientAndFindCorners), src has to be rotated the same exact way
          // so every debug image below — corners, color grid, grayscale
          // stages — is drawn against the same orientation the real corners
          // (and decode()'s real pipeline) actually use. Untouched (and
          // undisposed separately) when no rotation was needed.
          final orientedSrc = rotationCode == null
              ? src
              : cv.rotate(src, rotationCode);
          try {
            final cornersDebug = orientedSrc.clone();
            try {
              // The page-boundary estimate (yellow) is drawn separately from
              // the final selected marks (red) so a bad final pick can be
              // told apart from a bad *anchor* feeding into it: if the yellow
              // quad already isn't on the sheet, _detectPageQuad is the stage
              // to fix; if it's fine but the red circles still aren't on the
              // marks, the problem is in _findMarkerInRegion's own filtering.
              final pageQuad = _detectPageQuad(oriented);
              if (pageQuad != null) {
                // pageQuad is [topLeft, topRight, bottomLeft, bottomRight] —
                // not already a perimeter walk — so draw it in actual
                // clockwise order (TL, TR, BR, BL) or the "quad" comes out as
                // a bowtie instead of an outline.
                final perimeter = [
                  pageQuad[0],
                  pageQuad[1],
                  pageQuad[3],
                  pageQuad[2],
                ];
                for (var i = 0; i < perimeter.length; i++) {
                  final (x, y) = perimeter[i];
                  cv.circle(
                    cornersDebug,
                    cv.Point(x.round(), y.round()),
                    10,
                    cv.Scalar(0, 255, 255),
                    thickness: 3,
                  );
                  final (nx, ny) = perimeter[(i + 1) % perimeter.length];
                  cv.line(
                    cornersDebug,
                    cv.Point(x.round(), y.round()),
                    cv.Point(nx.round(), ny.round()),
                    cv.Scalar(0, 255, 255),
                    thickness: 2,
                  );
                }
              }
              const cornerLabels = ['TL', 'TR', 'BL', 'BR'];
              for (var i = 0; i < 4; i++) {
                // Stage-1 search box (thin blue) — the template-expected
                // prior, never a hard crop; useful to see it actually
                // landed on the real marker (or didn't, explaining a
                // Stage-2 fallback).
                cv.rectangle(
                  cornersDebug,
                  refine.stage1Regions[i],
                  cv.Scalar(255, 140, 0),
                  thickness: 2,
                );
                // Every candidate this corner rejected — orange, sized by
                // how highly it scored, so a near-miss (a bubble that
                // almost won) stands out from obvious clutter.
                for (final r in refine.rejectedPerCorner[i]) {
                  final cx = r.bboxGlobal.x + r.bboxGlobal.width ~/ 2;
                  final cy = r.bboxGlobal.y + r.bboxGlobal.height ~/ 2;
                  cv.circle(
                    cornersDebug,
                    cv.Point(cx, cy),
                    6 + (r.squareness * 10).round(),
                    cv.Scalar(0, 140, 255),
                    thickness: 2,
                  );
                  cv.putText(
                    cornersDebug,
                    '${r.reason} sq=${r.squareness.toStringAsFixed(2)}',
                    cv.Point(cx + 10, cy),
                    cv.FONT_HERSHEY_SIMPLEX,
                    0.4,
                    cv.Scalar(0, 140, 255),
                    thickness: 1,
                  );
                }
              }
              for (var i = 0; i < 4; i++) {
                final c = corners[i];
                final confidence = refine.confidence[i];
                // Confident = green (the check that used to reject the real
                // square at this pixel scale is gone); low/rescued = amber,
                // so a Stage-4 geometry-assisted rescue is visibly distinct
                // from a crisp detection, not indistinguishable red.
                final color = confidence == CornerConfidence.confident
                    ? cv.Scalar(0, 255, 0)
                    : cv.Scalar(0, 200, 255);
                cv.circle(
                  cornersDebug,
                  cv.Point(c.x.round(), c.y.round()),
                  16,
                  color,
                  thickness: 5,
                );
                cv.putText(
                  cornersDebug,
                  '${cornerLabels[i]} ${confidence.name}',
                  cv.Point(c.x.round() + 20, c.y.round() - 10),
                  cv.FONT_HERSHEY_SIMPLEX,
                  0.6,
                  color,
                  thickness: 2,
                );
              }
              if (refine.note != null) {
                cv.putText(
                  cornersDebug,
                  refine.note!,
                  cv.Point(20, cornersDebug.height - 20),
                  cv.FONT_HERSHEY_SIMPLEX,
                  0.5,
                  cv.Scalar(0, 200, 255),
                  thickness: 1,
                );
              }
              cv.imwrite(
                '$outputDir/sheet${pageIndex}_corners.jpg',
                cornersDebug,
              );
            } finally {
              cornersDebug.dispose();
            }

            final canonicalWidth = (template.pageWidthPt * _canonicalPxPerPt)
                .round();
            final canonicalHeight = (template.pageHeightPt * _canonicalPxPerPt)
                .round();
            final dstCorners = cv.VecPoint2f.fromList([
              for (final corner in template.cornerMarkers)
                cv.Point2f(
                  corner.xFrac * canonicalWidth,
                  corner.yFrac * canonicalHeight,
                ),
            ]);
            final srcCorners = cv.VecPoint2f.fromList(corners);
            final transform = cv.getPerspectiveTransform2f(
              srcCorners,
              dstCorners,
            );
            try {
              final warped = cv.warpPerspective(orientedSrc, transform, (
                canonicalWidth,
                canonicalHeight,
              ));
              try {
                for (final section in template.sections) {
                  for (final entry in section.items.entries) {
                    for (final bubble in entry.value) {
                      final x = (bubble.xFrac * canonicalWidth).round();
                      final y = (bubble.yFrac * canonicalHeight).round();
                      cv.circle(
                        warped,
                        cv.Point(x, y),
                        3,
                        cv.Scalar(0, 0, 255),
                        thickness: -1,
                      );
                    }
                  }
                }
                cv.imwrite('$outputDir/sheet${pageIndex}_grid.jpg', warped);
              } finally {
                warped.dispose();
              }

              // The actual grayscale pipeline decode() reads bubbles from —
              // same warp, same CLAHE, same threshold, on the grayscale image
              // rather than color — saved at each stage so a misread can be
              // diagnosed against what the decoder actually saw, not a
              // reconstruction of it. sheetN_warped_gray.jpg is the flattened
              // page before any contrast correction; sheetN_clahe.jpg is after
              // (compare the two to see how much correction was needed);
              // sheetN_inkmap.jpg is the final black/white result
              // _readBubbles actually samples — white is "ink" everywhere it
              // matters for scoring.
              final warpedGray = cv.warpPerspective(oriented, transform, (
                canonicalWidth,
                canonicalHeight,
              ));
              // Declared out here so the `finally` can dispose it.
              cv.Mat? normalizedDebugGray;
              try {
                cv.imwrite(
                  '$outputDir/sheet${pageIndex}_warped_gray.jpg',
                  warpedGray,
                );
                // Same illumination normalization decode() now applies,
                // saved as its own stage between warped_gray and clahe so a
                // shadow's removal is directly visible. When
                // _normalizeIllumination declines, it hands back `warpedGray`
                // and this image is simply identical to the previous one.
                normalizedDebugGray = _normalizeIllumination(warpedGray);
                cv.imwrite(
                  '$outputDir/sheet${pageIndex}_normalized.jpg',
                  normalizedDebugGray,
                );
                // Kept identical to the real decode path above (clipLimit,
                // blur kernel, brightness-adaptive scaling, and now the
                // illumination normalization too) so this debug output
                // actually reflects what _readBubbles saw, not a different
                // pipeline.
                final warpedGrayMeanScalar = warpedGray.mean();
                double warpedGrayBrightness;
                try {
                  warpedGrayBrightness = warpedGrayMeanScalar.val1;
                } finally {
                  warpedGrayMeanScalar.dispose();
                }
                // Same darkness-scaled bilateral pre-filter decode() now
                // runs — a no-op Mat reference (not a real filter call) at/
                // above _referenceBrightness — over the normalized image,
                // exactly as decode() does.
                final grayDarkness = _darknessFactor(warpedGrayBrightness);
                final grayClaheInput = grayDarkness > 0
                    ? cv.bilateralFilter(normalizedDebugGray, 5,
                        50 * grayDarkness, 50 * grayDarkness)
                    : normalizedDebugGray;
                try {
                  final clahe = cv.createCLAHE(
                    clipLimit: _adaptiveClipLimit(_claheClipLimitFor(template.examCode), warpedGrayBrightness),
                    tileGridSize: (8, 8),
                  );
                  try {
                    final normalized = clahe.apply(grayClaheInput);
                    try {
                      cv.imwrite(
                        '$outputDir/sheet${pageIndex}_clahe.jpg',
                        normalized,
                      );
                      final blurred = cv.gaussianBlur(normalized, (5, 5), 0);
                      try {
                        final inkMap = cv.adaptiveThreshold(
                          blurred,
                          255,
                          cv.ADAPTIVE_THRESH_GAUSSIAN_C,
                          cv.THRESH_BINARY_INV,
                          _adaptiveThresholdBlockSize,
                          _adaptiveThresholdCFor(_adaptiveThresholdC, warpedGrayBrightness),
                        );
                        try {
                          cv.imwrite(
                            '$outputDir/sheet${pageIndex}_inkmap.jpg',
                            inkMap,
                          );
                        } finally {
                          inkMap.dispose();
                        }
                      } finally {
                        blurred.dispose();
                      }
                    } finally {
                      normalized.dispose();
                    }
                  } finally {
                    clahe.dispose();
                  }
                } finally {
                  if (!identical(grayClaheInput, normalizedDebugGray)) {
                    grayClaheInput.dispose();
                  }
                }
              } finally {
                // Only a *new* Mat from _normalizeIllumination is ours here;
                // its bail path returns `warpedGray`, disposed just below.
                if (normalizedDebugGray != null &&
                    !identical(normalizedDebugGray, warpedGray)) {
                  normalizedDebugGray.dispose();
                }
                warpedGray.dispose();
              }
            } finally {
              transform.dispose();
              srcCorners.dispose();
              dstCorners.dispose();
            }
          } finally {
            if (rotationCode != null) orientedSrc.dispose();
          }
        } finally {
          if (rotationCode != null) oriented.dispose();
        }
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Finds each of the sheet's 4 fiducial corner marks.
  ///
  /// Stage 1: search a tight box around where *this exam's* own marker is
  /// actually printed ([_quadrantsFor]'s `stage1`). Stage 2: on a miss,
  /// expand to the full photo quadrant (today's original behavior,
  /// unchanged) — a wrong or imprecise position estimate only costs one
  /// extra search pass, never a missed mark. Stage 3 (shape / fill /
  /// contrast / position evaluation) happens inside [_findMarkerInRegion]
  /// itself. Stage 4: with ≥3 [CornerConfidence.confident] corners, fit the
  /// affine transform through them and (a) reject any other point that
  /// maps inside the answer-grid bounding box or far from its own expected
  /// position — this is what stops a shaded answer bubble from riding
  /// along as a "corner" even when 3 real squares were found — and (b) for
  /// a corner that's now missing, run one more *dedicated* search of the
  /// small box the other three predict it should be in, promoting it only
  /// if that search finds real marker evidence there (never a bare
  /// geometric point).
  ///
  /// All 4 fiducial marks must still end up with a centroid — no
  /// reconstructing one from geometry alone. Requiring that makes "not
  /// enough was detected" a hard rejection (never a silent guess) feeding
  /// perspective correction and bubble sampling. Returns the 4 refined
  /// centroids plus per-corner confidence in [top-left, top-right,
  /// bottom-left, bottom-right] order.
  _RefineResult _refineCorners(cv.Mat gray, OmrExamTemplate template) {
    const labels = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];
    final pageQuad = _detectPageQuad(gray);
    final searches = _quadrantsFor(gray.width, gray.height, pageQuad, template);

    if (_kFiducialDebug) {
      _fidLog(
        '===== pass on ${gray.width}x${gray.height} image | '
        'pageQuad=${pageQuad == null ? "null (fallback: literal photo corners)" : pageQuad.map((p) => "(${p.$1.toStringAsFixed(0)},${p.$2.toStringAsFixed(0)})").join(" ")} =====',
      );
      for (var i = 0; i < searches.length; i++) {
        final s = searches[i];
        _fidLog(
          'stage1 q=${labels[i]} = (${s.stage1.x},${s.stage1.y},${s.stage1.width},${s.stage1.height}) '
          'quadrant=(${s.quadrant.x},${s.quadrant.y},${s.quadrant.width},${s.quadrant.height}) '
          'anchor=(${s.anchorX.toStringAsFixed(1)},${s.anchorY.toStringAsFixed(1)})',
        );
      }
    }

    // Stage 1 -> Stage 2.
    final results = List<_MarkerSearchResult>.generate(4, (i) {
      final s = searches[i];
      final tag = _kFiducialDebug ? labels[i] : null;
      final stage1Result =
          _findMarkerInRegion(gray, s.stage1, s.anchorX, s.anchorY, debugTag: tag);
      return _bestOf(
        stage1Result,
        () => _findMarkerInRegion(gray, s.quadrant, s.anchorX, s.anchorY, debugTag: tag),
      );
    });

    if (_kFiducialDebug) {
      for (var i = 0; i < 4; i++) {
        final c = results[i].centroid;
        _fidLog(
          'WINNER q=${labels[i]} tier=${results[i].confidence.name} '
          '${c == null ? "NOT FOUND" : "(${c.x.toStringAsFixed(1)},${c.y.toStringAsFixed(1)})"} '
          'sq=${results[i].squareness.toStringAsFixed(3)}',
        );
      }
    }

    final points =
        List<cv.Point2f?>.generate(4, (i) => results[i].centroid);
    String? note;

    // Stage 4: geometric cross-check + dedicated rescue search. Only
    // meaningful with >=3 confidently-detected corners to fit a transform
    // through.
    final confidentIdx = [
      for (var i = 0; i < 4; i++)
        if (results[i].confidence == CornerConfidence.confident) i,
    ];
    if (confidentIdx.length >= 3) {
      final threeIdx = confidentIdx.take(3).toList();
      final threePts = [for (final i in threeIdx) points[i]!];
      if (!_nearCollinear(threePts)) {
        final threeFracs = [
          for (final i in threeIdx)
            cv.Point2f(
              template.cornerMarkers[i].xFrac,
              template.cornerMarkers[i].yFrac,
            ),
        ];
        final imgToFrac = cv.getAffineTransform2f(
          cv.VecPoint2f.fromList(threePts),
          cv.VecPoint2f.fromList(threeFracs),
        );
        try {
          final grid = _answerGridBboxFrac(template);
          bool insideGrid(double fx, double fy) =>
              fx >= grid.x0 && fx <= grid.x1 && fy >= grid.y0 && fy <= grid.y1;

          // 4a: downgrade any non-anchor point that's geometrically
          // implausible — this is what rejects a shaded bubble even though
          // it otherwise scored as a confident/low square.
          for (var i = 0; i < 4; i++) {
            if (threeIdx.contains(i) || points[i] == null) continue;
            final p = points[i]!;
            final (fx, fy) = _applyAffine(imgToFrac, p.x.toDouble(), p.y.toDouble());
            final marker = template.cornerMarkers[i];
            final off = math.sqrt(
                math.pow(fx - marker.xFrac, 2) + math.pow(fy - marker.yFrac, 2));
            final bad = insideGrid(fx, fy) || off > _affineToleranceFrac;
            if (bad) {
              if (_kFiducialDebug) {
                _fidLog('q=${labels[i]} DOWNGRADE reason=${insideGrid(fx, fy) ? "inside_grid" : "geom_inconsistent"} '
                    'frac=(${fx.toStringAsFixed(3)},${fy.toStringAsFixed(3)}) off=${off.toStringAsFixed(3)}');
              }
              points[i] = null;
              results[i] = _MarkerSearchResult(
                centroid: null,
                bboxGlobal: results[i].bboxGlobal,
                confidence: CornerConfidence.none,
                squareness: results[i].squareness,
                contrast: results[i].contrast,
                anchorDistance: results[i].anchorDistance,
                rejected: results[i].rejected,
              );
            }
          }

          // 4b: dedicated rescue search for exactly the corners now
          // missing — search the small box the other three predict, and
          // promote only on real marker evidence found there.
          final fracToImg = cv.getAffineTransform2f(
            cv.VecPoint2f.fromList(threeFracs),
            cv.VecPoint2f.fromList(threePts),
          );
          try {
            for (var i = 0; i < 4; i++) {
              if (threeIdx.contains(i) || points[i] != null) continue;
              final marker = template.cornerMarkers[i];
              final (px, py) =
                  _applyAffine(fracToImg, marker.xFrac, marker.yFrac);
              final halfExtent =
                  _stage1HalfExtentFrac * math.min(gray.width, gray.height) * 0.75;
              final rescueBox = _clampedRect(
                px - halfExtent,
                py - halfExtent,
                px + halfExtent,
                py + halfExtent,
                gray.width,
                gray.height,
              );
              final tag = _kFiducialDebug ? '${labels[i]}-rescue' : null;
              final rr =
                  _findMarkerInRegion(gray, rescueBox, px, py, debugTag: tag);
              final rc = rr.centroid;
              if (rc == null ||
                  rr.squareness < _markerMinSquarenessLow ||
                  rr.contrast < _markerMinContrast) {
                if (_kFiducialDebug) {
                  _fidLog('q=${labels[i]} RESCUE_FAILED no convincing marker '
                      'evidence near predicted (${px.toStringAsFixed(1)},${py.toStringAsFixed(1)})');
                }
                continue;
              }
              final (rfx, rfy) =
                  _applyAffine(imgToFrac, rc.x.toDouble(), rc.y.toDouble());
              final roff = math.sqrt(
                  math.pow(rfx - marker.xFrac, 2) + math.pow(rfy - marker.yFrac, 2));
              if (insideGrid(rfx, rfy) || roff > _affineToleranceFrac) {
                if (_kFiducialDebug) {
                  _fidLog('q=${labels[i]} RESCUE_FAILED candidate found but '
                      'geometrically inconsistent (frac=(${rfx.toStringAsFixed(3)},${rfy.toStringAsFixed(3)}))');
                }
                continue;
              }
              points[i] = rc;
              results[i] = _MarkerSearchResult(
                centroid: rc,
                bboxGlobal: rr.bboxGlobal,
                confidence: CornerConfidence.low,
                squareness: rr.squareness,
                contrast: rr.contrast,
                anchorDistance: rr.anchorDistance,
                rejected: rr.rejected,
              );
              note = '${labels[i]} corner recovered via geometry-assisted rescue';
              if (_kFiducialDebug) {
                _fidLog('q=${labels[i]} RESCUED sq=${rr.squareness.toStringAsFixed(3)}');
              }
            }
          } finally {
            fracToImg.dispose();
          }
        } finally {
          imgToFrac.dispose();
        }
      }
    }

    // All 4 fiducial marks must end up with a centroid — no reconstructing
    // one from geometry alone (Stage 4b only promotes an actually-detected
    // blob). Requiring a clean 4/4 makes "not enough was detected" a hard
    // rejection instead of a silent guess feeding into perspective
    // correction and bubble sampling.
    final missing = [
      for (var i = 0; i < 4; i++)
        if (points[i] == null) i,
    ];
    if (missing.isNotEmpty) {
      final names = missing.map((i) => labels[i]).join(', ');
      throw StateError(
        'Could not find the $names alignment mark${missing.length > 1 ? 's' : ''}. '
        'Page not fully detected. Please align the sheet and try again.',
      );
    }

    final resolved = points.cast<cv.Point2f>();
    _validateQuad(
      resolved,
      template,
      gray,
      [for (final r in results) r.bboxGlobal ?? cv.Rect(0, 0, 1, 1)],
      [for (final r in results) r.squareness],
    );

    final finalConfidentCount = results
        .where((r) => r.confidence == CornerConfidence.confident)
        .length;
    final verdict =
        finalConfidentCount == 4 ? AlignmentVerdict.green : AlignmentVerdict.yellow;

    if (_kFiducialDebug) {
      _fidLog(
        'final corners TL/TR/BL/BR = '
        '${resolved.map((p) => "(${p.x.toStringAsFixed(1)},${p.y.toStringAsFixed(1)})").join(" ")} '
        'verdict=${verdict.name}',
      );
    }

    return _RefineResult(
      corners: resolved,
      confidence: [for (final r in results) r.confidence],
      verdict: verdict,
      stage1Regions: [for (final s in searches) s.stage1],
      rejectedPerCorner: [for (final r in results) r.rejected],
      note: note,
    );
  }

  /// [_refineCorners], but tolerant of the sheet being rotated 90° in the
  /// photo — needed for a landscape-page template (currently only TAT)
  /// because the app's whole capture UI is locked to portrait (see
  /// main.dart's SystemChrome.setPreferredOrientations): the only way to
  /// get a landscape sheet to fill a portrait camera frame is to physically
  /// turn the paper sideways, and nothing constrains which way — clockwise
  /// or counterclockwise — a given user turns it. _refineCorners on its
  /// own assumes the photo's own top-left/top-right/bottom-left/bottom-
  /// right quadrants directly contain the sheet's own same-named corner
  /// marks (see _quadrantsFor), which is only true when the sheet is
  /// upright in frame.
  ///
  /// Tries the image as captured first (correct for every portrait-page
  /// template, and for a landscape one shot without rotating, e.g. a flat
  /// overhead photo rather than the handheld portrait-frame case), then
  /// each 90° rotation in turn, returning whichever succeeds. Portrait-page
  /// templates never attempt a rotation at all — there's no ambiguity to
  /// resolve for them, and doing so would just be wasted work.
  ///
  /// Returns the Mat actually used (identical to [gray] when no rotation
  /// was needed, otherwise a new rotated Mat the caller must separately
  /// dispose), its corners, and which rotation code was used to get there
  /// (null when [gray] needed none) — callers that also need to reproduce
  /// the same rotation on a second image (e.g. saveDebugVisualization's
  /// color [src]) need the exact code, not just "was it rotated": a 90°
  /// rotation in either direction changes a Mat's width/height the same
  /// way, so that alone can't tell them apart.
  (cv.Mat, _RefineResult, int?) _orientAndFindCorners(
    cv.Mat gray,
    OmrExamTemplate template,
  ) {
    if (template.pageWidthPt <= template.pageHeightPt) {
      return (gray, _refineCorners(gray, template), null);
    }
    StateError lastError;
    try {
      return (gray, _refineCorners(gray, template), null);
    } on StateError catch (e) {
      lastError = e;
    }
    for (final code in [
      cv.ROTATE_90_CLOCKWISE,
      cv.ROTATE_90_COUNTERCLOCKWISE,
    ]) {
      final rotated = cv.rotate(gray, code);
      try {
        return (rotated, _refineCorners(rotated, template), code);
      } on StateError catch (e) {
        lastError = e;
        rotated.dispose();
      }
    }
    throw lastError;
  }

  /// Finding *a* plausible small dark blob near each of the 4 expected
  /// corner spots isn't enough on its own — if the sheet is out of frame or
  /// badly misaligned, those 4 windows can each still latch onto unrelated
  /// clutter (shadows, texture, edges) that individually passes the
  /// size filter, so the corner search silently "succeeds" on nonsense.
  /// This checks the 4 found points actually form a plausible sheet-shaped
  /// rectangle together before accepting them.
  void _validateQuad(
    List<cv.Point2f> corners,
    OmrExamTemplate template,
    cv.Mat gray,
    List<cv.Rect> markerBoxes,
    List<double> squarenessPerCorner,
  ) {
    final tl = corners[0], tr = corners[1], bl = corners[2], br = corners[3];

    if (tl.x >= tr.x || bl.x >= br.x || tl.y >= bl.y || tr.y >= br.y) {
      throw StateError(
        'The detected corner marks are not arranged like the sheet. Retake the photo with the sheet upright and all four corners visible.',
      );
    }

    final width = ((tr.x - tl.x) + (br.x - bl.x)) / 2;
    final height = ((bl.y - tl.y) + (br.y - tr.y)) / 2;
    final expectedAspect = template.pageWidthPt / template.pageHeightPt;
    final actualAspect = width / height;
    // A real sheet's aspect ratio should match reasonably closely (paper
    // dimensions are exact), but this is a coarse secondary check — the
    // anchor-distance scoring in _findMarkerInRegion (prefer whichever
    // candidate sits closest to this quadrant's own estimated corner) is
    // the primary defense against picking up background clutter (a second
    // sheet, wall, furniture) instead of the actual sheet. 0.15 (tightened
    // from an original 0.35
    // that let a clutter-quad through) turned out to reject too many
    // genuine handheld photos too, whose measured aspect ratio shifts more
    // than that from normal perspective/keystone distortion at a
    // non-perfectly-perpendicular angle. 0.25 is a middle ground.
    if ((actualAspect - expectedAspect).abs() > expectedAspect * 0.25) {
      throw StateError(
        "The detected corners don't form a sheet-shaped rectangle. Retake the photo with just the one sheet, on a plain background, in frame.",
      );
    }

    final imageArea = gray.width * gray.height;
    final quadArea = width * height;
    if (quadArea < imageArea * 0.05) {
      throw StateError(
        'The sheet appears too small in this photo. Move closer and retake.',
      );
    }

    // No upper bound previously existed here — only "too small", never "too
    // big" or "too close to the frame edge". Confirmed this lets a false
    // pass through when the camera is zoomed in far enough that the real
    // corner marks fall partially or fully outside the frame: the
    // quadrant search (see _findMarkerInRegion's own doc comment — it
    // searches the *whole* quadrant, not a small window) can still latch
    // onto some other dark, roughly-square-ish blob near the frame edge —
    // a bubble row, header text, page clutter — and that false quad can
    // still happen to pass the aspect-ratio check above by coincidence.
    // Two checks catch this instead of one, since neither alone covers
    // every way "zoomed in too far" can present:
    if (quadArea > imageArea * 0.85) {
      throw StateError(
        'The sheet fills too much of the frame. Move back so all 4 corner marks have visible margin around them, then retake.',
      );
    }
    // A genuine corner mark is always printed with real margin around it
    // (kPageMargin + kMarkerPad in tool/generate_sheets.dart) — a
    // correctly-framed capture should never have a *found* corner sitting
    // right at the photo's own boundary. When the camera is zoomed in
    // past the point where the real mark is still in frame, whatever the
    // search fell back to accepting instead is disproportionately likely
    // to be hugging that boundary, unlike a genuine capture with visible
    // background on every side.
    const edgeMarginFrac = 0.015;
    final edgeMarginX = gray.width * edgeMarginFrac;
    final edgeMarginY = gray.height * edgeMarginFrac;
    for (final corner in corners) {
      if (corner.x < edgeMarginX ||
          corner.x > gray.width - edgeMarginX ||
          corner.y < edgeMarginY ||
          corner.y > gray.height - edgeMarginY) {
        throw StateError(
          'The sheet appears too close or cropped by the frame edge. Move back so the whole sheet is visible with margin around it, then retake.',
        );
      }
    }

    // The checks above only ever looked at the 4 points as an aggregate
    // quad — 3 real squares plus one shaded answer bubble sitting roughly
    // in the right place passes every one of them. These two checks
    // compare the 4 *markers themselves*: the printed squares are
    // identical in size and shape, so one that's a very different size, or
    // shaped nothing like the other three, is the tell.
    if (markerBoxes.length == 4 && squarenessPerCorner.length == 4) {
      final sizes = [
        for (final b in markerBoxes) math.sqrt(b.width * b.height),
      ]..sort();
      final medianSize = (sizes[1] + sizes[2]) / 2;
      if (medianSize > 0) {
        for (final b in markerBoxes) {
          final s = math.sqrt(b.width * b.height);
          if (s < medianSize * 0.45 || s > medianSize * 2.2) {
            throw StateError(
              'One detected corner mark is a very different size from the others. Retake with all four corner squares clearly visible.',
            );
          }
        }
      }
      final sortedSquareness = [...squarenessPerCorner]..sort();
      final medianSquareness = (sortedSquareness[1] + sortedSquareness[2]) / 2;
      if (sortedSquareness.first < _markerMinSquarenessLow &&
          medianSquareness > 0.70) {
        throw StateError(
          'One detected corner mark does not look like the others. Retake with all four corner squares clearly visible.',
        );
      }
    }
  }

  /// Finds the largest convex quadrilateral near the center of the photo
  /// that plausibly bounds the sheet (page edge against whatever background
  /// surrounds it), returning its corners ordered [topLeft, topRight,
  /// bottomLeft, bottomRight], or null if no such quad is found (e.g. the
  /// page already fills the whole frame, so there's no visible boundary
  /// edge to detect). Used only to seed a *scoring anchor* for the
  /// full-quadrant marker search (see [_quadrantsFor]), not to restrict
  /// where that search looks — an imprecise estimate here still lets the
  /// true mark win over background clutter, it just needs to be closer to
  /// the mark than the clutter is, not pixel-accurate.
  ///
  /// Requiring the candidate's centroid to be reasonably central rules out
  /// unrelated background objects - a second sheet lower in frame, a wall
  /// corner, furniture - that can otherwise out-area the actual sheet and
  /// get picked as "the page" just because they're bigger, even though the
  /// on-screen guide already tells the user to center the sheet they're
  /// scanning.
  List<(double, double)>? _detectPageQuad(cv.Mat gray) {
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    try {
      // Canny thresholds derived from this photo's own mean brightness
      // (the well-known "auto Canny" approach, substituting mean for the
      // more common median here since a mean is already computed elsewhere
      // in this file with the same `.mean()` call and a photographed sheet's
      // grayscale histogram is roughly unimodal, so the two track closely)
      // rather than a fixed 50/150 tuned against whatever lighting one past
      // test photo happened to have. Classroom photos vary a lot in
      // exposure — a fixed pair of absolute thresholds is either too
      // sensitive (picks up desk texture/shadow as edges) on a bright photo
      // or misses the actual page boundary on a dim one; scaling both
      // thresholds off the photo's own brightness keeps the same relative
      // sensitivity across that range instead of guessing one setting for
      // an unknown "typical" photo.
      final meanScalar = blurred.mean();
      double meanIntensity;
      try {
        meanIntensity = meanScalar.val1;
      } finally {
        meanScalar.dispose();
      }
      const cannySigma = 0.33;
      final lower = (meanIntensity * (1 - cannySigma)).clamp(0, 255);
      final upper = (meanIntensity * (1 + cannySigma)).clamp(0, 255);
      final edges = cv.canny(blurred, lower.toDouble(), upper.toDouble());
      try {
        final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
        try {
          final dilated = cv.dilate(edges, kernel, iterations: 2);
          try {
            final (contours, hierarchy) = cv.findContours(
              dilated,
              cv.RETR_LIST,
              cv.CHAIN_APPROX_SIMPLE,
            );
            try {
              final imageArea = (gray.width * gray.height).toDouble();
              final centerX = gray.width / 2;
              final centerY = gray.height / 2;
              final maxCenterDistance =
                  0.3 *
                  math.sqrt(
                    gray.width * gray.width + gray.height * gray.height,
                  ) /
                  2;
              List<(double, double)>? bestQuad;
              double bestArea = 0;
              for (final contour in contours) {
                final area = cv.contourArea(contour);
                if (area < imageArea * 0.2 || area <= bestArea) continue;

                List<(double, double)>? points;
                final peri = cv.arcLength(contour, true);
                final approx = cv.approxPolyDP(contour, 0.02 * peri, true);
                try {
                  if (approx.length == 4 && cv.isContourConvex(approx)) {
                    points = [
                      for (final p in approx) (p.x.toDouble(), p.y.toDouble()),
                    ];
                  }
                } finally {
                  approx.dispose();
                }

                // approxPolyDP didn't resolve a clean convex quad — a
                // shadow, a crease, or clutter touching the page's edge
                // commonly breaks the boundary into >4 vertices even though
                // it's still roughly rectangular. Falling back to the
                // contour's minimum-area bounding rectangle instead of
                // discarding it outright means a page whose edge is
                // well-formed apart from one broken segment still seeds a
                // usable anchor, rather than falling all the way back to
                // the coarser "page fills the frame" fallback every time
                // polygon approximation isn't perfectly clean.
                if (points == null) {
                  final rect = cv.minAreaRect(contour);
                  try {
                    // Guard against accepting a non-rectangular blob (an L
                    // shape, a diagonal object) just because it's large and
                    // central: a genuine page edge should fill most of its
                    // own minimum-area rectangle, so require the contour to
                    // cover a healthy majority of that box's area before
                    // trusting the box as a page-quad substitute.
                    final boxArea = rect.size.width * rect.size.height;
                    if (boxArea <= 0 || area < boxArea * 0.6) continue;
                    final boxPts = rect.points;
                    try {
                      points = [for (final p in boxPts) (p.x, p.y)];
                    } finally {
                      boxPts.dispose();
                    }
                  } finally {
                    rect.dispose();
                  }
                }

                final centroidX =
                    points.map((p) => p.$1).reduce((a, b) => a + b) / 4;
                final centroidY =
                    points.map((p) => p.$2).reduce((a, b) => a + b) / 4;
                final centerDistance = math.sqrt(
                  math.pow(centroidX - centerX, 2) +
                      math.pow(centroidY - centerY, 2),
                );
                if (centerDistance > maxCenterDistance) continue;
                bestArea = area;
                bestQuad = points;
              }
              return bestQuad == null ? null : _orderQuadCorners(bestQuad);
            } finally {
              contours.dispose();
              hierarchy.dispose();
            }
          } finally {
            dilated.dispose();
          }
        } finally {
          kernel.dispose();
        }
      } finally {
        edges.dispose();
      }
    } finally {
      blurred.dispose();
    }
  }

  /// Orders 4 arbitrary quad points as [topLeft, topRight, bottomLeft,
  /// bottomRight]: top-left has the smallest x+y, bottom-right the largest;
  /// top-right has the largest x-y, bottom-left the smallest.
  List<(double, double)> _orderQuadCorners(List<(double, double)> pts) {
    final bySum = [...pts]
      ..sort((a, b) => (a.$1 + a.$2).compareTo(b.$1 + b.$2));
    final byDiff = [...pts]
      ..sort((a, b) => (a.$1 - a.$2).compareTo(b.$1 - b.$2));
    return [bySum.first, byDiff.last, byDiff.first, bySum.last];
  }

  /// Bilinearly interpolates a fractional page position within the
  /// quadrilateral [quad] ([topLeft, topRight, bottomLeft, bottomRight]).
  (double, double) _bilinearInterpolate(
    List<(double, double)> quad,
    double xFrac,
    double yFrac,
  ) {
    final tl = quad[0], tr = quad[1], bl = quad[2], br = quad[3];
    final topX = tl.$1 + (tr.$1 - tl.$1) * xFrac;
    final topY = tl.$2 + (tr.$2 - tl.$2) * xFrac;
    final bottomX = bl.$1 + (br.$1 - bl.$1) * xFrac;
    final bottomY = bl.$2 + (br.$2 - bl.$2) * xFrac;
    return (topX + (bottomX - topX) * yFrac, topY + (bottomY - topY) * yFrac);
  }

  /// Clamps a candidate rectangle (given as raw left/top/right/bottom,
  /// which may extend past the image bounds) to a valid region within an
  /// image of [width]x[height].
  cv.Rect _clampedRect(
    double left,
    double top,
    double right,
    double bottom,
    int width,
    int height,
  ) {
    final l = left.clamp(0, width - 1).round();
    final t = top.clamp(0, height - 1).round();
    final r = right.clamp(l + 1, width).round();
    final b = bottom.clamp(t + 1, height).round();
    return cv.Rect(l, t, r - l, b - t);
  }

  /// One search setup per corner mark, in [top-left, top-right,
  /// bottom-left, bottom-right] order: a tight [_QuadrantSearch.stage1] box
  /// centered on where *this exam's* own corner marker is actually printed
  /// (`template.cornerMarkers` — inset markers like AT's right edge at
  /// 0.867 or PT's bottom at 0.761 land the box on the real mark, not
  /// generic page-corner margin), the full photo quadrant as the Stage-2
  /// fallback, and the point [_findMarkerInRegion]'s position score is
  /// measured against: bilinearly interpolated from [pageQuad] when
  /// [_detectPageQuad] found a page boundary, or the marker's own page
  /// fraction applied directly to the photo otherwise (correct when the
  /// sheet fills the frame edge-to-edge, so there's no boundary edge to
  /// have detected in the first place).
  ///
  /// [_QuadrantSearch.quadrant] is always the full quadrant regardless of
  /// [stage1] — a miss in the tight box always falls through to it (see
  /// [_refineCorners]), so a wrong or imprecise position estimate only
  /// costs one extra search pass, never a missed mark. Quadrants overlap
  /// slightly past the exact midpoint ([_quadrantOverlapFrac]) so a mark
  /// sitting close to the frame's center — a small or off-center sheet —
  /// still falls inside its own quadrant.
  List<_QuadrantSearch> _quadrantsFor(
    int width,
    int height,
    List<(double, double)>? pageQuad,
    OmrExamTemplate template,
  ) {
    final midX = width / 2;
    final midY = height / 2;
    final overlapX = width * _quadrantOverlapFrac;
    final overlapY = height * _quadrantOverlapFrac;
    final w = width.toDouble();
    final h = height.toDouble();
    final regions = [
      _clampedRect(0, 0, midX + overlapX, midY + overlapY, width, height),
      _clampedRect(midX - overlapX, 0, w, midY + overlapY, width, height),
      _clampedRect(0, midY - overlapY, midX + overlapX, h, width, height),
      _clampedRect(midX - overlapX, midY - overlapY, w, h, width, height),
    ];
    // pageQuad, when present, is already ordered [topLeft, topRight,
    // bottomLeft, bottomRight] by _detectPageQuad — matching quadrant
    // order exactly, so each region pairs with its own corner's estimate.
    // Falls back to that quadrant's literal photo corner when no boundary
    // was detected (correct precisely when the sheet fills the frame
    // edge-to-edge, so there was no boundary edge to detect in the first
    // place).
    const fracs = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)];
    final anchors = [
      for (final (xFrac, yFrac) in fracs)
        pageQuad == null
            ? (xFrac * w, yFrac * h)
            : _bilinearInterpolate(pageQuad, xFrac, yFrac),
    ];

    // Stage-1 box per corner: centered on where THIS exam's own marker is
    // actually printed (template.cornerMarkers), using the same
    // pageQuad-or-direct-fraction position estimate as the anchors above —
    // an inset marker (AT's right edge at 0.867, PT's bottom at 0.761)
    // lands the box on the real mark instead of empty page-corner margin.
    final halfExtent = _stage1HalfExtentFrac * math.min(w, h);
    final stage1s = <cv.Rect>[];
    for (final marker in template.cornerMarkers) {
      final (cx, cy) = pageQuad == null
          ? (marker.xFrac * w, marker.yFrac * h)
          : _bilinearInterpolate(pageQuad, marker.xFrac, marker.yFrac);
      stage1s.add(_clampedRect(
        cx - halfExtent,
        cy - halfExtent,
        cx + halfExtent,
        cy + halfExtent,
        width,
        height,
      ));
    }

    return [
      for (var i = 0; i < 4; i++)
        (
          stage1: stage1s[i],
          quadrant: regions[i],
          anchorX: anchors[i].$1,
          anchorY: anchors[i].$2,
        ),
    ];
  }

  /// Searches [region] for one corner square and scores every candidate
  /// blob by a combination of **shape** (`_squarenessOf` — the printed
  /// marker is a solid filled square, not a hollow/filled circle or a
  /// letter-filled ring), proximity to ([anchorX], [anchorY]) — this
  /// corner's estimated position (see [_quadrantsFor]) — and local
  /// contrast. The winner is whichever candidate maximizes
  /// `0.50*squareness + 0.32*positionScore + 0.18*contrastScore`.
  ///
  /// Never returns null. On no acceptable candidate the result carries
  /// [CornerConfidence.none] and a null centroid; either way it carries the
  /// highest-scoring rejected candidates for the debug overlay so a bad
  /// pick — or a near miss — can be understood.
  ///
  /// [region] is either a tight Stage-1 box around the template-expected
  /// corner or, on a Stage-1 miss, the full photo-quadrant (see
  /// [_refineCorners]); the caller decides which. The search is by what the
  /// mark actually looks like and where it genuinely is, not by whether an
  /// earlier guess was close enough — so a Stage-2 (full-quadrant) find is
  /// still eligible for [CornerConfidence.confident].
  _MarkerSearchResult _findMarkerInRegion(
    cv.Mat gray,
    cv.Rect region,
    double anchorX,
    double anchorY, {
    String? debugTag,
  }) {
    final roi = gray.region(region);
    try {
      // Brightness measured on this corner's own search ROI, not the whole
      // photo — a shadow or silhouette can fall over just one corner while
      // the rest of the sheet is fine, and the other 3 corners' searches
      // shouldn't get a correction they don't need because of it. A no-op
      // at/above _referenceBrightness, same as decode()'s own adaptive
      // scaling.
      final roiMeanScalar = roi.mean();
      double roiBrightness;
      try {
        roiBrightness = roiMeanScalar.val1;
      } finally {
        roiMeanScalar.dispose();
      }
      final clahe = cv.createCLAHE(clipLimit: _adaptiveClipLimit(3, roiBrightness), tileGridSize: (4, 4));
      try {
        final enhanced = clahe.apply(roi);
        try {
          final blurred = cv.gaussianBlur(enhanced, (3, 3), 0);
          try {
            final roiMinDim = math.min(roi.width, roi.height);
            final blockSize = ((roiMinDim ~/ 4) | 1).clamp(11, 51);
            final binary = cv.adaptiveThreshold(
              blurred,
              255,
              cv.ADAPTIVE_THRESH_GAUSSIAN_C,
              cv.THRESH_BINARY_INV,
              blockSize,
              _adaptiveThresholdCFor(8, roiBrightness),
            );
            try {
              // Ordinary photo blur/JPEG softening can still break a
              // printed mark's edges into fragments too small to
              // individually clear the area filter below. A small dilation
              // bridges those fragments back into one solid blob before
              // contour extraction, with little effect on marks that were
              // already solid.
              final dilateKernel = cv.getStructuringElement(cv.MORPH_RECT, (
                3,
                3,
              ));
              try {
                final dilated = cv.dilate(binary, dilateKernel, iterations: 1);
                try {
                  final (contours, hierarchy) = cv.findContours(
                    dilated,
                    cv.RETR_EXTERNAL,
                    cv.CHAIN_APPROX_SIMPLE,
                  );
                  try {
                    // The area cap is relative to the *whole photo*, not
                    // this region — a quadrant can be a large fraction of
                    // the image, but the printed mark itself is always a
                    // small, roughly fixed fraction of the page regardless
                    // of how much of the photo is being searched for it.
                    final imageArea = gray.width * gray.height;

                    final imageAreaCap = imageArea * 0.02;
                    final anchorScale = math.max(
                      1.0,
                      0.25 *
                          math.sqrt(region.width * region.width +
                              region.height * region.height),
                    );

                    // Winner tracked by COMBINED score — higher is better now
                    // (squareness-led), not the old "closest wins".
                    double bestScore = -1;
                    double bestSquareness = 0;
                    double bestContrast = 0;
                    double bestDistance = double.infinity;
                    cv.Rect? bestRect;
                    var bestContourIndex = -1;
                    final rejected = <_RejectedCandidate>[];
                    void reject(cv.Rect r, double sq, double sc, String why) {
                      rejected.add(_RejectedCandidate(
                        cv.Rect(region.x + r.x, region.y + r.y, r.width, r.height),
                        sq,
                        sc,
                        why,
                      ));
                    }

                    for (var ci = 0; ci < contours.length; ci++) {
                      final contour = contours[ci];
                      final area = cv.contourArea(contour);
                      final rect = cv.boundingRect(contour);
                      final boxArea = (rect.width * rect.height).toDouble();
                      final longSide = math.max(rect.width, rect.height);
                      final shortSide =
                          math.max(1, math.min(rect.width, rect.height));
                      final aspect = longSide / shortSide;
                      final extent = boxArea > 0 ? area / boxArea : 0.0;

                      void log(String s) {
                        if (_kFiducialDebug && debugTag != null) {
                          _fidLog('q=$debugTag c#$ci '
                              'bbox=(${rect.x},${rect.y},${rect.width},${rect.height}) '
                              'area=${area.toStringAsFixed(0)} $s');
                        }
                      }

                      // ---- cheap early rejects (bound cost before the
                      // heavier shape metrics) ----
                      if (area < 8 || area > imageAreaCap) {
                        log('REJECT area (need 8..${imageAreaCap.toStringAsFixed(0)})');
                        continue;
                      }
                      if (boxArea <= 0 || extent < _markerMinFillRatio) {
                        reject(rect, 0, 0, 'fill_ratio');
                        log('REJECT fill_ratio (extent=${extent.toStringAsFixed(3)}<$_markerMinFillRatio)');
                        continue;
                      }
                      if (aspect > _markerMaxAspect) {
                        reject(rect, 0, 0, 'aspect');
                        log('REJECT aspect (${aspect.toStringAsFixed(2)}>$_markerMaxAspect)');
                        continue;
                      }

                      final perimeter = cv.arcLength(contour, true);
                      final circularity = perimeter > 0
                          ? 4 * math.pi * area / (perimeter * perimeter)
                          : 0.0;

                      // ---- shape metrics (rotation-invariant) ----
                      var approxVerts = -1;
                      var rectangularity = 0.0;
                      var inkDensity = 0.0;
                      var solidity = 0.0;
                      try {
                        final ap =
                            cv.approxPolyDP(contour, 0.04 * perimeter, true);
                        try {
                          approxVerts = ap.length;
                        } finally {
                          ap.dispose();
                        }
                      } catch (_) {}
                      try {
                        final mar = cv.minAreaRect(contour);
                        try {
                          final marArea = mar.size.width * mar.size.height;
                          if (marArea > 0) rectangularity = area / marArea;
                        } finally {
                          mar.dispose();
                        }
                      } catch (_) {}
                      try {
                        final hullMat = cv.convexHull(contour);
                        try {
                          final hullVp = cv.VecPoint.fromMat(hullMat);
                          try {
                            final hullArea = cv.contourArea(hullVp);
                            if (hullArea > 0) solidity = area / hullArea;
                          } finally {
                            hullVp.dispose();
                          }
                        } finally {
                          hullMat.dispose();
                        }
                      } catch (_) {}
                      try {
                        final m = cv.Mat.zeros(
                          rect.height,
                          rect.width,
                          cv.MatType.CV_8UC1,
                        );
                        try {
                          cv.drawContours(
                            m,
                            contours,
                            ci,
                            cv.Scalar.all(255),
                            thickness: -1,
                            offset: cv.Point(-rect.x, -rect.y),
                          );
                          final srcSlice = dilated.region(rect);
                          try {
                            final anded = cv.bitwiseAND(srcSlice, m);
                            try {
                              final maskPx = cv.countNonZero(m).toDouble();
                              final inkPx = cv.countNonZero(anded).toDouble();
                              if (maskPx > 0) inkDensity = inkPx / maskPx;
                            } finally {
                              anded.dispose();
                            }
                          } finally {
                            srcSlice.dispose();
                          }
                        } finally {
                          m.dispose();
                        }
                      } catch (_) {}

                      final squareness = _squarenessOf(
                        rectangularity: rectangularity,
                        approxVerts: approxVerts,
                        inkDensity: inkDensity,
                        solidity: solidity,
                        circularity: circularity,
                        aspect: aspect,
                        extent: extent,
                      );

                      final globalCx = region.x + rect.x + rect.width / 2;
                      final globalCy = region.y + rect.y + rect.height / 2;
                      final distance = math.sqrt(
                        math.pow(globalCx - anchorX, 2) +
                            math.pow(globalCy - anchorY, 2),
                      );

                      // Local contrast against this blob's own neighborhood
                      // (unchanged measurement).
                      final localPad = math.max(rect.width, rect.height) * 2;
                      final localRegion = _clampedRect(
                        (rect.x - localPad).toDouble(),
                        (rect.y - localPad).toDouble(),
                        (rect.x + rect.width + localPad).toDouble(),
                        (rect.y + rect.height + localPad).toDouble(),
                        roi.width,
                        roi.height,
                      );
                      final blobRoi = roi.region(rect);
                      final localRoi = roi.region(localRegion);
                      double contrast;
                      try {
                        final blobMean = blobRoi.mean();
                        try {
                          final localMean = localRoi.mean();
                          try {
                            contrast = localMean.val1 - blobMean.val1;
                          } finally {
                            localMean.dispose();
                          }
                        } finally {
                          blobMean.dispose();
                        }
                      } finally {
                        blobRoi.dispose();
                        localRoi.dispose();
                      }

                      final positionScore = math.exp(-distance / anchorScale);
                      final contrastScore = _clamp01(
                          (contrast - _markerMinContrast) /
                              (90 - _markerMinContrast));
                      final candScore = 0.50 * squareness +
                          0.32 * positionScore +
                          0.18 * contrastScore;

                      log('extent=${extent.toStringAsFixed(3)} aspect=${aspect.toStringAsFixed(2)} '
                          'circ=${circularity.toStringAsFixed(3)} rect=${rectangularity.toStringAsFixed(3)} '
                          'ink=${inkDensity.toStringAsFixed(3)} solid=${solidity.toStringAsFixed(3)} '
                          'verts=$approxVerts sq=${squareness.toStringAsFixed(3)} '
                          'contrast=${contrast.toStringAsFixed(1)} dist=${distance.toStringAsFixed(1)} '
                          'pos=${positionScore.toStringAsFixed(3)} score=${candScore.toStringAsFixed(3)}');

                      if (contrast < _markerMinContrast) {
                        reject(rect, squareness, candScore, 'contrast');
                        continue;
                      }
                      if (squareness < _markerMinSquarenessLow) {
                        reject(rect, squareness, candScore, 'low_squareness');
                        continue;
                      }
                      if (candScore > bestScore) {
                        if (bestRect != null) {
                          reject(bestRect, bestSquareness, bestScore, 'outscored');
                        }
                        bestScore = candScore;
                        bestSquareness = squareness;
                        bestContrast = contrast;
                        bestDistance = distance;
                        bestRect = rect;
                        bestContourIndex = ci;
                      } else {
                        reject(rect, squareness, candScore, 'outscored');
                      }
                    }

                    rejected.sort((a, b) => b.squareness.compareTo(a.squareness));
                    final topRejects = rejected.take(5).toList();

                    if (bestRect == null) {
                      return _MarkerSearchResult(
                        centroid: null,
                        bboxGlobal: null,
                        confidence: CornerConfidence.none,
                        squareness: 0,
                        contrast: 0,
                        anchorDistance: double.infinity,
                        rejected: topRejects,
                      );
                    }

                    // The blob's true (area-weighted) centroid — a
                    // bounding-box midpoint drifts on an asymmetrically
                    // distorted blob and skews the whole homography.
                    final rect = bestRect;
                    final bboxGlobal = cv.Rect(
                      region.x + rect.x,
                      region.y + rect.y,
                      rect.width,
                      rect.height,
                    );
                    final mask = cv.Mat.zeros(
                        rect.height, rect.width, cv.MatType.CV_8UC1);
                    late cv.Point2f centroid;
                    try {
                      cv.drawContours(
                        mask,
                        contours,
                        bestContourIndex,
                        cv.Scalar.all(255),
                        thickness: -1,
                        offset: cv.Point(-rect.x, -rect.y),
                      );
                      final mm = cv.moments(mask);
                      try {
                        final cx = mm.m00 > 0
                            ? region.x + rect.x + mm.m10 / mm.m00
                            : region.x + rect.x + rect.width / 2;
                        final cy = mm.m00 > 0
                            ? region.y + rect.y + mm.m01 / mm.m00
                            : region.y + rect.y + rect.height / 2;
                        centroid = cv.Point2f(cx.toDouble(), cy.toDouble());
                      } finally {
                        mm.dispose();
                      }
                    } finally {
                      mask.dispose();
                    }

                    final posScoreBest = math.exp(-bestDistance / anchorScale);
                    final tier = (bestSquareness >=
                                _markerMinSquarenessConfident &&
                            bestContrast >= _markerMinContrast &&
                            posScoreBest >= 0.36787944)
                        ? CornerConfidence.confident
                        : CornerConfidence.low;
                    if (_kFiducialDebug && debugTag != null) {
                      _fidLog('q=$debugTag WINNER c#$bestContourIndex '
                          'sq=${bestSquareness.toStringAsFixed(3)} '
                          'contrast=${bestContrast.toStringAsFixed(1)} '
                          'dist=${bestDistance.toStringAsFixed(1)} tier=${tier.name}');
                    }

                    return _MarkerSearchResult(
                      centroid: centroid,
                      bboxGlobal: bboxGlobal,
                      confidence: tier,
                      squareness: bestSquareness,
                      contrast: bestContrast,
                      anchorDistance: bestDistance,
                      rejected: topRejects,
                    );
                  } finally {
                    contours.dispose();
                    hierarchy.dispose();
                  }
                } finally {
                  dilated.dispose();
                }
              } finally {
                dilateKernel.dispose();
              }
            } finally {
              binary.dispose();
            }
          } finally {
            blurred.dispose();
          }
        } finally {
          enhanced.dispose();
        }
      } finally {
        clahe.dispose();
      }
    } finally {
      roi.dispose();
    }
  }

  /// Reads every item's fill fractions and decides blank/marked/ambiguous
  /// primarily by comparing bubbles *within the same item* against each
  /// other, not against a single fixed constant.
  ///
  /// The earlier design compared every bubble on the sheet against one
  /// global floor and margin. That's fragile to exactly the kind of thing
  /// a real photo actually has: uneven or dim lighting across the page
  /// (confirmed against real scans, not assumed) shifts every bubble's
  /// fill reading together, so a global floor either lets a whole
  /// lighting-dim sheet's blank bubbles cross it, or a global margin
  /// shrinks below its threshold for a genuinely marked bubble sitting
  /// next to a blank one whose reading got pushed up by the same shift.
  /// Two bubbles printed on the same row of the same photo were captured
  /// under essentially identical local lighting, so comparing a bubble
  /// against its own row's other bubbles cancels that shift out instead
  /// of being fooled by it — a real mark still has to look darker than
  /// its neighbors, but "darker than its neighbors" no longer depends on
  /// matching one fixed brightness assumed to hold for every photo.
  ///
  /// Works down to 2 choices (e.g. True/False) too: the "floor reference"
  /// is just the single runner-up in that case, which is exactly what
  /// [_ambiguousMargin] already compares against below — a 2-choice item
  /// can't tell a genuine blank apart from a genuine double-mark any more
  /// than a fully-marked-every-choice item can for 3+ choices (both read
  /// as blank instead of ambiguous), but that's an existing, accepted
  /// trade-off, not a new one. Confirmed against a real blank TAT scan
  /// that the alternative — a fixed absolute floor for 2-choice items,
  /// the original design — actively breaks blank detection: T/F bubbles'
  /// printed oval outline plus the "T"/"F" glyph itself put every blank
  /// item's fill around 0.43-0.57 (comfortably over any reasonable fixed
  /// floor) with the two choices reading almost identically, so every
  /// single blank 2-choice item was flagged ambiguous rather than blank.
  /// 3+-choice items never exposed this because [_blankFillFloor] was
  /// already doing basically no work there — [_markPresenceGap] was
  /// always the real gate — but a 2-choice item has no third bubble to
  /// build that same-row reference from without this change.
  OmrScanResult _readBubbles(
    cv.Mat inkMap,
    OmrExamTemplate template,
    int canonicalWidth,
    int canonicalHeight,
  ) {
    // Sample the full printed bubble (its radii, converted to canonical
    // pixels), not a size guessed independently of what's actually on the
    // page — otherwise enlarging bubbles in the sheet generator without a
    // matching decoder change just keeps sampling the same small patch in
    // the middle, which is where the printed choice letter lives. X and Y
    // are sampled independently since QTM/TAT's bubbles print flattened
    // (see _bubbleFillFraction's doc comment) — using the same radius for
    // both, as an earlier version did, systematically diluted a genuinely
    // marked oval bubble's measured fill.
    final bubbleSampleHalfPxX = template.bubbleRadiusPt * _canonicalPxPerPt;
    final bubbleSampleHalfPxY = template.bubbleRadiusYPt * _canonicalPxPerPt;
    final ambiguousMargin = _ambiguousMarginFor(template.examCode);
    final items = <OmrItemResult>[];
    for (final section in template.sections) {
      for (final itemNumber in section.items.keys.toList()..sort()) {
        final choices = section.items[itemNumber]!;
        final fills = [
          for (final bubble in choices)
            (
              bubble.choice,
              _bubbleFillFraction(
                inkMap,
                bubble,
                bubbleSampleHalfPxX,
                bubbleSampleHalfPxY,
                canonicalWidth,
                canonicalHeight,
              ),
            ),
        ]..sort((a, b) => b.$2.compareTo(a.$2)); // descending by fill

        final bestChoice = fills[0].$1;
        final bestFill = fills[0].$2;
        final runnerUpFill = fills[1].$2; // every item has >=2 choices

        // The lowest-filled *other* bubble in this item — a robust,
        // same-row "what does blank ink look like right here" reference
        // that stays reliable even if the single runner-up happens to
        // be a noisy outlier (still safely blank, just not the
        // clearest example of it). For a 2-choice item this is just the
        // one runner-up.
        final floorReference = fills
            .sublist(1)
            .map((e) => e.$2)
            .reduce(math.min);
        final hasSomething =
            bestFill >= _blankFillFloor &&
            (bestFill - floorReference) >= _markPresenceGap;

        if (!hasSomething) {
          items.add(
            OmrItemResult(
              sectionName: section.name,
              itemNumber: itemNumber,
              markedChoice: null,
            ),
          );
        } else if (bestFill - runnerUpFill < ambiguousMargin) {
          // Unchanged regardless of choice count: best and runner-up are
          // too close to call, whether that's a genuine double-mark or a
          // single mark with an unusually dark neighbor — either way it
          // shouldn't be silently guessed.
          items.add(
            OmrItemResult(
              sectionName: section.name,
              itemNumber: itemNumber,
              markedChoice: null,
              isAmbiguous: true,
            ),
          );
        } else {
          items.add(
            OmrItemResult(
              sectionName: section.name,
              itemNumber: itemNumber,
              markedChoice: bestChoice,
            ),
          );
        }
      }
    }
    return OmrScanResult(examCode: template.examCode, items: items);
  }

  /// Fraction (0-1) of the bubble's ring-shaped sample ROI that is "ink" on
  /// the binarized [inkMap] (255 = ink, after THRESH_BINARY_INV). Samples
  /// the outer bubble area minus a central zone where the printed choice
  /// letter lives, so blank sheets aren't misread as ambiguous marks.
  ///
  /// The sample rectangle's half-width/half-height are taken from
  /// [template]'s bubbleRadiusPt/bubbleRadiusYPt independently rather than
  /// assuming a single radius for both — QTM/TAT's bubbles print as
  /// flattened ovals (see generate_sheets.dart's bubbleRadiusYFor), and
  /// sampling a square sized to the horizontal radius in both directions
  /// pulls in a band of blank paper above/below the actual printed oval.
  /// Confirmed against a real scan: that diluted a fully, densely marked
  /// oval bubble's measured fill from ~0.9 down to ~0.4 — on its own
  /// enough for ordinary threshold noise on a neighboring blank bubble to
  /// push a genuine mark into reading as ambiguous.
  double _bubbleFillFraction(
    cv.Mat inkMap,
    BubblePos bubble,
    double halfPxX,
    double halfPxY,
    int canonicalWidth,
    int canonicalHeight,
  ) {
    final cx = bubble.xFrac * canonicalWidth;
    final cy = bubble.yFrac * canonicalHeight;
    final outerFill = _squareFillFraction(
      inkMap,
      cx,
      cy,
      halfPxX,
      halfPxY,
      canonicalWidth,
      canonicalHeight,
    );
    final innerHalfPxX = halfPxX * _bubbleInnerSampleFrac;
    final innerHalfPxY = halfPxY * _bubbleInnerSampleFrac;
    final innerFill = _squareFillFraction(
      inkMap,
      cx,
      cy,
      innerHalfPxX,
      innerHalfPxY,
      canonicalWidth,
      canonicalHeight,
    );

    final outerArea = halfPxX * halfPxY * 4;
    final innerArea = innerHalfPxX * innerHalfPxY * 4;
    final ringArea = outerArea - innerArea;
    if (ringArea <= 0) return outerFill;

    return ((outerFill * outerArea) - (innerFill * innerArea)) / ringArea;
  }

  double _squareFillFraction(
    cv.Mat inkMap,
    double cx,
    double cy,
    double halfPxX,
    double halfPxY,
    int canonicalWidth,
    int canonicalHeight,
  ) {
    final left = (cx - halfPxX).clamp(0, canonicalWidth - 1).round();
    final top = (cy - halfPxY).clamp(0, canonicalHeight - 1).round();
    final right = (cx + halfPxX).clamp(left + 1, canonicalWidth).round();
    final bottom = (cy + halfPxY).clamp(top + 1, canonicalHeight).round();

    final roi = inkMap.region(cv.Rect(left, top, right - left, bottom - top));
    try {
      final mean = roi.mean();
      try {
        return mean.val1 / 255.0;
      } finally {
        mean.dispose();
      }
    } finally {
      roi.dispose();
    }
  }
}
