import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/omr_scan_result.dart';
import 'fiducial_search_tuning.dart';
import 'omr_alignment_check.dart';
import 'omr_mesh_correction.dart';
import 'omr_bubble_classifier.dart';
import 'omr_templates.dart';
import 'tat_marker_validation.dart';

/// Template-centered search box, fallback quadrant, and scoring anchor.
typedef _QuadrantSearch = ({
  cv.Rect stage1,
  cv.Rect quadrant,
  double anchorX,
  double anchorY,
  // Fixed-tolerance position-scoring scale for the Stage-1 search only —
  // see [kFiducialAnchorToleranceFrac]'s doc comment for why this must
  // stay independent of `stage1`'s (enlarged) box size.
  double stage1AnchorScale,
});

/// Ranked outcome of measuring every choice in one OMR item at a given
/// (possibly zero) sampling shift -- see [OmrDecoder._measureItemAt].
typedef _ItemMeasurement = ({
  List<(String, ({double ringFill, double wholeFill, double centerFill, double score}))>
      measurements,
  String bestChoice,
  double bestFill,
  double runnerUpFill,
  double floorReference,
});

/// Rejected marker candidate retained for the debug overlay.
class _RejectedCandidate {
  /// Bounding box in full-image coordinates.
  final cv.Rect bboxGlobal;
  final double squareness;
  final double score;
  final double area;
  final double contrast;

  /// `area` | `aspect` | `fill_ratio` | `contrast` | `low_squareness` |
  /// `inside_grid` | `geom_inconsistent` | `outscored`.
  final String reason;

  const _RejectedCandidate(
    this.bboxGlobal,
    this.squareness,
    this.score,
    this.reason, {
    this.area = 0,
    this.contrast = 0,
  });
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
  final double positionScore;
  final List<_RejectedCandidate> rejected;

  const _MarkerSearchResult({
    required this.centroid,
    required this.bboxGlobal,
    required this.confidence,
    required this.squareness,
    required this.contrast,
    required this.anchorDistance,
    this.positionScore = 0,
    required this.rejected,
  });

}

/// Refined fiducial corners, confidence, and debug geometry (TL, TR, BL, BR).
class _RefineResult {
  /// TL, TR, BL, BR — CV centroids of the real printed squares (a rescued
  /// corner is still a detected blob, just lower confidence).
  final List<cv.Point2f> corners;
  final List<CornerConfidence> confidence;
  final AlignmentVerdict verdict;

  /// TL, TR, BL, BR — the Stage-1 search boxes, for the debug overlay.
  final List<cv.Rect> stage1Regions;

  /// Expected marker anchors (TL, TR, BL, BR), mapped into the detected page.
  /// Unlike search boxes, these points are not clamped to image edges.
  final List<(double, double)> anchors;

  /// TL, TR, BL, BR — rejected candidates per corner, for the debug overlay.
  final List<List<_RejectedCandidate>> rejectedPerCorner;

  /// A one-line "corner X recovered from geometry" note, or null.
  final String? note;

  const _RefineResult({
    required this.corners,
    required this.confidence,
    required this.verdict,
    required this.stage1Regions,
    required this.anchors,
    required this.rejectedPerCorner,
    required this.note,
  });
}

/// Independent post-warp marker detections in TL, TR, BL, BR order.
/// Reprojecting the four fitted source points cannot validate an exact fit.
class _WarpVerification {
  /// Expected canonical position per corner (`template.cornerMarkers[i]`
  /// scaled into the warped image's own pixel space).
  final List<cv.Point2f> expected;

  /// Freshly re-detected centroid per corner, or null if nothing in the
  /// search box cleared even [OmrDecoder._markerMinSquarenessLow].
  final List<cv.Point2f?> redetected;

  /// Canonical-px distance from [redetected] to [expected] per corner;
  /// `double.infinity` where nothing was found.
  final List<double> errorPx;
  final List<CornerConfidence> confidence;

  const _WarpVerification({
    required this.expected,
    required this.redetected,
    required this.errorPx,
    required this.confidence,
  });
}

/// Native OpenCV decoder: locate fiducials, rectify the sheet, normalize lighting,
/// and classify bubble marks. Selected by the dart:io conditional export.
class OmrDecoder {
  const OmrDecoder();

  /// Quadrant overlap allows markers near the center of an off-center sheet.
  static const double _quadrantOverlapFrac = 0.12;

  /// Canonical pixels per PDF point when warping the sheet flat. Bubble
  /// sampling geometry below is tuned against this scale.
  static const double _canonicalPxPerPt = 2.0;

  /// Higher-resolution warp for handwritten name OCR in [cropNameFields].
  /// Keep separate from the scale used to tune bubble scoring.
  static const double _ocrCanonicalPxPerPt = 6.0;

  /// Per-exam contrast correction: QTM needs less to avoid amplifying noise;
  /// other exams retain stronger correction for uneven lighting.
  static double _claheClipLimitFor(String examCode) => switch (examCode) {
    'QTM' => 1.2,
    // TAT's dense landscape layout packs 120 small oval T/F bubbles across
    // many narrow columns — its bubble-to-bubble spacing is the tightest of
    // any exam, so CLAHE noise amplification on blank paper between bubbles
    // bleeds into neighboring fill readings more than on QTM/AT.  A clip
    // limit between QTM's conservative 1.2 and the default 2.0 restores
    // shadow/LED contrast without the speckle that inflates false positives.
    'TAT' => 1.5,
    _ => 2.0,
  };

  /// Odd threshold window spanning several bubbles to follow lighting gradients.
  /// Per-exam: TAT's tighter bubble spacing means a 45-px window averages
  /// across too many bubbles, diluting the local mean and making faint marks
  /// harder to distinguish from blank paper.  A smaller window (31) tracks
  /// the narrower columns more faithfully without being so small that it
  /// loses the lighting-gradient-following property.
  static int _adaptiveThresholdBlockSizeFor(String examCode) => switch (examCode) {
    'TAT' => 31,
    _ => 45,
  };

  /// Constant subtracted from the local adaptive-threshold mean; higher
  /// values require darker pixels to count as "ink".
  static const double _adaptiveThresholdC = 12;

  /// Brightness at which low-light adjustments become a no-op (0–255).
  /// Darker inputs receive proportional correction; needs real low-light calibration.
  static const double _referenceBrightness = 170.0;

  /// Brightness drop at which correction saturates; needs low-light calibration.
  static const double _maxDarknessRange = 100.0;

  /// Clamped darkness factor: 0 at reference brightness, 1 at maximum drop.
  static double _darknessFactor(double meanBrightness) =>
      ((_referenceBrightness - meanBrightness) / _maxDarknessRange).clamp(0.0, 1.0);

  /// Washout factor: 0 at reference brightness, 1 at near-saturation (250).
  /// Captures the opposite problem from darkness — an overexposed image from
  /// a low-end camera's aggressive auto-exposure, where pencil marks are
  /// compressed to within a few gray levels of white paper.
  static double _washoutFactor(double meanBrightness) =>
      ((meanBrightness - _referenceBrightness) / 80.0).clamp(0.0, 1.0);

  /// Increase contrast correction for both dark AND washed-out inputs.
  /// Dark inputs: up to 2× base (unchanged from before).
  /// Washed-out inputs: up to 1.5× base — a gentler boost because the image
  /// already has high mean brightness and aggressive CLAHE on bright images
  /// risks amplifying JPEG artifacts more than on dark ones.
  static double _adaptiveClipLimit(double base, double meanBrightness) =>
      base * (1 + _darknessFactor(meanBrightness) + _washoutFactor(meanBrightness) * 0.5);

  /// Reduce the ink threshold offset up to 50% for dark inputs.
  static double _adaptiveThresholdCFor(double base, double meanBrightness) =>
      base * (1 - _darknessFactor(meanBrightness) * 0.5);

  /// Downscale factor for inexpensive, broad background-illumination estimation.
  static const int _illumDownscaleDiv = 8;

  /// Target paper-brightness band after background division, preserving faint ink.
  /// Min lowered from 170 → 150: on washed-out low-end camera captures (auto-
  /// exposure pushes paper to near-255), the background mean is very high, and
  /// clamping the division target to 170 keeps the result too bright — faint
  /// pencil marks end up only a few gray levels below paper, well within CLAHE
  /// noise.  A target of 150 pulls the normalized page further from saturation,
  /// giving CLAHE and adaptive thresholding more dynamic range to separate
  /// genuinely marked bubbles from blank paper.
  static const double _illumTargetLevelMin = 150;
  static const double _illumTargetLevelMax = 230;

  /// Normalize broad lighting variations before CLAHE and thresholding by dividing
  /// by a downscaled, blurred background estimate.
  /// Returns [gray] unchanged on failure or implausible output. The caller owns
  /// a new result only; all other allocations are disposed here.
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
      // large page can't make this needlessly slow. Floor raised from 11 to
      // 21 so that high-frequency LED panel banding (narrow bright/dark
      // stripes across the page from PWM flicker or rolling-shutter
      // interaction) gets averaged out rather than surviving into the
      // background estimate — a visible stripe in `background` divides out
      // as a complementary stripe in the result, producing a false lighting
      // gradient that wasn't in the original capture.
      final k = ((math.min(downW, downH) ~/ 3) | 1).clamp(21, 151);
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
      //
      // Upper bound relaxed from 250 → 253: under strong LED panel lighting
      // (multiple ceiling LEDs in a defense/conference room) the paper is
      // almost saturated white in the capture, which pushes the normalized
      // mean into 245-252. Rejecting those and falling back to the raw warp
      // loses the gradient correction that _normalizeIllumination provides,
      // exactly when it's needed most. A mean above 253 still indicates a
      // degenerate division (everything near 255) where thresholding will
      // fail regardless.
      if (rMean < 30 || rMean > 253 || rStd < 3) {
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

  /// Minimum ink signal. Mark presence primarily uses same-row bubble differences
  /// so changes in overall lighting do not shift every item across a fixed floor.
  /// Per-exam: TAT's small oval bubbles on washed-out low-end camera captures
  /// (auto-exposure blows out pencil-vs-paper contrast) can score below the
  /// standard 0.15 even when genuinely marked — lowered to 0.10 so faint marks
  /// at least reach the presence/ambiguity checks instead of being silently
  /// dismissed as blank.  Risk of false positives on dirty paper is mitigated
  /// by the _markPresenceGap check that still requires the best bubble to
  /// stand out from its row's floor.
  static double _blankFillFloorFor(String examCode) => switch (examCode) {
    'TAT' => 0.10,
    _ => 0.15,
  };

  /// Minimum best-to-runner-up gap for an unambiguous mark.
  /// AT/QTM use 0.10 for lighter, ring-shaped marks observed in real scans.
  static double _ambiguousMarginFor(String examCode) => switch (examCode) {
    'AT' || 'QTM' => 0.10,
    // TAT's True/False items have only 2 choices per row — the runner-up is
    // the *only* other bubble, so the absolute best-to-runner-up margin is
    // structurally lower than on 4-5 choice exams where runner-up is a
    // randomly blank neighbor.  A 0.15 flat cutoff flags too many genuinely
    // single-marked T/F items as ambiguous; 0.08 matches the reduced
    // headroom while still catching real double-marks.
    'TAT' => 0.08,
    _ => 0.15,
  };

  /// Minimum best-to-lowest bubble gap for mark presence, including two-choice items.
  /// Lower than the ambiguity margin so faint marks can reach review.
  /// Per-exam: TAT on washed-out captures (low-end camera auto-exposure) can
  /// compress the entire fill range into a narrow band where even a genuinely
  /// marked bubble barely exceeds its row's blank floor by 0.04-0.06.  A gap
  /// of 0.05 lets those faint-but-real marks reach the ambiguity/margin checks
  /// instead of being dismissed as blank.
  static double _markPresenceGapFor(String examCode) => switch (examCode) {
    'TAT' => 0.05,
    _ => 0.08,
  };

  /// A best-to-runner-up gap at least this fraction of the item's own
  /// presence gap (best-to-floor) counts as decisive even when it falls
  /// short of [_ambiguousMarginFor]'s flat cutoff. Rescues genuinely
  /// single, dominant marks that would otherwise be flagged ambiguous only
  /// because the absolute margin required doesn't scale with how strongly
  /// an item's ink separates from its own local blank baseline -- confirmed
  /// against real on-device captures (2026-09-13) where a clearly-marked
  /// TAT item (margin 0.131 against a required 0.15) was one of many
  /// flagged ambiguous despite a visually unambiguous, single dark bubble.
  static const double _ambiguousRelativeMarginFloor = 0.55;

  /// Presence gap must clear this multiple of [_markPresenceGapFor] before the
  /// relative-margin rescue above applies -- keeps genuinely faint marks
  /// (gap barely over the floor, so its ratio to the gap is unreliable)
  /// routed to ambiguous review as originally intended, rather than being
  /// waved through just because they happen to dominate a razor-thin signal.
  static const double _strongPresenceGapMultiplier = 1.5;

  /// Below this gap between the runner-up and the item's own blank floor,
  /// the "runner-up" isn't a real second choice -- it's indistinguishable
  /// from the other genuinely-blank bubbles in the same item. Rescues a
  /// faint-but-uncontested mark that [_strongPresenceGapMultiplier] alone
  /// would still flag ambiguous: that check asks "is the *winning* mark's
  /// own ink strong enough to trust its ratio," which a light mark can fail
  /// even with zero real competition (confirmed against a real AT capture,
  /// 2026-09-15, where a faint but singly-marked item read
  /// bestFill=0.10/runnerUp=0.02/floorReference=0.015 -- comfortably
  /// uncontested, but presenceGap 0.085 fell under the 0.12 bar). This is a
  /// second, independent path to the same "decisive" verdict, asking about
  /// the *other* choices instead: do any of them look like a real
  /// contender at all, regardless of how faint the winner itself is.
  ///
  /// Expressed as a fraction of the item's own per-exam presence gap
  /// ([_markPresenceGapFor]) rather than a flat number, so that TAT's
  /// deliberately compressed thresholds scale this ceiling down with them --
  /// on a sheet where a *real* mark only has to clear its floor by 0.05, a
  /// runner-up sitting 0.04 above that floor is a genuine contender, not
  /// blank paper.
  static const double _noCompetitorGapFraction = 0.5;

  /// Small local re-centering search tried only for items the flat/relative
  /// checks above still call blank or ambiguous. A single page-wide
  /// perspective correction can leave individual rows slightly
  /// mis-registered when the physical sheet isn't perfectly flat -- on a
  /// real capture (2026-09-13) this measurably shifted an entire row's
  /// sample boxes enough that a neighboring, unmarked bubble outscored the
  /// actually-shaded one (e.g. true mark B measured 0.263 while unmarked C
  /// measured 0.289). Each candidate re-measures every choice in the item
  /// shifted by the same (dx, dy) -- modeling a local row-level drift, not
  /// a per-bubble one -- and only replaces the baseline if it produces a
  /// larger best-to-runner-up margin, so this can only rescue an
  /// already-uncertain item, never destabilize a confident one. Fractions
  /// are of the bubble's own outer sampling half-width/height, kept well
  /// under half the template's own bubble-to-bubble spacing.
  static const List<double> _itemRecenterShiftFracs = [-0.35, -0.15, 0.0, 0.15, 0.35];

  /// Wider recenter search grid used whenever mesh correction isn't in effect
  /// (`!mesh.isActive`) — either the template prints no interior fiducials, or
  /// it does but the mesh was rejected on this capture. Without the
  /// triangulated mesh, the single global homography can leave center-of-page
  /// bubbles off by more than the standard ±0.35 half-width — especially on
  /// TAT's landscape layout where the sheet's longer horizontal span amplifies
  /// any paper curl. The wider ±0.55 grid roughly doubles the candidates
  /// (7×7 vs 5×5) but covers drift the narrower grid simply cannot reach, and
  /// only ever runs for items already judged blank or ambiguous.
  static const List<double> _itemRecenterShiftFracsWide = [-0.55, -0.35, -0.15, 0.0, 0.15, 0.35, 0.55];

  /// A fiducial blob must be at least this many gray levels darker than the
  /// local background to count as a real mark (not a shadow edge). Still a
  /// hard gate; also feeds `contrastScore` in the combined candidate score.
  static const double _markerMinContrast = 20;

  /// Loose contour-to-box fill floor tolerates perspective-distorted squares.
  /// Squareness metrics provide the stronger shape discrimination.
  static const double _markerMinFillRatio = 0.18;

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
  /// Stage-2 search — this is a prior, never a boundary. Shared with the
  /// live viewfinder's on-screen box sizing (`fiducial_search_tuning.dart`)
  /// so the two can never drift apart — tune there, not here.
  static const double _stage1HalfExtentFrac = kFiducialSearchHalfExtentFrac;

  /// Padding added around the answer-grid bounding box (fraction of page)
  /// when testing whether a candidate maps *inside* the grid — a strong
  /// signal it's a shaded bubble, not a corner square. Capped low: PT
  /// prints its bottom markers only ~0.04 page-height below the grid, so a
  /// larger pad would swallow them.
  static const double _gridBboxPadFrac = 0.02;

  /// Allowed page-fraction error from the other three corners' affine prediction.
  /// Loose enough for perspective tilt; grid exclusion and post-warp checks
  /// provide stricter validation.
  static const double _affineToleranceFrac = 0.30;

  /// Half-extent (canonical px) of the search box used to re-detect each
  /// fiducial on the warped image, centered on its expected canonical
  /// position. Derived from the sheet's own print geometry: a printed
  /// marker is 12pt wide (24 canonical px at [_canonicalPxPerPt]=2.0), and
  /// sits 20pt (40 canonical px) from where bubble-grid content begins —
  /// this box stays inside that gap (8px buffer) while still comfortably
  /// covering real reprojection drift.
  static const double _postWarpSearchHalfExtentPx = 32.0;

  /// Cap on the long side (px) of the frame [checkCornersFromLuma] actually
  /// searches. `startImageStream` delivers frames at the same resolution
  /// the [CameraController] is configured with for capture (there is no
  /// separate, smaller analysis stream) — confirmed on a real device that
  /// searching a frame at that size took 1-2+ SECONDS per live check (see
  /// the `[OMR PERF] liveFrame=` timing), not the fraction of a second this
  /// advisory-only live guide was designed around. At that real cadence,
  /// ordinary hand tremor between checks routinely exceeds the auto-capture
  /// movement threshold (tuned assuming a much faster ~600ms cadence), so
  /// "stable" could go effectively unreachable — all 4 corners genuinely
  /// locked, auto-capture still never firing. Live detection only needs to
  /// be good enough to color a viewfinder and track rough motion — the
  /// post-capture pass (`locateCorners`/`decode`) always re-searches the
  /// real full-resolution photo independently regardless — so downscaling
  /// this one advisory pass trades precision nobody needs here for the
  /// responsiveness the feature actually depends on.
  ///
  /// TEMPORARY test value — 640 measured consistently fast (~150-300ms,
  /// confirmed on a real device) but manual capture no longer depends on
  /// this signal at all now, so there's room to trade some of that speed
  /// back for resolution if it helps the small printed squares resolve
  /// more reliably in the live guide. Testing 800 against
  /// `[OMR PERF] liveFrame=` before considering 960 — see the capture-
  /// architecture change this accompanied.
  static const int _liveCheckMaxDimension = 800;

  /// Post-warp reprojection error (canonical px) above which a corner is
  /// flagged but still accepted (yellow) — roughly a marker's own
  /// half-width, i.e. the expected noise floor of a clean warp + re-detect.
  static const double _warpWarnPx = 10.0;

  /// Post-warp reprojection error (canonical px) above which the warp is
  /// rejected outright (red) — roughly one full marker width: a shift this
  /// large means the marker isn't where the template says it must be.
  static const double _warpRejectPx = 20.0;

  /// TEMPORARY diagnostic switch for fiducial-marker selection. When true,
  /// [_refineCorners] and [_findMarkerInRegion] print `[OMR FIDUCIAL DEBUG]`
  /// lines describing every candidate blob, the anchors, and the winners.
  /// Purely observational — no threshold, filter, or selection decision
  /// reads this or the extra metrics it logs.
  ///
  /// Runtime diagnostic-mode switch (2026-09-19) — was a hardcoded `const
  /// bool = true` despite this doc comment already saying it should be
  /// off: with the search boxes doubled, a full-quadrant Stage-2 fallback
  /// can evaluate 1000+ candidate contours, each triggering a synchronous
  /// `print()`, sitting directly on the capture path (this runs on every
  /// `locateCorners`/`decode` call in ordinary production scanning, not
  /// just a debug session or the live preview). Now defaults to `false` —
  /// ordinary scanning stays quiet — and is flipped only via
  /// [OmrDecoder.setDiagnosticsEnabled], which
  /// [ExamScanningScreen]'s existing debug-build-only bug-icon toggle
  /// calls once per capture, threaded through the isolate boundary via
  /// [_OmrDecodeRequest.diagnosticsEnabled]/[_DebugVizRequest] (see
  /// `app_state.dart`) since each `compute()` call gets its own isolate
  /// memory — a plain static set on the main isolate would never be seen
  /// there. Each isolate call sets this explicitly at its own start, so no
  /// isolate can carry a stale value from a previous call.
  static bool _kFiducialDebug = false;

  /// TEMPORARY. Synchronous stdout (not debugPrint, whose throttle can drop
  /// the tail when the decode isolate tears down) — every line reaches
  /// logcat as `I/flutter`.
  // ignore: avoid_print
  static void _fidLog(String line) => print('[OMR FIDUCIAL DEBUG] $line');

  /// TEMPORARY diagnostic switch for scan-pipeline latency instrumentation
  /// (investigating a reported post-lock capture/processing slowdown).
  /// Mirrors [_kFiducialDebug]/[_fidLog] — same isolate-safety reasoning
  /// (this code runs inside `compute()`-spawned isolates; `print`, not
  /// `debugPrint`, survives isolate teardown). Purely observational — no
  /// threshold, filter, or selection decision reads these numbers. Remove
  /// once real on-device timings have been collected and acted on.
  static const bool _kPerfDebug = true;

  // ignore: avoid_print
  static void _perfLog(String line) => print('[OMR PERF] $line');

  /// Diagnostic switch for the ring/whole/center per-bubble-candidate log
  /// (4+ lines per item, so a full sheet is 250-400+ lines). Same runtime
  /// toggle as [_kFiducialDebug] — see [OmrDecoder.setDiagnosticsEnabled] —
  /// rather than a separate one, so "diagnostic mode" is one on/off switch,
  /// not several to remember. Purely observational — no threshold or
  /// classification decision reads these numbers.
  static bool _kBubbleDebug = false;

  // ignore: avoid_print
  static void _bubbleLog(String block) => print('[OMR BUBBLE] $block');

  /// Enables or disables verbose fiducial/bubble diagnostic logging
  /// ([_kFiducialDebug]/[_kBubbleDebug]) for whichever isolate this runs
  /// in. Ordinary decoding never calls this (diagnostics default off);
  /// `app_state.dart`'s isolate wrapper functions call it once, first
  /// thing, using a flag threaded in through the request object for that
  /// call — see [_kFiducialDebug]'s doc comment for why a plain static
  /// can't just be toggled from the main isolate directly. Does not gate
  /// [_kPerfDebug] (the cheap, one-line-per-stage timing log) — that stays
  /// independently controlled by `kOmrPerfDebug`, since it produces no
  /// images and no per-candidate volume.
  static void setDiagnosticsEnabled(bool enabled) {
    _kFiducialDebug = enabled;
    _kBubbleDebug = enabled;
  }

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

  /// Loads a captured photo for decoding, choosing whether OpenCV applies
  /// its own EXIF-Orientation auto-rotation (`cv.imread`'s default
  /// behavior for `IMREAD_COLOR` — since OpenCV 3.x it rotates/flips the
  /// decoded pixels to match the file's EXIF `Orientation` tag unless
  /// `IMREAD_IGNORE_ORIENTATION` is passed).
  ///
  /// For every portrait-page template (AT/QTM/PT), the phone is captured
  /// in its natural, never-reconfigured portrait lock, and the whole
  /// pipeline has always been tuned against the default EXIF-aware load —
  /// left exactly as before.
  ///
  /// For the one landscape-page template (TAT), [ExamScanningScreen]
  /// physically unlocks device rotation for that screen only (see its
  /// `_isLandscapeExam`) so the user can turn the phone sideways to fill
  /// the frame with a wide sheet — forced via
  /// `SystemChrome.setPreferredOrientations`, not the OS's own natural
  /// auto-rotate. That same forced-landscape unlock has already caused a
  /// real, confirmed device-orientation-tracking bug elsewhere in this
  /// screen (see its `dispose()` doc comment on the landscapeLeft/
  /// landscapeRight AppLockGate re-lock loop) — trusting the camera
  /// plugin's own EXIF `Orientation` tag for this one screen means
  /// trusting it correctly tracked which way the phone was actually
  /// turned during a forced, non-standard rotation lock. Confirmed broken
  /// on a real device (2026-09-14): a TAT capture's rectified overlay
  /// image came out with the sheet's content rotated to portrait despite
  /// the sheet being landscape — exactly this failure mode.
  ///
  /// Ignoring EXIF for TAT loads the RAW sensor buffer instead and lets
  /// [_orientAndFindCorners]'s own fixed-rotation content search determine
  /// the true orientation by actually finding the corners — the same
  /// EXIF-independent strategy [checkCornersFromLuma] already uses
  /// successfully for the live preview, which reads raw camera bytes with
  /// no EXIF involved at all.
  static cv.Mat _imreadForTemplate(String imagePath, OmrExamTemplate template) {
    final isLandscapePage = template.pageWidthPt > template.pageHeightPt;
    return cv.imread(
      imagePath,
      flags: isLandscapePage
          ? cv.IMREAD_COLOR | cv.IMREAD_IGNORE_ORIENTATION
          : cv.IMREAD_COLOR,
    );
  }

  /// Physically rotates a freshly captured photo to upright, in place on
  /// disk, using the device's ACTUAL orientation at the moment the shutter
  /// fired (`quarterTurnsClockwise` — see `ExamScanningScreen._capture`'s
  /// call site, which derives this from `CameraController.value.
  /// deviceOrientation`, the exact same signal the `camera` plugin itself
  /// uses to keep the live preview upright) rather than guessing the
  /// rotation from pixel content.
  ///
  /// Exists specifically for landscape-page templates (TAT), for a device
  /// orientation lock this screen no longer applies (TAT capture is fully
  /// portrait-locked now — see `ExamScanningScreen._isLandscapeExam`,
  /// always false — so this method's call site is currently unreachable).
  /// Left in place rather than removed since nothing about the underlying
  /// need has changed: [_orientAndFindCorners]'s content-based search alone
  /// can't always pick correctly, because a printed corner square looks
  /// identical under any 90° rotation, so more than one candidate rotation
  /// can "succeed" at finding 4 square-shaped blobs — it's the same 4
  /// physical squares either way, just mislabeled.
  /// Confirmed on a real device (2026-09-14): a capture whose rectified
  /// output came out with the sheet's content rotated 90° despite the
  /// file itself being correctly landscape-shaped (the output size is
  /// always [OmrExamTemplate.pageWidthPt]/[pageHeightPt]-derived,
  /// independent of which rotation was used internally — so a
  /// correctly-sized-but-wrongly-rotated result is possible and is
  /// exactly what this fixes).
  ///
  /// Called once, immediately after `takePicture()`, before anything else
  /// (the post-capture alignment check, `decode`, `rectifyForOverlay`,
  /// etc.) ever reads the file — so every later stage just sees an
  /// already-upright photo and needs no special handling. Loads ignoring
  /// EXIF (see [_imreadForTemplate]'s doc comment for why that matters for
  /// a landscape template specifically) so this is the one and only
  /// rotation ever applied. A no-op when [quarterTurnsClockwise] is a
  /// multiple of 4 (already upright) — including when it's 0, the common
  /// case for every non-landscape template, which never calls this at all.
  void normalizeCaptureOrientation(String imagePath, int quarterTurnsClockwise) {
    final turns = quarterTurnsClockwise % 4;
    if (turns == 0) return;
    final src = cv.imread(
      imagePath,
      flags: cv.IMREAD_COLOR | cv.IMREAD_IGNORE_ORIENTATION,
    );
    try {
      if (src.isEmpty) return;
      final rotated = cv.rotate(
        src,
        switch (turns) {
          1 => cv.ROTATE_90_CLOCKWISE,
          2 => cv.ROTATE_180,
          _ => cv.ROTATE_90_COUNTERCLOCKWISE,
        },
      );
      try {
        cv.imwrite(imagePath, rotated);
      } finally {
        rotated.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Authoritative post-capture gate, run right after a photo is captured
  /// and before it's ever added to the batch: does the same image load +
  /// corner search as [decode], and — unlike this method's original
  /// "cheap" scope — the same perspective warp and post-warp geometric
  /// verification too (see [_checkAlignment]/[_verifyWarpedCorners]), so a
  /// photo that would produce a badly-corrected sheet is caught here, not
  /// discovered later as a bad score. Still skips illumination
  /// normalization, CLAHE, and bubble sampling — [decode]'s genuinely
  /// expensive stages — so this remains reasonable to run on every capture.
  AlignmentCheck locateCorners(String imagePath, OmrExamTemplate template) {
    final src = _imreadForTemplate(imagePath, template);
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
  /// Also returns each found corner's centroid, normalized to `(x/width,
  /// y/height)` fractions of this frame — device/resolution-independent —
  /// so callers (the live scanning screen's auto-capture stability check)
  /// can diff a corner's position between frames without needing raw pixel
  /// coordinates. Plain `(double, double)` records, not `cv.Point2f`: the
  /// latter wraps a native FFI struct and isn't safe to return from a
  /// `compute()`-spawned isolate, unlike a value record.
  ///
  /// Searches the same way [_refineCorners] does (see [_quadrantsFor],
  /// [_findMarkerInRegion]) — a tight template-expected box first, the full
  /// photo quadrant if that misses — so the live guide and the post-capture
  /// gate can never disagree about whether a mark is findable in a frame.
  ({
    List<CornerConfidence> confidence,
    List<(double, double)?> positions,
    List<CornerDiagnostic>? diagnostics,
    FrameRotation rotation,
  })
      checkCornersFromLuma(
    Uint8List lumaBytes,
    int width,
    int height,
    int bytesPerRow,
    OmrExamTemplate template, {
    // Temporary, opt-in only (see `ExamScanningScreen._diagnosticsEnabled`)
    // — every field below is descriptive-only and read by nothing else in
    // this method or its callers, so leaving this false costs nothing over
    // the previous behavior.
    bool includeDiagnostics = false,
  }) {
    final full = cv.Mat.fromList(
      height,
      bytesPerRow,
      cv.MatType.CV_8UC1,
      lumaBytes,
    );
    try {
      final cropped = bytesPerRow == width
          ? full
          : full.region(cv.Rect(0, 0, width, height));
      try {
        // See [_liveCheckMaxDimension]'s doc comment — this is what
        // actually keeps a live check fast; everything below is unchanged.
        final longSide = math.max(cropped.width, cropped.height);
        final cv.Mat gray;
        if (longSide > _liveCheckMaxDimension) {
          final scale = _liveCheckMaxDimension / longSide;
          gray = cv.resize(
            cropped,
            ((cropped.width * scale).round(), (cropped.height * scale).round()),
            interpolation: cv.INTER_AREA,
          );
        } else {
          gray = cropped;
        }
        try {
          // Raw camera frames can be sideways even in a portrait-locked UI.
          // Retry every template, but stop as soon as all corners are confident.
          var best = _searchLiveCorners(
            gray, template,
            detailGray: cropped,
            includeDiagnostics: includeDiagnostics,
          );
          var bestScore = _liveConfidenceScore(best.confidence);
          var bestRotation = FrameRotation.none;
          if (best.confidence.every((c) => c == CornerConfidence.confident)) {
            return (
              confidence: best.confidence,
              positions: best.positions,
              diagnostics: best.diagnostics,
              rotation: bestRotation,
            );
          }
          for (final code in [
            cv.ROTATE_90_CLOCKWISE,
            cv.ROTATE_90_COUNTERCLOCKWISE,
          ]) {
            final rotated = cv.rotate(gray, code);
            final rotatedDetail = identical(gray, cropped)
                ? rotated
                : cv.rotate(cropped, code);
            try {
              final candidate = _searchLiveCorners(
                rotated, template,
                detailGray: rotatedDetail,
                includeDiagnostics: includeDiagnostics,
              );
              final score = _liveConfidenceScore(candidate.confidence);
              if (score > bestScore) {
                best = candidate;
                bestScore = score;
                bestRotation = code == cv.ROTATE_90_CLOCKWISE
                    ? FrameRotation.clockwise90
                    : FrameRotation.counterClockwise90;
              }
              if (best.confidence.every((c) => c == CornerConfidence.confident)) {
                break;
              }
            } finally {
              if (!identical(rotatedDetail, rotated)) rotatedDetail.dispose();
              rotated.dispose();
            }
          }
          return (
            confidence: best.confidence,
            positions: best.positions,
            diagnostics: best.diagnostics,
            rotation: bestRotation,
          );
        } finally {
          if (!identical(gray, cropped)) gray.dispose();
        }
      } finally {
        if (!identical(cropped, full)) cropped.dispose();
      }
    } finally {
      full.dispose();
    }
  }

  /// One live corner search pass over [gray] at whatever orientation it's
  /// already in — the body [checkCornersFromLuma] always ran, now shared
  /// so a landscape template can try it against multiple rotations.
  ({
    List<CornerConfidence> confidence,
    List<(double, double)?> positions,
    List<CornerDiagnostic>? diagnostics,
  })
      _searchLiveCorners(
    cv.Mat gray,
    OmrExamTemplate template, {
    cv.Mat? detailGray,
    bool includeDiagnostics = false,
  }) {
    final pageQuad = _detectPageQuad(gray);
    final searches = _quadrantsFor(gray.width, gray.height, pageQuad, template);
    final results = [
      for (final s in searches)
        _bestOf(
          _findMarkerInRegion(
            gray, s.stage1, s.anchorX, s.anchorY,
            anchorScaleOverride: s.stage1AnchorScale,
          ),
          () => _findMarkerInRegion(gray, s.quadrant, s.anchorX, s.anchorY),
        ),
    ];
    // Bounded higher-resolution retry: once the sheet is roughly in frame
    // (>=2 corners already confident at this frame's downscaled resolution
    // — see [_liveCheckMaxDimension]'s doc comment), re-measure every
    // remaining `low`-tier corner whose *shape* score (not position) is the
    // only thing holding it back, against the original un-downscaled
    // pixels. Bounded by construction: with >=2 already confident, at most
    // 2 corners can be `low` here, so this never means running
    // full-resolution detection across all 4 corners on every frame — only
    // whichever ones are actually still uncertain.
    //
    // Previously this only fired with EXACTLY 3 confident corners, so two
    // simultaneously weak corners (e.g. both dimmed by an uneven shadow, or
    // both just slightly soft from preview downscaling) never got this
    // retry's benefit at all and could stay stuck yellow indefinitely —
    // confirmed by direct code review of the old `== 3` gate, not assumed.
    if (detailGray != null && !identical(detailGray, gray) &&
        results.where((r) => r.confidence == CornerConfidence.confident).length >= 2) {
      final sx = detailGray.width / gray.width;
      final sy = detailGray.height / gray.height;
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        final c = r.centroid;
        final b = r.bboxGlobal;
        if (r.confidence != CornerConfidence.low || c == null || b == null ||
            r.squareness >= _markerMinSquarenessConfident ||
            r.positionScore < 0.36787944) continue;
        final cx = (c.x + 0.5) * sx - 0.5;
        final cy = (c.y + 0.5) * sy - 0.5;
        final pad = math.max(12.0, math.max(b.width, b.height) * 2.0);
        final box = _clampedRect(cx - pad * sx, cy - pad * sy,
            cx + pad * sx, cy + pad * sy, detailGray.width, detailGray.height);
        final detailed = _findMarkerInRegion(detailGray, box, cx, cy);
        final p = detailed.centroid;
        // Confirm the same blob, rather than switching to neighboring text.
        if (detailed.confidence != CornerConfidence.confident || p == null ||
            ((p.x - cx) / sx).abs() > b.width / 2 ||
            ((p.y - cy) / sy).abs() > b.height / 2) continue;
        results[i] = _MarkerSearchResult(
          centroid: cv.Point2f((p.x + 0.5) / sx - 0.5, (p.y + 0.5) / sy - 0.5),
          bboxGlobal: b,
          confidence: CornerConfidence.confident,
          squareness: detailed.squareness,
          contrast: detailed.contrast,
          anchorDistance: r.anchorDistance,
          positionScore: r.positionScore,
          rejected: r.rejected,
        );
      }
    }

    // Geometric cross-check + promotion + rescue — see
    // [_crossCheckCornersByGeometry]'s doc comment. This is what lets a
    // corner whose shape/contrast are genuinely fine, but whose position
    // score was only measured against an inaccurate page-boundary guess
    // (see [_detectPageQuad]), actually reach `confident` and turn the
    // live indicator green — never by loosening the shape/contrast gates
    // themselves, only by using the other 3 corners' own real geometry as
    // stronger evidence of where this one has to be.
    final points = List<cv.Point2f?>.generate(4, (i) => results[i].centroid);
    _crossCheckCornersByGeometry(
      points, results, gray, template,
      allowRescueSearch: true,
    );

    return (
      confidence: [for (final r in results) r.confidence],
      positions: [
        for (final r in results)
          r.centroid == null
              ? null
              : (r.centroid!.x / gray.width, r.centroid!.y / gray.height),
      ],
      diagnostics: includeDiagnostics
          ? [
              for (var i = 0; i < 4; i++)
                _buildCornerDiagnostic(results[i], searches[i], gray.width, gray.height),
            ]
          : null,
    );
  }

  /// Builds one corner's [CornerDiagnostic] for the temporary opt-in live
  /// overlay (see [checkCornersFromLuma]'s `includeDiagnostics`) — purely
  /// descriptive, never read by any detection/capture decision. [result]
  /// and [search] must be for the same corner index; [frameWidth]/
  /// [frameHeight] are the frame ([gray] in [_searchLiveCorners]) they were
  /// both measured against, used only to normalize into fractions.
  CornerDiagnostic _buildCornerDiagnostic(
    _MarkerSearchResult result,
    _QuadrantSearch search,
    int frameWidth,
    int frameHeight,
  ) {
    final box = search.stage1;
    final CornerRejectionCategory category;
    if (result.confidence == CornerConfidence.confident) {
      category = CornerRejectionCategory.confident;
    } else if (result.centroid == null) {
      // Nothing was accepted -- fall back to the single closest rejected
      // candidate's own reason (contrast/shape/position) when there was
      // one at all, so "nothing found" and "something was there but it
      // failed a specific gate" read differently in the overlay.
      category = result.rejected.isEmpty
          ? CornerRejectionCategory.noCandidate
          : categorizeRejectionReason(result.rejected.first.reason);
    } else if (result.squareness < _markerMinSquarenessConfident) {
      category = CornerRejectionCategory.shape;
    } else {
      // An accepted candidate always already clears the hard contrast gate
      // (see [_findMarkerInRegion]'s `contrast < _markerMinContrast` reject)
      // and, by this branch, the shape gate too — position is the only
      // remaining reason a winner stays `low`.
      category = CornerRejectionCategory.position;
    }
    return CornerDiagnostic(
      searchBoxFrac: (
        x0: box.x / frameWidth,
        y0: box.y / frameHeight,
        x1: (box.x + box.width) / frameWidth,
        y1: (box.y + box.height) / frameHeight,
      ),
      anchorFrac: (search.anchorX / frameWidth, search.anchorY / frameHeight),
      centroidFrac: result.centroid == null
          ? null
          : (result.centroid!.x / frameWidth, result.centroid!.y / frameHeight),
      confidence: result.confidence,
      squareness: result.squareness,
      contrast: result.contrast,
      positionScore: result.positionScore,
      rejection: category,
    );
  }

  /// Total ranking score for a live search's 4 corner tiers — confident
  /// counts double a low, none counts nothing — used only to pick the best
  /// of 3 orientation attempts for a landscape template; never read by any
  /// classification decision.
  int _liveConfidenceScore(List<CornerConfidence> tiers) => tiers.fold(
        0,
        (sum, t) => sum +
            switch (t) {
              CornerConfidence.confident => 2,
              CornerConfidence.low => 1,
              CornerConfidence.none => 0,
            },
      );

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

  /// Sanity-checks that 3 candidate points ([pts], in the same order as
  /// their known template page-fraction positions [fracs] — an outer
  /// corner marker's own fraction, or (since 2026-09-18) an interior
  /// fiducial's, when one of those was used to help seed the fit) form a
  /// triangle whose own proportions are at least roughly consistent with
  /// what the template says the real, physical spacing between those same
  /// 3 points should be.
  ///
  /// Confirmed on a real device (2026-09-14) that this was a real,
  /// unguarded gap: [_crossCheckCornersByGeometry] validates a 4th,
  /// separately-missing corner against whichever 3 corners were already
  /// "usable", but never validated those 3 against EACH OTHER — a stray
  /// dark blob deep inside the answer grid (roughly 2/3 of the way down
  /// an AT sheet, mistaken for the bottom-left corner, whose real mark
  /// sits at the very bottom edge) sailed straight through as a trusted
  /// seed point purely because it was one of only 3 corners with any
  /// detection at all, and produced a nonsensical warp that still
  /// scored.
  ///
  /// Compares PAIRWISE DISTANCE RATIOS (not absolute distances, which a
  /// photo's own scale/distance makes meaningless) between the 3 points,
  /// in pixel space, against the same ratios computed from the template's
  /// own page-fraction positions converted to real page-point distances.
  /// Ratios stay roughly stable under the moderate perspective distortion
  /// a realistic, roughly fronto-parallel handheld photo introduces, so a
  /// wildly inconsistent ratio is real evidence one of the 3 points is
  /// wrong — not merely photo distortion. The tolerance (any ratio within
  /// half to double of its expected value) is deliberately generous:
  /// this only needs to catch a GROSS mislocation like the one confirmed
  /// above, never to fine-tune precision — that remains the job of the
  /// stricter post-warp reprojection check ([_classifyWarpVerification])
  /// once a homography actually exists to measure.
  bool _cornerTriplePlausible(
    List<(double, double)> fracs,
    List<cv.Point2f> pts,
    OmrExamTemplate template,
  ) {
    double templateDist(int a, int b) {
      final ma = fracs[a];
      final mb = fracs[b];
      final dx = (ma.$1 - mb.$1) * template.pageWidthPt;
      final dy = (ma.$2 - mb.$2) * template.pageHeightPt;
      return math.sqrt(dx * dx + dy * dy);
    }

    double pixelDist(cv.Point2f a, cv.Point2f b) {
      final dx = a.x - b.x;
      final dy = a.y - b.y;
      return math.sqrt(dx * dx + dy * dy);
    }

    final tDist = [
      templateDist(0, 1),
      templateDist(1, 2),
      templateDist(0, 2),
    ];
    final pDist = [
      pixelDist(pts[0], pts[1]),
      pixelDist(pts[1], pts[2]),
      pixelDist(pts[0], pts[2]),
    ];
    for (var i = 0; i < 3; i++) {
      for (var j = i + 1; j < 3; j++) {
        if (tDist[i] <= 0 || tDist[j] <= 0 || pDist[i] <= 0 || pDist[j] <= 0) {
          continue;
        }
        final expectedRatio = tDist[i] / tDist[j];
        final actualRatio = pDist[i] / pDist[j];
        final relError = (actualRatio / expectedRatio - 1).abs();
        if (relError > 1.0) return false;
      }
    }
    return true;
  }

  /// Cross-checks each corner's position against the affine geometry
  /// implied by (up to) 3 of the OTHER corners already found, then, where
  /// possible, downgrades, promotes, or rescues using that same geometry:
  ///
  ///  * a candidate that maps inside the answer grid, or too far from its
  ///    own expected position under that affine, is downgraded to
  ///    [CornerConfidence.none] — this is what stops a shaded answer bubble
  ///    or stray text from riding along as a "corner" even though its own
  ///    shape/contrast scoring passed;
  ///  * a corner stuck at [CornerConfidence.low] purely because its own
  ///    *position* score was measured against an inaccurate expected anchor
  ///    — [_quadrantsFor]'s anchor comes from [_detectPageQuad]'s guessed
  ///    page boundary, which can be wrong — gets promoted to
  ///    [CornerConfidence.confident] once the other corners' own geometry
  ///    confirms it sits exactly where a real corner must be, without
  ///    loosening its shape/contrast gates at all;
  ///  * a corner with no centroid at all gets one dedicated rescue search
  ///    of the small box the other three predict, promoted only on real
  ///    marker evidence found there (never a bare geometric point).
  ///
  /// Shared by the post-capture [_refineCorners] and the live per-frame
  /// [_searchLiveCorners] so both apply the exact same protection against a
  /// false "corner" and the exact same geometry-based rescue/promotion —
  /// the live guide and the post-capture gate must never disagree about
  /// whether a mark is findable in a frame (this is also what fixes the
  /// live indicator getting permanently stuck yellow/never-green on a
  /// frame where the page-boundary guess is off but all 4 real marks are
  /// genuinely visible).
  ///
  /// Needs >=3 points with *some* evidence to fit a transform through —
  /// outer corners with confidence != none first, topped up with
  /// [extraAnchors] (2026-09-18: independently-found interior fiducials,
  /// currently only TAT's — see [_findInteriorAnchorsRaw]) when fewer than
  /// 3 outer corners qualify; no-ops (returns null) if even that isn't
  /// enough. Mutates [points]/[results] in place — only ever for the 4
  /// outer-corner slots; [extraAnchors] themselves are read-only inputs to
  /// the fit, never written back to. Returns a short user-facing note when
  /// a corner was rescued or promoted this way (or null).
  ///
  /// [_cornerTriplePlausible] is the mutual-consistency gate this method
  /// applies to its own 3-point seed before trusting it — see that
  /// method's doc comment for the concrete failure it was built to catch.
  String? _crossCheckCornersByGeometry(
    List<cv.Point2f?> points,
    List<_MarkerSearchResult> results,
    cv.Mat gray,
    OmrExamTemplate template, {
    required bool allowRescueSearch,
    List<String>? labels,
    List<({cv.Point2f point, double xFrac, double yFrac})> extraAnchors = const [],
  }) {
    const fallbackLabels = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];
    final names = labels ?? fallbackLabels;
    final debug = _kFiducialDebug && labels != null;
    String? note;

    final usableIdx = [
      for (var i = 0; i < 4; i++)
        if (results[i].confidence != CornerConfidence.none) i,
    ]..sort((a, b) {
        final rankA = results[a].confidence == CornerConfidence.confident ? 0 : 1;
        final rankB = results[b].confidence == CornerConfidence.confident ? 0 : 1;
        return rankA.compareTo(rankB);
      });

    // Seed with the sheet's own outer corners first (best-conditioned --
    // widely spaced at the page's actual edges), and only reach for
    // [extraAnchors] (2026-09-18: TAT's interior per-Test marks, found
    // independently in raw image space -- see [_findInteriorAnchorsRaw])
    // when outer corners alone don't reach 3. Before this, a capture with
    // only 1-2 usable outer corners always bailed out right here
    // (`usableIdx.length < 3`) with a hard "not fully detected" rejection,
    // even for a template like TAT that prints 8 more real fiducials than
    // the primary 4-corner homography strictly needs -- none of that
    // redundancy ever got a chance to help. [threeIdx] below stays exactly
    // the outer-corner indices actually used (never more than
    // [usableIdx.length]), so 4a/4b's own "skip the corners already used
    // as the seed" loops are unaffected by however many extra anchors
    // filled the remaining slots.
    final threeIdx = usableIdx.take(3).toList();
    final threePts = [for (final i in threeIdx) points[i]!];
    final threeFracTuples = [
      for (final i in threeIdx)
        (template.cornerMarkers[i].xFrac, template.cornerMarkers[i].yFrac),
    ];
    if (threePts.length < 3) {
      for (final a in extraAnchors) {
        if (threePts.length >= 3) break;
        threePts.add(a.point);
        threeFracTuples.add((a.xFrac, a.yFrac));
      }
    }
    if (threePts.length < 3) return null;
    if (_nearCollinear(threePts)) return null;
    // Confirmed on a real device (2026-09-14): with exactly 3 corners
    // "usable" (not 4 confidently found), the 3 were blindly trusted as
    // ground truth for seeding the affine below -- nothing ever
    // cross-checked them against EACH OTHER, only a 4th, separately
    // missing corner ever got checked against them (see 4a below). A
    // stray dark blob deep inside the answer grid (mistaken for the
    // bottom-left corner, ~2/3 of the way down the page instead of at the
    // bottom edge) sailed straight through as a trusted seed point this
    // way and produced a nonsensical warp that still got accepted. Reject
    // the whole triple up front if its own proportions are wildly
    // inconsistent with what the template says these 3 points' real
    // spacing should be -- this can only make the 4th corner (if missing)
    // stay missing (an honest "not fully detected" retake) instead of
    // silently building a homography from a point that was never real.
    if (!_cornerTriplePlausible(threeFracTuples, threePts, template)) return null;

    final threeFracs = [
      for (final f in threeFracTuples) cv.Point2f(f.$1, f.$2),
    ];
    final imgToFrac = cv.getAffineTransform2f(
      cv.VecPoint2f.fromList(threePts),
      cv.VecPoint2f.fromList(threeFracs),
    );
    try {
      final grid = _answerGridBboxFrac(template);
      bool insideGrid(double fx, double fy) =>
          fx >= grid.x0 && fx <= grid.x1 && fy >= grid.y0 && fy <= grid.y1;

      // 4a: downgrade anything geometrically implausible; promote anything
      // geometrically consistent that was only held back by its position
      // score.
      for (var i = 0; i < 4; i++) {
        if (threeIdx.contains(i) || points[i] == null) continue;
        final p = points[i]!;
        final (fx, fy) = _applyAffine(imgToFrac, p.x.toDouble(), p.y.toDouble());
        final marker = template.cornerMarkers[i];
        final off = math.sqrt(
            math.pow(fx - marker.xFrac, 2) + math.pow(fy - marker.yFrac, 2));
        final bad = insideGrid(fx, fy) || off > _affineToleranceFrac;
        if (bad) {
          if (debug) {
            _fidLog('q=${names[i]} DOWNGRADE reason=${insideGrid(fx, fy) ? "inside_grid" : "geom_inconsistent"} '
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
          continue;
        }
        if (results[i].confidence == CornerConfidence.low &&
            results[i].squareness >= _markerMinSquarenessConfident &&
            results[i].contrast >= _markerMinContrast) {
          if (debug) {
            _fidLog('q=${names[i]} PROMOTE via geometry (off=${off.toStringAsFixed(3)}, '
                'sq=${results[i].squareness.toStringAsFixed(3)})');
          }
          results[i] = _MarkerSearchResult(
            centroid: results[i].centroid,
            bboxGlobal: results[i].bboxGlobal,
            confidence: CornerConfidence.confident,
            squareness: results[i].squareness,
            contrast: results[i].contrast,
            anchorDistance: results[i].anchorDistance,
            positionScore: results[i].positionScore,
            rejected: results[i].rejected,
          );
          note ??= '${names[i]} corner confirmed via geometry';
        }
      }

      // 4b: dedicated rescue search for exactly the corners still missing.
      if (allowRescueSearch) {
        final fracToImg = cv.getAffineTransform2f(
          cv.VecPoint2f.fromList(threeFracs),
          cv.VecPoint2f.fromList(threePts),
        );
        try {
          for (var i = 0; i < 4; i++) {
            if (threeIdx.contains(i) || points[i] != null) continue;
            final marker = template.cornerMarkers[i];
            final (px, py) = _applyAffine(fracToImg, marker.xFrac, marker.yFrac);
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
            final tag = debug ? '${names[i]}-rescue' : null;
            final rescueAnchorScale = math.max(
              1.0,
              0.25 *
                  (2 * kFiducialAnchorToleranceFrac * math.min(gray.width, gray.height)) *
                  math.sqrt2,
            );
            final rr = _findMarkerInRegion(
              gray, rescueBox, px, py,
              debugTag: tag,
              anchorScaleOverride: rescueAnchorScale,
            );
            final rc = rr.centroid;
            if (rc == null ||
                rr.squareness < _markerMinSquarenessLow ||
                rr.contrast < _markerMinContrast) {
              if (debug) {
                _fidLog('q=${names[i]} RESCUE_FAILED no convincing marker '
                    'evidence near predicted (${px.toStringAsFixed(1)},${py.toStringAsFixed(1)})');
              }
              continue;
            }
            final (rfx, rfy) = _applyAffine(imgToFrac, rc.x.toDouble(), rc.y.toDouble());
            final roff = math.sqrt(
                math.pow(rfx - marker.xFrac, 2) + math.pow(rfy - marker.yFrac, 2));
            if (insideGrid(rfx, rfy) || roff > _affineToleranceFrac) {
              if (debug) {
                _fidLog('q=${names[i]} RESCUE_FAILED candidate found but '
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
            note = '${names[i]} corner recovered via geometry-assisted rescue';
            if (debug) {
              _fidLog('q=${names[i]} RESCUED sq=${rr.squareness.toStringAsFixed(3)}');
            }
          }
        } finally {
          fracToImg.dispose();
        }
      }
    } finally {
      imgToFrac.dispose();
    }
    return note;
  }

  /// Used by [locateCorners] — the post-capture gate, and the only place
  /// that can reject a bad photo before it ever enters the batch. Doesn't
  /// stop at finding the four corners: also fits the homography and warps,
  /// then independently re-detects each marker on the warped image to
  /// confirm the correction actually landed them where the template says
  /// they must be (see [_verifyWarpedCorners]) — a "4/4 confidently found"
  /// read is not, by itself, proof that the resulting perspective
  /// correction is trustworthy. Skips bubble sampling/illumination
  /// normalization/CLAHE — the expensive parts of [decode] — so this stays
  /// reasonable to run on every capture.
  ///
  /// A [_RefineResult] with [AlignmentVerdict.green] or
  /// [AlignmentVerdict.yellow] both count as pre-warp `aligned` — yellow
  /// means a usable quad was still produced (see [_refineCorners]'s Stage
  /// 4), just with a corner recovered by geometry rather than crisply
  /// detected. The post-warp check can still downgrade either to rejected
  /// or degraded, independent of the pre-warp verdict.
  AlignmentCheck _checkAlignment(cv.Mat gray, OmrExamTemplate template) {
    final totalSw = _kPerfDebug ? (Stopwatch()..start()) : null;
    var cornerSearchMs = 0;
    var warpMs = 0;
    var warpVerifyMs = 0;
    try {
      final cornerSw = _kPerfDebug ? (Stopwatch()..start()) : null;
      final (oriented, refine, _) = _orientAndFindCorners(gray, template);
      if (cornerSw != null) cornerSearchMs = cornerSw.elapsedMilliseconds;
      try {
        final canonicalWidth =
            (template.pageWidthPt * _canonicalPxPerPt).round();
        final canonicalHeight =
            (template.pageHeightPt * _canonicalPxPerPt).round();
        final dstCorners = cv.VecPoint2f.fromList([
          for (final c in template.cornerMarkers)
            cv.Point2f(
              c.xFrac * canonicalWidth,
              c.yFrac * canonicalHeight,
            ),
        ]);
        final srcCorners = cv.VecPoint2f.fromList(refine.corners);
        final warpSw = _kPerfDebug ? (Stopwatch()..start()) : null;
        final transform = cv.getPerspectiveTransform2f(srcCorners, dstCorners);
        try {
          final warped = cv.warpPerspective(
            oriented,
            transform,
            (canonicalWidth, canonicalHeight),
          );
          if (warpSw != null) warpMs = warpSw.elapsedMilliseconds;
          try {
            final verifySw = _kPerfDebug ? (Stopwatch()..start()) : null;
            final verification = _verifyWarpedCorners(
              warped,
              template,
              canonicalWidth,
              canonicalHeight,
            );
            final classified =
                _classifyWarpVerification(verification, refine.confidence);
            if (verifySw != null) warpVerifyMs = verifySw.elapsedMilliseconds;
            void logTotal() {
              if (totalSw == null) return;
              _perfLog(
                'locateCorners cornerSearch=${cornerSearchMs}ms warp=${warpMs}ms '
                'warpVerify=${warpVerifyMs}ms total=${totalSw.elapsedMilliseconds}ms',
              );
            }

            if (!classified.ok) {
              logTotal();
              return AlignmentCheck.warpMisaligned(
                classified.message!,
                refine.confidence,
                verification.errorPx,
              );
            }
            if (classified.degraded ||
                refine.verdict != AlignmentVerdict.green) {
              logTotal();
              return AlignmentCheck.degraded(
                classified.message ?? refine.note,
                refine.confidence,
                verification.errorPx,
              );
            }
            logTotal();
            return const AlignmentCheck.aligned();
          } finally {
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
    } on StateError catch (e) {
      if (totalSw != null) {
        _perfLog(
          'locateCorners cornerSearch=${cornerSearchMs}ms FAILED '
          'total=${totalSw.elapsedMilliseconds}ms',
        );
      }
      return AlignmentCheck.misaligned(e.message);
    }
  }

  /// Reads [imagePath] against [template] and returns the decoded marks.
  /// Throws a [StateError] with a user-facing message if the sheet couldn't
  /// be read or aligned.
  OmrScanResult decode(String imagePath, OmrExamTemplate template, {String? rectifiedOutputPath}) {
    final decodeTotalSw = _kPerfDebug ? (Stopwatch()..start()) : null;
    var decodeCornerSearchMs = 0;
    var decodeWarpMs = 0;
    var decodeWarpVerifyMs = 0;
    var decodeIllumMs = 0;
    var decodeBilateralMs = 0;
    var decodeClaheMs = 0;
    var decodeThresholdMs = 0;
    var decodeBubbleReadMs = 0;
    final src = _imreadForTemplate(imagePath, template);
    try {
      if (src.isEmpty) {
        throw StateError('Could not read the captured photo at $imagePath.');
      }
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        final cornerSw = _kPerfDebug ? (Stopwatch()..start()) : null;
        final (oriented, refine, rotationCode) = _orientAndFindCorners(gray, template);
        if (cornerSw != null) {
          decodeCornerSearchMs = cornerSw.elapsedMilliseconds;
        }
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
          final warpSw = _kPerfDebug ? (Stopwatch()..start()) : null;
          final transform = cv.getPerspectiveTransform2f(
            srcCorners,
            dstCorners,
          );
          try {
            final warped = cv.warpPerspective(oriented, transform, (
              canonicalWidth,
              canonicalHeight,
            ));
            if (warpSw != null) decodeWarpMs = warpSw.elapsedMilliseconds;
            // Declared out here so the `finally` below can dispose it; it is
            // assigned as the first statement inside the `try`.
            cv.Mat? normalizedGray;
            try {
              // Post-warp geometric gate: independently re-detect each
              // fiducial directly on `warped` (already grayscale — `oriented`
              // is derived from `gray`) and reject the whole photo if any
              // one lands too far from its known canonical position. This
              // is what actually catches a photo that passed every pre-warp
              // check (Stage 4's geometry cross-check, _validateQuad) but
              // still produced a badly-corrected sheet — see
              // [_verifyWarpedCorners]'s doc comment for why this can't be
              // done by re-projecting the same 4 source points instead.
              // Should already have been caught by [locateCorners] before
              // this photo ever entered the batch, but decode() never
              // assumes another method's check transfers to this exact
              // call — same isolation philosophy as [rectifyForOverlay].
              final verifySw = _kPerfDebug ? (Stopwatch()..start()) : null;
              final warpVerification = _verifyWarpedCorners(
                warped,
                template,
                canonicalWidth,
                canonicalHeight,
              );
              final warpVerdict =
                  _classifyWarpVerification(warpVerification, refine.confidence);
              if (verifySw != null) {
                decodeWarpVerifyMs = verifySw.elapsedMilliseconds;
              }
              if (!warpVerdict.ok) {
                throw StateError(warpVerdict.message!);
              }

              // Local mesh correction: only meaningful for a template that
              // prints the extra interior fiducials (see
              // [OmrExamTemplate.interiorFiducials]) — a no-op (empty map,
              // [OmrMeshCorrection.build] returns
              // [OmrMeshVerdict.notApplicable]) for every legacy sheet and
              // TAT, so this changes nothing for them. The 4 corners are
              // passed as their own canonical position (not
              // `refine.corners`, which are pre-warp/original-photo
              // coordinates) — they're exactly where the homography just
              // put them by construction; see [OmrMeshCorrection]'s doc
              // comment for why only the 5 interior points can show a real
              // measured residual.
              final meshSw = _kPerfDebug ? (Stopwatch()..start()) : null;
              final interiorMeasured = _detectInteriorFiducials(
                warped,
                template,
                canonicalWidth,
                canonicalHeight,
              );
              final mesh = OmrMeshCorrection.build(
                template: template,
                canonicalWidth: canonicalWidth,
                canonicalHeight: canonicalHeight,
                cornersMeasuredPx: [
                  for (final c in template.cornerMarkers)
                    (c.xFrac * canonicalWidth, c.yFrac * canonicalHeight),
                ],
                interiorMeasuredPx: interiorMeasured,
              );
              final decodeMeshMs = meshSw?.elapsedMilliseconds ?? 0;
              if (_kFiducialDebug) {
                for (final d in mesh.diagnostics) {
                  _fidLog('mesh $d');
                }
              }
              // Positive, measured evidence of a problem (either the
              // interior marks agree with each other on being far from
              // where they should be, or they disagree with each other in
              // a way consistent with a mismatched outer corner) rejects
              // the capture outright, with a reason naming which failure
              // it is — distinct from [OmrMeshVerdict.inconclusive] (marks
              // simply weren't visible), which never rejects by itself; see
              // [OmrMeshCorrection.shouldRejectCapture]'s doc comment. This
              // is independent of [warpVerdict] above: a capture can pass
              // the 4-corner reprojection check (the corners *individually*
              // land close enough to their targets) while the interior
              // marks still reveal the chosen correspondence itself is
              // wrong — that's exactly the failure mode this second,
              // independent check exists to catch.
              if (mesh.shouldRejectCapture) {
                throw StateError(mesh.rejectionReason!);
              }

              // Illumination normalization runs first, on the raw warp:
              // divide out a large-scale estimate of the lighting/shadow
              // field so a strong cast shadow or an uneven LED wash reaches
              // the CLAHE + threshold stages below as a roughly evenly-lit
              // page, which is what their (fixed and darkness-adaptive)
              // margins already assume. Best-effort — [_normalizeIllumination]
              // returns `warped` itself on any failure, so `identical`
              // short-circuits every use below and the pipeline is unchanged
              // whenever normalization couldn't help.
              final illumSw = _kPerfDebug ? (Stopwatch()..start()) : null;
              normalizedGray = _normalizeIllumination(warped);
              if (illumSw != null) decodeIllumMs = illumSw.elapsedMilliseconds;

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
              final bilateralSw = _kPerfDebug ? (Stopwatch()..start()) : null;
              final claheInput = darkness > 0
                  ? cv.bilateralFilter(
                      normalizedGray, 5, 50 * darkness, 50 * darkness)
                  : normalizedGray;
              if (bilateralSw != null) {
                decodeBilateralMs = bilateralSw.elapsedMilliseconds;
              }
              try {
                final claheSw = _kPerfDebug ? (Stopwatch()..start()) : null;
                final clahe = cv.createCLAHE(
                  clipLimit: _adaptiveClipLimit(_claheClipLimitFor(template.examCode), warpedBrightness),
                  tileGridSize: (8, 8),
                );
                try {
                  final normalized = clahe.apply(claheInput);
                  if (claheSw != null) decodeClaheMs = claheSw.elapsedMilliseconds;
                  try {
                    final blurred = cv.gaussianBlur(normalized, (5, 5), 0);
                    try {
                      final threshSw = _kPerfDebug ? (Stopwatch()..start()) : null;
                      final inkMap = cv.adaptiveThreshold(
                        blurred,
                        255,
                        cv.ADAPTIVE_THRESH_GAUSSIAN_C,
                        cv.THRESH_BINARY_INV,
                        _adaptiveThresholdBlockSizeFor(template.examCode),
                        _adaptiveThresholdCFor(_adaptiveThresholdC, warpedBrightness),
                      );
                      if (threshSw != null) {
                        decodeThresholdMs = threshSw.elapsedMilliseconds;
                      }
                      try {
                        final bubbleSw = _kPerfDebug ? (Stopwatch()..start()) : null;
                        final result = _readBubbles(
                          inkMap,
                          template,
                          canonicalWidth,
                          canonicalHeight,
                          mesh,
                        );
                        if (bubbleSw != null) {
                          decodeBubbleReadMs = bubbleSw.elapsedMilliseconds;
                        }
                        if (decodeTotalSw != null) {
                          _perfLog(
                            'decode cornerSearch=${decodeCornerSearchMs}ms warp=${decodeWarpMs}ms '
                            'warpVerify=${decodeWarpVerifyMs}ms mesh=${decodeMeshMs}ms(${mesh.verdict.name}) '
                            'illum=${decodeIllumMs}ms '
                            'bilateral=${decodeBilateralMs}ms clahe=${decodeClaheMs}ms '
                            'threshold=${decodeThresholdMs}ms bubbleRead=${decodeBubbleReadMs}ms '
                            'total=${decodeTotalSw.elapsedMilliseconds}ms',
                          );
                        }
                        // The review/overlay image uses the exact
                        // perspective transform already fitted above —
                        // the viewer applies the persisted mesh to
                        // overlays, just as _measureBubbleInk does to
                        // sampling (see ScannedImageViewerScreen). TAT
                        // writes `warped` itself (grayscale, already
                        // computed for bubble sampling — unchanged
                        // behavior). Every other exam (2026-09-19,
                        // previously handled by a fully separate
                        // `rectifyForOverlay` call that re-read the file
                        // and re-ran its own independent corner search)
                        // instead warps the ORIGINAL COLOR `src` through
                        // this SAME `transform` — one extra warpPerspective
                        // call (cheap: reuses an already-fitted transform,
                        // no new search), not a second corner detection —
                        // preserving the color review image AT/QTM staff
                        // already see, without the duplicate registration
                        // work or its risk of landing on a different
                        // (contradictory) quad than the one bubbles were
                        // actually scored against.
                        if (rectifiedOutputPath != null) {
                          if (template.examCode == 'TAT') {
                            try {
                              cv.imwrite(rectifiedOutputPath, warped);
                            } catch (_) {
                              // A display-image failure must not lose a scan.
                            }
                          } else {
                            final orientedSrc =
                                rotationCode == null ? src : cv.rotate(src, rotationCode);
                            try {
                              final warpedColor = cv.warpPerspective(
                                orientedSrc, transform, (canonicalWidth, canonicalHeight));
                              try {
                                cv.imwrite(rectifiedOutputPath, warpedColor);
                              } catch (_) {
                                // A display-image failure must not lose a scan.
                              } finally {
                                warpedColor.dispose();
                              }
                            } finally {
                              if (!identical(orientedSrc, src)) orientedSrc.dispose();
                            }
                          }
                        }
                        return OmrScanResult(
                          examCode: result.examCode,
                          items: result.items,
                          templateVersion: template.templateVersion,
                          meshInteriorMeasuredFrac: mesh.verdict == OmrMeshVerdict.notApplicable
                              ? null
                              : mesh.toMeasuredFractions(canonicalWidth, canonicalHeight),
                          meshVerdict: mesh.verdict.name,
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
    final src = _imreadForTemplate(imagePath, template);
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
  /// [middleNameFieldRect]) directly out of [imagePath] — the original
  /// captured photo, not a rectified/display copy — so staff can read the
  /// handwritten name and enter it manually (see showExamineeDialog); this
  /// app does not attempt automatic handwriting recognition. Runs its own
  /// corner search and perspective warp at [_ocrCanonicalPxPerPt] (much
  /// higher than [rectifyForOverlay]'s [_canonicalPxPerPt]) so the crop has
  /// enough real pixels to be legible — see [_ocrCanonicalPxPerPt]'s doc
  /// comment for why a shared low-res rectified copy wasn't good enough.
  /// Purely a display input, same isolation as [rectifyForOverlay]: its own
  /// `imread`/corner search/warp, sharing no Mat or intermediate value with
  /// [decode] or [rectifyForOverlay] — never touches scoring. Returns all
  /// three written paths, or null if the sheet's corners couldn't be found
  /// in this photo.
  ({String lastName, String firstName, String middleName})? cropNameFields(
    String imagePath,
    OmrExamTemplate template, {
    required String lastNameOutPath,
    required String firstNameOutPath,
    required String middleNameOutPath,
  }) {
    final src = _imreadForTemplate(imagePath, template);
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
            final srcCorners = cv.VecPoint2f.fromList(corners);
            try {
              // Mesh detection needs the interior fiducials found
              // somewhere on a warped page, but not at this method's much
              // higher OCR resolution — reuse [_canonicalPxPerPt] (the
              // same small canonical scale `decode()` itself builds its
              // own mesh at) on `oriented` (already grayscale, no extra
              // cvtColor needed) instead of warping a whole page at
              // [_ocrCanonicalPxPerPt] just to search for a handful of
              // small printed squares. 2026-09-19: this used to warp the
              // FULL page in color at 6px/pt (≈54-62MB for a typical exam
              // page) purely to extract ~0.3% of it per field; see the
              // direct field-region warp below for the other half of that
              // fix.
              final meshWidth = (template.pageWidthPt * _canonicalPxPerPt).round();
              final meshHeight = (template.pageHeightPt * _canonicalPxPerPt).round();
              final meshDstCorners = cv.VecPoint2f.fromList([
                for (final corner in template.cornerMarkers)
                  cv.Point2f(corner.xFrac * meshWidth, corner.yFrac * meshHeight),
              ]);
              final OmrMeshCorrection mesh;
              try {
                final meshTransform = cv.getPerspectiveTransform2f(srcCorners, meshDstCorners);
                try {
                  final meshWarped = cv.warpPerspective(oriented, meshTransform, (meshWidth, meshHeight));
                  try {
                    // TAT's new references bracket answers, not
                    // handwriting. Preserve its existing global-only name
                    // crop mapping.
                    final interiorMeasuredSmall = template.examCode == 'TAT'
                        ? <OmrFiducialRole, (double, double)>{}
                        : _detectInteriorFiducials(meshWarped, template, meshWidth, meshHeight);
                    // Rescale from the small detection resolution up to
                    // this method's own OCR canonical scale —
                    // OmrMeshCorrection operates in whatever pixel space
                    // it's built with, and a measured canonical position
                    // scales linearly between the two (both describe the
                    // same warped page, just sampled at a different
                    // density).
                    final ocrScale = _ocrCanonicalPxPerPt / _canonicalPxPerPt;
                    final interiorMeasured = {
                      for (final entry in interiorMeasuredSmall.entries)
                        entry.key: (entry.value.$1 * ocrScale, entry.value.$2 * ocrScale),
                    };
                    mesh = OmrMeshCorrection.build(
                      template: template,
                      canonicalWidth: canonicalWidth,
                      canonicalHeight: canonicalHeight,
                      cornersMeasuredPx: [
                        for (final c in template.cornerMarkers)
                          (c.xFrac * canonicalWidth, c.yFrac * canonicalHeight),
                      ],
                      interiorMeasuredPx: interiorMeasured,
                    );
                  } finally {
                    meshWarped.dispose();
                  }
                } finally {
                  meshTransform.dispose();
                }
              } finally {
                meshDstCorners.dispose();
              }
              // Direct field-region warp (2026-09-19): each field's own
              // small output rectangle is warped straight from
              // `orientedSrc` (the original capture) by shifting the SAME
              // page-wide destination correspondence (`corners` ->
              // template.cornerMarkers' canonical positions) so the
              // field's own top-left lands at (0,0) of a field-sized
              // output — the identical global 4-corner registration used
              // everywhere else, just queried for a small output window
              // instead of the whole page. `warpPerspective` only samples
              // the source pixels its requested output window actually
              // needs, so this does the same real per-field work as
              // before without ever allocating a full-page intermediate.
              void writeField(OmrFieldRect field, String outPath, int boxCount) {
                // Mesh-correct all 4 corners of the field rect (not just
                // its center) and take their bounding box — a locally
                // bent capture can skew the rect into a non-axis-aligned
                // quad, and the crop must stay a rectangle; the bounding
                // box only ever grows the crop slightly, never loses
                // handwriting at an edge. A no-op whenever
                // `mesh.isActive` is false.
                final x0 = field.xFrac * canonicalWidth;
                final y0 = field.yFrac * canonicalHeight;
                final x1 = (field.xFrac + field.widthFrac) * canonicalWidth;
                final y1 = (field.yFrac + field.heightFrac) * canonicalHeight;
                final corrected = [
                  mesh.correct(x0, y0),
                  mesh.correct(x1, y0),
                  mesh.correct(x0, y1),
                  mesh.correct(x1, y1),
                ];
                final rect = _clampedRect(
                  corrected.map((p) => p.$1).reduce(math.min),
                  corrected.map((p) => p.$2).reduce(math.min),
                  corrected.map((p) => p.$1).reduce(math.max),
                  corrected.map((p) => p.$2).reduce(math.max),
                  canonicalWidth,
                  canonicalHeight,
                );
                final dstCornersLocal = cv.VecPoint2f.fromList([
                  for (final corner in template.cornerMarkers)
                    cv.Point2f(
                      corner.xFrac * canonicalWidth - rect.x,
                      corner.yFrac * canonicalHeight - rect.y,
                    ),
                ]);
                final cv.Mat roi;
                try {
                  final transformLocal = cv.getPerspectiveTransform2f(srcCorners, dstCornersLocal);
                  try {
                    roi = cv.warpPerspective(orientedSrc, transformLocal, (rect.width, rect.height));
                  } finally {
                    transformLocal.dispose();
                  }
                } finally {
                  dstCornersLocal.dispose();
                }
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
                      // Trim trailing blank cells so a short name in a
                      // wide, mostly-empty field (e.g. 7 letters in a
                      // 24-cell Last Name field) doesn't produce an image
                      // that's mostly blank paper — confirmed on a real
                      // device this made the crop strip badly out of
                      // proportion with narrower fields (MI) next to it.
                      // A no-op (identical Mat) for `boxCount <= 0` (TAT's
                      // un-boxed fields) or a field with nothing detected
                      // to trim to. See _trimNameCropToContent's own doc
                      // comment for why this only ever removes guaranteed-
                      // blank trailing space, never any handwriting.
                      final trimmed = boxCount > 0
                          ? _trimNameCropToContent(grayRoi, roi.width, roi.height, boxCount)
                          : grayRoi;
                      try {
                        // CLAHE re-normalizes local contrast (same
                        // technique used before thresholding for bubble
                        // detection) so a crop taken in poor/uneven
                        // lighting stays legible to a human reader; a
                        // light blur afterward tamps down the noise CLAHE
                        // can amplify in an otherwise near-blank paper
                        // region. Otherwise left unmodified (printed grid
                        // lines and all) — this image is read directly by
                        // staff, not fed to a recognizer, so within
                        // whatever width is kept it must be a complete,
                        // un-altered record of exactly what was
                        // handwritten.
                        final clahe = cv.createCLAHE(clipLimit: 3, tileGridSize: (4, 4));
                        try {
                          final enhanced = clahe.apply(trimmed);
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
                        if (!identical(trimmed, grayRoi)) trimmed.dispose();
                      }
                    } finally {
                      grayRoi.dispose();
                    }
                  } finally {
                    roi.dispose();
                  }
                }

              writeField(template.lastNameFieldRect, lastNameOutPath, template.lastNameBoxCount);
              writeField(template.firstNameFieldRect, firstNameOutPath, template.firstNameBoxCount);
              writeField(template.middleNameFieldRect, middleNameOutPath, template.middleNameBoxCount);
              return (
                lastName: lastNameOutPath,
                firstName: firstNameOutPath,
                middleName: middleNameOutPath,
              );
            } finally {
              srcCorners.dispose();
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

  /// How many extra letter cells past the last one classified as
  /// containing ink to keep before trimming a name crop — deliberately
  /// generous. This value only ever controls how much *extra blank space*
  /// survives the trim; it can never cause real handwriting to be dropped
  /// from the saved image, since everything to the left of the trim point
  /// (ink or not) is always kept intact. A margin this size comfortably
  /// covers the worst per-cell misclassification gap actually observed on
  /// a real capture this session (a 2-cell run of faint ink misread as
  /// blank from an uneven lighting gradient — see [_lastInkCellIndex]'s
  /// own doc comment) with real room to spare, since under-trimming only
  /// costs a little unused width while over-trimming would cut off a
  /// letter.
  static const int _nameCropTrimBufferCells = 5;

  /// How much darker (0-255 gray levels) a cell's own mean brightness must
  /// be than the brightest cell in a local window around it (see
  /// [_nameCropBaselineWindowRadius]) to count as containing handwriting —
  /// the same self-calibrating, gradient-tolerant approach validated
  /// earlier this session for the (now-removed) OCR line-reconstruction
  /// step. Reused here for a much lower-stakes purpose: finding *how far*
  /// real handwriting extends across the field, not classifying or
  /// dropping any individual cell, so a misclassified cell here only
  /// shifts the trim point slightly rather than removing content.
  static const double _nameCropInkDrop = 12.0;

  /// See [_nameCropInkDrop] — window radius for its local brightest-cell
  /// baseline, same value and same reasoning as the earlier OCR
  /// reconstruction step.
  static const int _nameCropBaselineWindowRadius = 6;

  /// Index (0-based) of the last letter cell across [boxCount] that
  /// appears to contain handwriting, judged by comparing each cell's mean
  /// brightness against the brightest cell in a local window around it
  /// (see [_nameCropInkDrop]/[_nameCropBaselineWindowRadius]) — tolerant of
  /// a lighting/shadow gradient across the field, unlike a single
  /// field-wide brightness reference. Returns null when nothing in the
  /// field reads as ink (a blank field — the caller keeps the full crop
  /// rather than trimming to nothing).
  static int? _lastInkCellIndex(cv.Mat gray, int width, int height, int boxCount) {
    final cellWidth = width / boxCount;
    final cellMeans = <double>[];
    for (var i = 0; i < boxCount; i++) {
      final x0 = (i * cellWidth).round().clamp(0, width - 1);
      final x1 = ((i + 1) * cellWidth).round().clamp(x0 + 1, width);
      final cell = gray.region(cv.Rect(x0, 0, x1 - x0, height));
      try {
        final meanScalar = cell.mean();
        try {
          cellMeans.add(meanScalar.val1);
        } finally {
          meanScalar.dispose();
        }
      } finally {
        cell.dispose();
      }
    }
    int? lastInk;
    for (var i = 0; i < boxCount; i++) {
      final lo = math.max(0, i - _nameCropBaselineWindowRadius);
      final hi = math.min(boxCount - 1, i + _nameCropBaselineWindowRadius);
      var baseline = cellMeans[lo];
      for (var j = lo + 1; j <= hi; j++) {
        if (cellMeans[j] > baseline) baseline = cellMeans[j];
      }
      if ((baseline - cellMeans[i]) >= _nameCropInkDrop) lastInk = i;
    }
    if (_kFiducialDebug) {
      _fidLog('nameCropTrim boxCount=$boxCount means=${cellMeans.map((m) => m.toStringAsFixed(1)).toList()} '
          'lastInk=$lastInk');
    }
    return lastInk;
  }

  /// Trims [gray] (a cropped, un-warped name field, [width]x[height]) down
  /// to just past where handwriting actually ends, so a short name in a
  /// wide field doesn't produce an image that's mostly blank paper. Keeps
  /// every cell from the start of the field through
  /// [_lastInkCellIndex] plus [_nameCropTrimBufferCells] extra cells of
  /// margin, and always returns [gray] unchanged (identical) rather than
  /// trim — when the field reads as entirely blank ([_lastInkCellIndex]
  /// returns null), or when the computed trim point would keep the whole
  /// field anyway — callers must check `identical()` before disposing,
  /// same convention as [_normalizeIllumination].
  static cv.Mat _trimNameCropToContent(cv.Mat gray, int width, int height, int boxCount) {
    final lastInk = _lastInkCellIndex(gray, width, height, boxCount);
    if (lastInk == null) {
      if (_kFiducialDebug) {
        _fidLog('nameCropTrim boxCount=$boxCount width=$width height=$height -> blank field, no trim');
      }
      return gray;
    }
    final cellWidth = width / boxCount;
    final keepCells = (lastInk + 1 + _nameCropTrimBufferCells).clamp(1, boxCount);
    if (keepCells >= boxCount) {
      if (_kFiducialDebug) {
        _fidLog('nameCropTrim boxCount=$boxCount width=$width keepCells=$keepCells -> '
            'no trim (would keep whole field)');
      }
      return gray;
    }
    final trimWidth = (keepCells * cellWidth).round().clamp(1, width);
    if (_kFiducialDebug) {
      _fidLog('nameCropTrim boxCount=$boxCount width=$width height=$height keepCells=$keepCells '
          'trimWidth=$trimWidth');
    }
    return gray.region(cv.Rect(0, 0, trimWidth, height));
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
    final debugVizSw = _kPerfDebug ? (Stopwatch()..start()) : null;
    final src = _imreadForTemplate(imagePath, template);
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
          if (debugVizSw != null) {
            _perfLog(
              'debugViz pageIndex=$pageIndex FAILED total=${debugVizSw.elapsedMilliseconds}ms',
            );
          }
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
                // Expected marker position (magenta crosshair) — the exact
                // point every candidate in this corner's search was scored
                // against (see [_QuadrantSearch.anchorX]/`anchorY`),
                // distinct from the Stage-1 box itself (which can get
                // clamped at the image edge).
                final (ax, ay) = refine.anchors[i];
                final axi = ax.round(), ayi = ay.round();
                cv.line(cornersDebug, cv.Point(axi - 12, ayi), cv.Point(axi + 12, ayi),
                    cv.Scalar(255, 0, 255), thickness: 2);
                cv.line(cornersDebug, cv.Point(axi, ayi - 12), cv.Point(axi, ayi + 12),
                    cv.Scalar(255, 0, 255), thickness: 2);
                // Every candidate this corner rejected — orange, sized by
                // how highly it scored, so a near-miss (a bubble that
                // almost won) stands out from obvious clutter. Label
                // carries every metric requested for diagnosing a failed
                // corner: reason, squareness, area, contrast.
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
                    '${r.reason} sq=${r.squareness.toStringAsFixed(2)} '
                    'a=${r.area.toStringAsFixed(0)} '
                    '${r.bboxGlobal.width}x${r.bboxGlobal.height} '
                    'c=${r.contrast.toStringAsFixed(1)}',
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
              // The homography quad itself — connecting the 4 accepted
              // corners in true perimeter order (TL,TR,BR,BL is a
              // perimeter walk; index order [tl,tr,bl,br] is not), distinct
              // in color (magenta) from the individual accept/reject
              // markers above so the actual quad shape fed into
              // getPerspectiveTransform2f is visible at a glance.
              const perimeterOrder = [0, 1, 3, 2];
              for (var i = 0; i < perimeterOrder.length; i++) {
                final a = corners[perimeterOrder[i]];
                final b = corners[perimeterOrder[(i + 1) % perimeterOrder.length]];
                cv.line(
                  cornersDebug,
                  cv.Point(a.x.round(), a.y.round()),
                  cv.Point(b.x.round(), b.y.round()),
                  cv.Scalar(255, 0, 255),
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
              // Computed from warpedGray (before any of the color drawing
              // below) so the grid.jpg overlay can show exactly what
              // decode()/locateCorners() would see: where each fiducial was
              // expected after correction, where it was actually
              // re-detected, and the resulting per-corner pixel error. See
              // [_verifyWarpedCorners]'s doc comment for why re-detection
              // (not re-projecting the same 4 source points) is the only
              // meaningful post-warp check.
              final warpVerification = _verifyWarpedCorners(
                warpedGray,
                template,
                canonicalWidth,
                canonicalHeight,
              );
              final warpClassified = _classifyWarpVerification(
                warpVerification,
                refine.confidence,
              );

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
                const warpCornerLabels = ['TL', 'TR', 'BL', 'BR'];
                for (var i = 0; i < 4; i++) {
                  final e = warpVerification.expected[i];
                  final r = warpVerification.redetected[i];
                  final err = warpVerification.errorPx[i];
                  // Expected canonical position — magenta crosshair, always
                  // drawn even when nothing was re-detected there.
                  final ex = e.x.round(), ey = e.y.round();
                  cv.line(warped, cv.Point(ex - 10, ey), cv.Point(ex + 10, ey),
                      cv.Scalar(255, 0, 255), thickness: 2);
                  cv.line(warped, cv.Point(ex, ey - 10), cv.Point(ex, ey + 10),
                      cv.Scalar(255, 0, 255), thickness: 2);
                  // Error-tier color: green within tolerance, amber past
                  // _warpWarnPx, red past _warpRejectPx (or not found).
                  final errColor = err > _warpRejectPx
                      ? cv.Scalar(0, 0, 255)
                      : err > _warpWarnPx
                          ? cv.Scalar(0, 200, 255)
                          : cv.Scalar(0, 255, 0);
                  if (r != null) {
                    final rx = r.x.round(), ry = r.y.round();
                    cv.circle(warped, cv.Point(rx, ry), 8, errColor,
                        thickness: 2);
                    cv.line(warped, cv.Point(ex, ey), cv.Point(rx, ry),
                        errColor, thickness: 1);
                  }
                  final label = err.isInfinite
                      ? '${warpCornerLabels[i]} not found'
                      // Plain ASCII — cv.FONT_HERSHEY_SIMPLEX has no glyph
                      // for "Δ" and silently renders it as "??" (confirmed
                      // against a real device capture).
                      : '${warpCornerLabels[i]} err=${err.toStringAsFixed(1)}px';
                  cv.putText(
                    warped,
                    label,
                    cv.Point(ex + 14, ey + 14),
                    cv.FONT_HERSHEY_SIMPLEX,
                    0.5,
                    errColor,
                    thickness: 1,
                  );
                }
                final verdictLabel = warpClassified.ok
                    ? (warpClassified.degraded
                        ? 'post-warp: within tolerance but degraded (max ${warpClassified.maxErrorPx.toStringAsFixed(1)}px)'
                        : 'post-warp: OK (max ${warpClassified.maxErrorPx.toStringAsFixed(1)}px)')
                    : 'post-warp: REJECTED - ${warpClassified.message}';
                cv.putText(
                  warped,
                  verdictLabel,
                  cv.Point(20, warped.height - 20),
                  cv.FONT_HERSHEY_SIMPLEX,
                  0.5,
                  warpClassified.ok
                      ? (warpClassified.degraded
                          ? cv.Scalar(0, 200, 255)
                          : cv.Scalar(0, 255, 0))
                      : cv.Scalar(0, 0, 255),
                  thickness: 1,
                );
                cv.imwrite('$outputDir/sheet${pageIndex}_grid.jpg', warped);
              } finally {
                warped.dispose();
              }

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
                          _adaptiveThresholdBlockSizeFor(template.examCode),
                          _adaptiveThresholdCFor(_adaptiveThresholdC, warpedGrayBrightness),
                        );
                        try {
                          cv.imwrite(
                            '$outputDir/sheet${pageIndex}_inkmap.jpg',
                            inkMap,
                          );
                          if (debugVizSw != null) {
                            _perfLog(
                              'debugViz pageIndex=$pageIndex total=${debugVizSw.elapsedMilliseconds}ms',
                            );
                          }
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
      final stage1Result = _findMarkerInRegion(
        gray, s.stage1, s.anchorX, s.anchorY,
        debugTag: tag,
        anchorScaleOverride: s.stage1AnchorScale,
      );
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

    // Stage 4: geometric cross-check + promotion + dedicated rescue search
    // (see [_crossCheckCornersByGeometry]). Needs 3 points to fit a
    // transform through -- prefer confident corners to seed it, but fall
    // back to `low`-confidence ones when fewer than 3 are confident, rather
    // than skipping this whole stage.
    //
    // A `low` corner already cleared _findMarkerInRegion's own shape/
    // contrast/position filtering (it's real marker evidence, just not
    // strong enough for `confident`) -- a shadow or a finger near one
    // corner shouldn't cost the *other* corners their own cross-check too.
    // Confirmed on-device: a capture with only 2 confident corners (a
    // finger near two others) skipped this entire stage under the old
    // >=3-confident-only gate, so neither of the two `low` corners -- one
    // of which had actually locked onto the wrong feature -- was ever
    // cross-checked or rescued, producing an unusable warp with no
    // indication anything had gone wrong upstream of it.
    //
    // Only bother searching for extra (interior-fiducial) anchors when the
    // outer corners alone won't reach the 3-point minimum the affine fit
    // needs — the common case (3-4 outer corners usable) pays nothing
    // extra for TAT's additional printed marks.
    final usableOuterCount =
        results.where((r) => r.confidence != CornerConfidence.none).length;
    final extraAnchors = usableOuterCount < 3
        ? _findInteriorAnchorsRaw(gray, pageQuad, template)
        : const <({cv.Point2f point, double xFrac, double yFrac})>[];
    if (_kFiducialDebug && extraAnchors.isNotEmpty) {
      _fidLog('extra interior anchors found for corner rescue: '
          '${extraAnchors.map((a) => "(${a.xFrac.toStringAsFixed(2)},${a.yFrac.toStringAsFixed(2)})->"
              "(${a.point.x.toStringAsFixed(1)},${a.point.y.toStringAsFixed(1)})").join(" ")}');
    }
    final note = _crossCheckCornersByGeometry(
      points,
      results,
      gray,
      template,
      allowRescueSearch: true,
      labels: _kFiducialDebug ? labels : null,
      extraAnchors: extraAnchors,
    );

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
    _validateQuad(resolved);

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
      anchors: [for (final s in searches) (s.anchorX, s.anchorY)],
      rejectedPerCorner: [for (final r in results) r.rejected],
      note: note,
    );
  }

  /// Finds the sheet's 4 corners for a real captured photo, at whatever
  /// resolution the camera produced.
  ///
  /// For any capture whose long side exceeds [_liveCheckMaxDimension],
  /// this searches a downscaled copy FIRST — matching the exact scale the
  /// live preview already judged the sheet at — then refines each found
  /// corner's position with one small, full-resolution search around it.
  /// This split matters because [_findMarkerInRegion]'s blur/dilate
  /// kernels are fixed *absolute* pixel sizes (3x3): the same printed
  /// marker can score meaningfully differently at full capture resolution
  /// than it did in a downscaled live preview that just approved it as
  /// confident, since the kernel's smoothing effect relative to the
  /// marker's own on-screen size changes with resolution. Searching at
  /// the live preview's own scale keeps classification (which tier a
  /// corner gets) consistent with what the user already saw go green;
  /// the full-resolution refinement afterward keeps the actual centroid
  /// sharp enough for an accurate warp, rather than trading all precision
  /// away for that consistency.
  ///
  /// Previously this downscale-then-match-scale step only ran for QTM
  /// (`template.examCode == 'QTM'`) — confirmed by direct code review, not
  /// assumed, and confirmed on a real device (2026-09-14) that AT hit the
  /// identical mismatch this was built to prevent: all 4 live corners
  /// green, the saved capture still rejected as "Page not fully
  /// detected", because the full-resolution search the capture-time gate
  /// ran was judging the same marks by different shape metrics than the
  /// downscaled live search that had just approved them. There was
  /// nothing QTM-specific about the underlying cause, so this now applies
  /// uniformly to every exam whose capture resolution exceeds the live
  /// preview's own scale.
  _RefineResult _findCaptureCorners(cv.Mat gray, OmrExamTemplate template) {
    final longSide = math.max(gray.width, gray.height);
    if (longSide <= _liveCheckMaxDimension) {
      return _refineCorners(gray, template);
    }

    final scale = _liveCheckMaxDimension / longSide;
    final small = cv.resize(
      gray,
      ((gray.width * scale).round(), (gray.height * scale).round()),
      interpolation: cv.INTER_AREA,
    );
    try {
      final result = _refineCorners(small, template);
      final sx = gray.width / small.width;
      final sy = gray.height / small.height;
      // OpenCV resize maps pixel centers, while rectangle edges scale directly.
      double x(double value) => (value + 0.5) * sx - 0.5;
      double y(double value) => (value + 0.5) * sy - 0.5;
      cv.Rect rect(cv.Rect r) => _clampedRect(
        r.x * sx, r.y * sy, (r.x + r.width) * sx,
        (r.y + r.height) * sy, gray.width, gray.height,
      );

      // Full-resolution refinement: re-search a small box around each
      // rescaled centroid using the ORIGINAL pixels, for a sharper final
      // position. Only adopted when it's clearly the same blob (within
      // half the search box) and still real marker evidence -- this can
      // only sharpen WHERE a corner sits, never change WHICH tier
      // [_refineCorners] already decided for it at the consistent,
      // downscaled resolution.
      final refinedCorners = <cv.Point2f>[];
      for (var i = 0; i < result.corners.length; i++) {
        final p = result.corners[i];
        final rx = x(p.x.toDouble());
        final ry = y(p.y.toDouble());
        final pad = math.max(16.0, math.min(sx, sy) * 6);
        final box = _clampedRect(
          rx - pad, ry - pad, rx + pad, ry + pad, gray.width, gray.height,
        );
        final refined = _findMarkerInRegion(gray, box, rx, ry);
        final rc = refined.centroid;
        final sameBlob = rc != null &&
            refined.confidence != CornerConfidence.none &&
            (rc.x - rx).abs() <= pad / 2 &&
            (rc.y - ry).abs() <= pad / 2;
        refinedCorners.add(sameBlob ? rc : cv.Point2f(rx, ry));
      }

      return _RefineResult(
        corners: refinedCorners,
        confidence: result.confidence,
        verdict: result.verdict,
        stage1Regions: [for (final r in result.stage1Regions) rect(r)],
        anchors: [for (final a in result.anchors) (x(a.$1), y(a.$2))],
        rejectedPerCorner: [
          for (final rejected in result.rejectedPerCorner)
            [
              for (final r in rejected)
                _RejectedCandidate(
                  rect(r.bboxGlobal), r.squareness, r.score, r.reason,
                  area: r.area * sx * sy, contrast: r.contrast,
                ),
            ],
        ],
        note: result.note,
      );
    } finally {
      small.dispose();
    }
  }

  /// [_refineCorners], but tolerant of the sheet being rotated 90° in the
  /// photo — needed for a landscape-page template (currently only TAT)
  /// because the app's whole capture UI is locked to portrait (see
  /// main.dart's SystemChrome.setPreferredOrientations): the only way to
  /// get a landscape sheet to fill a portrait camera frame is to physically
  /// turn the paper sideways. _refineCorners on its own assumes the photo's
  /// own top-left/top-right/bottom-left/bottom-right quadrants directly
  /// contain the sheet's own same-named corner marks (see _quadrantsFor),
  /// which is only true when the sheet is upright in frame.
  ///
  /// Portrait-page templates never attempt a rotation at all — there's no
  /// ambiguity to resolve for them, and doing so would just be wasted work.
  ///
  /// TEMPORARY, 2026-09-18: back to trying all four quarter turns and
  /// picking the best-scoring one (the pre-existing, previously-working
  /// behavior), instead of assuming a single fixed rotation. A same-day
  /// attempt to lock TAT to one standardized physical placement (phone
  /// portrait, sheet turned so the title reads normally at the top and name
  /// fields are on the left — see docs/tat-portrait-capture.md) guessed
  /// [cv.ROTATE_90_COUNTERCLOCKWISE] as that placement's raw-buffer-to-
  /// canonical rotation, reasoning from the on-screen viewfinder guide's own
  /// `cornerFractions` transform plus one earlier device log. That guess was
  /// confirmed WRONG on a real device: a capture in exactly the standardized
  /// placement (title up, name fields left, all 4 outer corners found) was
  /// rejected. Reverted to this known-good multi-candidate search so
  /// scanning works again; once real `[OMR FIDUCIAL DEBUG] TAT orientation
  /// candidates=...` log data confirms which rotation code the standardized
  /// placement actually produces, the single-rotation optimization can be
  /// reapplied correctly instead of guessed again.
  ///
  /// Tries the image as captured first (correct for every portrait-page
  /// template, and for a landscape one shot without rotating, e.g. a flat
  /// overhead photo rather than the handheld portrait-frame case), then
  /// each 90° rotation, then 180°, returning whichever succeeds.
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
      final upright = _findCaptureCorners(gray, template);
      if (template.templateVersion != 'TAT-portrait-v5') return (gray, upright, null);
      return _resolveTatPortraitDirection(gray, upright, template);
    }
    // Cache each candidate's full corner-search result (2026-09-19) —
    // `_RefineResult` is plain value data (Point2f/Rect/enums/doubles, no
    // Mat), so holding all 4 costs nothing worth measuring. Previously the
    // winning candidate's corners were computed here, then thrown away and
    // recomputed a second time below via a fresh `_findCaptureCorners` call
    // after rotating `gray` again — the same expensive contour search
    // (Stage 1/Stage 2 blob search + squareness scoring across every
    // quadrant) run twice for whichever rotation turned out to be correct.
    // Only the (cheap) `cv.rotate` needs repeating, to hand back a live
    // Mat that isn't one of the (disposed) per-candidate scratch rotations.
    final candidates = <(int?, double)>[];
    final refineByCode = <int?, _RefineResult>{};
    for (final code in <int?>[
      null, cv.ROTATE_90_CLOCKWISE, cv.ROTATE_90_COUNTERCLOCKWISE,
      cv.ROTATE_180,
    ]) {
      final image = code == null ? gray : cv.rotate(gray, code);
      try {
        final refine = _findCaptureCorners(image, template);
        refineByCode[code] = refine;
        // Match the normal registration resolution: at 1 px/pt a 9pt
        // square is only nine pixels wide, making the fixed blur/dilation
        // and contour-extent gate disproportionately sensitive to rounding.
        final width = (template.pageWidthPt * _canonicalPxPerPt).round();
        final height = (template.pageHeightPt * _canonicalPxPerPt).round();
        final src = cv.VecPoint2f.fromList(refine.corners);
        final dst = cv.VecPoint2f.fromList([
          for (final c in template.cornerMarkers)
            cv.Point2f(c.xFrac * width, c.yFrac * height),
        ]);
        final transform = cv.getPerspectiveTransform2f(src, dst);
        try {
          final warped = cv.warpPerspective(image, transform, (width, height));
          try {
            final measured = _detectInteriorFiducials(warped, template, width, height);
            var score = 0.0;
            var above = 0;
            var below = 0;
            for (final f in template.interiorFiducials) {
              if (f.role == OmrFiducialRole.dividerLeft ||
                  f.role == OmrFiducialRole.dividerRight) {
                continue;
              }
              final point = measured[f.role];
              if (point == null) continue;
              final dx = (point.$1 - f.xFrac * width) * template.pageWidthPt / width;
              final dy = (point.$2 - f.yFrac * height) * template.pageHeightPt / height;
              final error = math.sqrt(dx * dx + dy * dy);
              if (error > 12) continue;
              score += 1 - error / 48;
              if (f.yFrac < 0.5) { above++; } else { below++; }
            }
            candidates.add((code, above >= 2 && below >= 2 ? score : 0));
            if (_kFiducialDebug) {
              _fidLog('TAT orientation rotation=$code size=${width}x$height '
                  'above=$above below=$below score=$score measured=$measured');
            }
          } finally {
            warped.dispose();
          }
        } finally {
          transform.dispose();
          src.dispose();
          dst.dispose();
        }
      } on StateError {
        candidates.add((code, 0));
      } finally {
        if (!identical(image, gray)) image.dispose();
      }
    }
    final selected = selectTatOrientation([for (final c in candidates) c.$2]);
    if (_kFiducialDebug) {
      _fidLog('TAT orientation candidates=$candidates selected=$selected');
    }
    if (selected == null) {
      throw StateError(
        'Could not confirm the sheet\'s placement. Hold the phone '
        'upright and turn the sheet so "TEACHING APTITUDE TEST (TAT)" '
        'reads normally at the top and the name fields are on the '
        'left, then retake.',
      );
    }
    final code = candidates[selected].$1;
    final image = code == null ? gray : cv.rotate(gray, code);
    try {
      return (image, refineByCode[code]!, code);
    } catch (_) {
      if (!identical(image, gray)) image.dispose();
      rethrow;
    }
  }

  /// Deliberately minimal, per explicit product direction: as long as all 4
  /// fiducial marks were found (see [_refineCorners]/[_findMarkerInRegion]'s
  /// own shape/contrast filtering, which is what actually decides "is this
  /// really one of the printed squares"), a real-world capture should be
  /// allowed through even with a shadow across part of the sheet, a hand
  /// holding it at an angle, or the sheet not perfectly flat — none of
  /// which change where the 4 marks actually are.
  ///
  /// This used to also reject on aggregate area/aspect/edge-margin, on one
  /// marker's own size/shape differing from the other three, and on the
  /// quad's side- and diagonal-length ratios — each individually reasonable
  /// as a defense against a wrong corner, but collectively strict enough
  /// that ordinary handheld conditions (shadow, tilt, an off-center grip)
  /// were being rejected more often than a genuinely bad corner was being
  /// caught. Only the two checks below remain: both are about whether a
  /// perspective transform can even be *computed* from these 4 points at
  /// all, not about how good the capture looks.
  void _validateQuad(List<cv.Point2f> corners) {
    final tl = corners[0], tr = corners[1], bl = corners[2], br = corners[3];

    if (tl.x >= tr.x || bl.x >= br.x || tl.y >= bl.y || tr.y >= br.y) {
      throw StateError(
        'The detected corner marks are not arranged like the sheet. Retake the photo with the sheet upright and all four corners visible.',
      );
    }

    // Convexity: `corners` is [tl, tr, bl, br] (index order), which is NOT
    // a perimeter walk — feeding it straight into a convexity test would
    // produce a self-intersecting "bowtie" for every normal quad, not the
    // true shape. Build the actual clockwise perimeter first. A
    // self-intersecting quad has no sane perspective transform at all
    // (getPerspectiveTransform2f would fit *something*, but it wouldn't
    // mean anything), so this one stays a hard rejection.
    final perimeter = cv.VecPoint2f.fromList([tl, tr, br, bl]);
    try {
      if (!cv.isContourConvex2f(perimeter)) {
        throw StateError(
          "The four corner marks don't form a simple, flat rectangle — one appears crossed over relative to the others. Retake with the sheet flat and all four corners visible.",
        );
      }
    } finally {
      perimeter.dispose();
    }
  }

  /// Independently re-detects each of the 4 fiducial markers directly on
  /// [warpedGray] (an already-rectified image), in a small box around each
  /// one's expected canonical position, and measures how far the fresh
  /// re-detection landed from that expected position.
  ///
  /// This is the only meaningful post-warp check: `getPerspectiveTransform2f`
  /// on exactly 4 points is an exact solve, so re-projecting the same 4
  /// source points through the fitted transform back onto their targets is
  /// trivially perfect and would prove nothing. If the *original* detection
  /// was actually on the wrong feature (a bubble corner near the true mark,
  /// or a point subtly displaced by steep-angle perspective distortion),
  /// warping fixes that wrong point onto its target exactly — but the rest
  /// of the page (including where the true fiducial actually ends up) does
  /// not correspondingly land correctly. Re-detecting fresh here can reveal
  /// that.
  _WarpVerification _verifyWarpedCorners(
    cv.Mat warpedGray,
    OmrExamTemplate template,
    int canonicalWidth,
    int canonicalHeight,
  ) {
    final expected = [
      for (final c in template.cornerMarkers)
        cv.Point2f(c.xFrac * canonicalWidth, c.yFrac * canonicalHeight),
    ];
    final redetected = <cv.Point2f?>[];
    final errors = <double>[];
    final confidences = <CornerConfidence>[];
    cv.Mat? normalizedGray;
    try {
      for (final e in expected) {
        final box = _clampedRect(
          e.x - _postWarpSearchHalfExtentPx,
          e.y - _postWarpSearchHalfExtentPx,
          e.x + _postWarpSearchHalfExtentPx,
          e.y + _postWarpSearchHalfExtentPx,
          canonicalWidth,
          canonicalHeight,
        );
        var r = _findMarkerInRegion(warpedGray, box, e.x, e.y);
        // A missing marker can be a lighting failure, not a displaced corner.
        // Normalize once on demand; keep detected offsets and all acceptance gates.
        if (r.centroid == null) {
          normalizedGray ??= _normalizeIllumination(warpedGray);
          if (!identical(normalizedGray, warpedGray)) {
            r = _findMarkerInRegion(normalizedGray, box, e.x, e.y);
          }
        }
        final c = r.centroid;
        redetected.add(c);
        confidences.add(r.confidence);
        errors.add(
          c == null
              ? double.infinity
              : math.sqrt(math.pow(c.x - e.x, 2) + math.pow(c.y - e.y, 2)),
        );
      }
    } finally {
      if (normalizedGray != null && !identical(normalizedGray, warpedGray)) {
        normalizedGray.dispose();
      }
    }
    return _WarpVerification(
      expected: expected,
      redetected: redetected,
      errorPx: errors,
      confidence: confidences,
    );
  }

  /// Search half-extent (canonical px) for one interior fiducial, scaled
  /// off its own printed half-size rather than reusing the 4 main
  /// corners' fixed [_postWarpSearchHalfExtentPx] — a redesigned sheet's
  /// interior marks are noticeably smaller (see
  /// [OmrFiducial.halfSizePt]/`kAtCenterMarkerHalf`) and sit inside dense
  /// bubble-grid content, so a search box sized off the *corner* marker
  /// would both waste search area and raise the odds of latching onto a
  /// nearby bubble/text glyph instead of the intended smaller square.
  /// Still comfortably larger than the mark itself, matching the same
  /// generous-relative-to-marker-size margin [_postWarpSearchHalfExtentPx]
  /// already gives the (larger) corner markers.
  static double _interiorSearchHalfExtentPx(double halfSizePt) =>
      math.max(14.0, halfSizePt * _canonicalPxPerPt * 2.5);

  /// How well the small marks of a portrait TAT v5 sheet line up in [image]
  /// warped by [refine]'s corners: how many were found within 12pt of their
  /// printed position, and their summed closeness. The side pair and centre
  /// mark look the same turned around, so they say nothing about direction and
  /// are skipped.
  ({int count, double score}) _tatSmallMarkEvidence(
    cv.Mat image,
    _RefineResult refine,
    OmrExamTemplate template,
  ) {
    final width = (template.pageWidthPt * _canonicalPxPerPt).round();
    final height = (template.pageHeightPt * _canonicalPxPerPt).round();
    final src = cv.VecPoint2f.fromList(refine.corners);
    final dst = cv.VecPoint2f.fromList([
      for (final c in template.cornerMarkers) cv.Point2f(c.xFrac * width, c.yFrac * height),
    ]);
    try {
      final transform = cv.getPerspectiveTransform2f(src, dst);
      try {
        final warped = cv.warpPerspective(image, transform, (width, height));
        try {
          final small = [for (final f in template.interiorFiducials) if (f.halfSizePt < 4) f];
          final measured = _detectInteriorFiducials(warped, template, width, height, only: small);
          var count = 0;
          var score = 0.0;
          for (final f in small) {
            final point = measured[f.role];
            if (point == null) continue;
            final dx = (point.$1 - f.xFrac * width) * template.pageWidthPt / width;
            final dy = (point.$2 - f.yFrac * height) * template.pageHeightPt / height;
            final error = math.sqrt(dx * dx + dy * dy);
            if (error > 12) continue;
            count++;
            score += 1 - error / 48;
          }
          return (count: count, score: score);
        } finally {
          warped.dispose();
        }
      } finally {
        transform.dispose();
      }
    } finally {
      src.dispose();
      dst.dispose();
    }
  }

  /// Portrait TAT v5 is held upright in the portrait-locked camera, so only
  /// two states are possible: the sheet as shot, or turned 180 degrees. The
  /// four corner squares look identical either way, so direction comes from
  /// the seven small marks. A sheet already the right way up is accepted after
  /// one look (4+ small marks); the 180 degree search only runs when that
  /// look is weak, keeping the common case cheap on older phones.
  (cv.Mat, _RefineResult, int?) _resolveTatPortraitDirection(
    cv.Mat gray,
    _RefineResult upright,
    OmrExamTemplate template,
  ) {
    final asShot = _tatSmallMarkEvidence(gray, upright, template);
    if (asShot.count >= 4) return (gray, upright, null);

    var turnedEvidence = (count: 0, score: 0.0);
    final turned = cv.rotate(gray, cv.ROTATE_180);
    try {
      _RefineResult? turnedRefine;
      try {
        turnedRefine = _findCaptureCorners(turned, template);
        turnedEvidence = _tatSmallMarkEvidence(turned, turnedRefine, template);
      } on StateError {
        // Turned reading has no usable corners: as shot is the only candidate.
      }
      final selected = selectTatPortraitDirection(
        asShotCount: asShot.count,
        asShotScore: asShot.score,
        turnedCount: turnedEvidence.count,
        turnedScore: turnedEvidence.score,
      );
      if (_kFiducialDebug) {
        _fidLog('TAT portrait direction asShot=$asShot turned=$turnedEvidence selected=$selected');
      }
      if (selected == 0) {
        turned.dispose();
        return (gray, upright, null);
      }
      if (selected == 1 && turnedRefine != null) return (turned, turnedRefine, cv.ROTATE_180);
    } catch (_) {
      turned.dispose();
      rethrow;
    }
    turned.dispose();
    throw StateError(
      asShot.count == 0 && turnedEvidence.count == 0
          ? 'Could not match the small alignment squares on the TAT sheet, so its '
              'direction is unknown. Hold the phone upright with the whole sheet in '
              'frame (title on the right edge), use even lighting, tap to focus, and retake.'
          : 'The TAT sheet direction is unclear. Keep every small square above the '
              'answer sections visible, hold the phone steady and upright, and retake.',
    );
  }

  /// Independently re-detects every one of [template]'s
  /// [OmrExamTemplate.interiorFiducials] directly on the already
  /// (4-corner-)warped [warpedGray] — the exact same "search a box around
  /// the known canonical position" technique [_verifyWarpedCorners] uses
  /// for the 4 main corners, just against each interior mark's own
  /// (smaller) expected size. A mark that isn't confidently found here
  /// simply has no entry in the result map — [OmrMeshCorrection.build]
  /// treats a missing entry as "no local evidence at that point," never as
  /// a hard failure (see its own doc comment on [OmrMeshVerdict]).
  /// No-op (returns an empty map immediately) for a template with no
  /// interior fiducials, so this costs nothing for legacy sheets/TAT.
  Map<OmrFiducialRole, (double, double)> _detectInteriorFiducials(
    cv.Mat warpedGray,
    OmrExamTemplate template,
    int canonicalWidth,
    int canonicalHeight, {
    Iterable<OmrFiducial>? only,
  }) {
    if (template.interiorFiducials.isEmpty) return const {};
    final found = <OmrFiducialRole, (double, double)>{};
    final tat = template.examCode == 'TAT';
    final scale = canonicalWidth / template.pageWidthPt;
    cv.Mat? normalizedGray;
    try {
      for (final fiducial in only ?? template.interiorFiducials) {
        final ex = fiducial.xFrac * canonicalWidth;
        final ey = fiducial.yFrac * canonicalHeight;
        final halfExtent = tat
            ? (fiducial.halfSizePt + 14) * scale
            : _interiorSearchHalfExtentPx(fiducial.halfSizePt);
        final box = _clampedRect(
          ex - halfExtent,
          ey - halfExtent,
          ex + halfExtent,
          ey + halfExtent,
          canonicalWidth,
          canonicalHeight,
        );
        var r = _findMarkerInRegion(warpedGray, box, ex, ey,
            expectedSidePx: tat ? 2 * fiducial.halfSizePt * scale : null);
        if (r.centroid == null) {
          normalizedGray ??= _normalizeIllumination(warpedGray);
          if (!identical(normalizedGray, warpedGray)) {
            r = _findMarkerInRegion(normalizedGray, box, ex, ey,
                expectedSidePx: tat ? 2 * fiducial.halfSizePt * scale : null);
          }
        }
        final c = r.centroid;
        if (c != null && r.confidence != CornerConfidence.none) {
          found[fiducial.role] = (c.x, c.y);
        }
      }
    } finally {
      if (normalizedGray != null && !identical(normalizedGray, warpedGray)) {
        normalizedGray.dispose();
      }
    }
    return found;
  }

  /// Turns a [_WarpVerification] into a pass/warn/reject verdict, checking
  /// every corner independently rather than only the single worst one —
  /// confirmed by direct code review that the previous version could let
  /// one corner's real, measured misalignment slide through unexamined
  /// whenever a DIFFERENT corner happened to have the single largest
  /// error and was confident pre-warp: the whole check only ever looked
  /// at `errorPx.reduce(max)`, so a second corner sitting just under that
  /// max but still well past [_warpRejectPx] was never even considered.
  ///
  /// Also distinguishes two different kinds of "bad" post-warp reading,
  /// which are not the same evidence:
  ///  * **inconclusive** — nothing was found at all in the post-warp
  ///    search box ([_WarpVerification.redetected] is null there;
  ///    `errorPx` is infinite). This proves nothing by itself (shadow,
  ///    glare, a steep angle can all hide a real mark that's still
  ///    exactly where it should be) — [preWarpConfidence] (the same
  ///    corner's confidence from *before* the warp) is what decides
  ///    whether this blocks: a corner that was [CornerConfidence.confident]
  ///    pre-warp but merely hard to re-detect post-warp never blocks, per
  ///    explicit product direction (see [_validateQuad]'s doc comment for
  ///    the same reasoning pre-warp) — a real mark that was genuinely
  ///    found shouldn't be second-guessed just because a second,
  ///    independent look came back inconclusive. A corner that *wasn't*
  ///    confidently found pre-warp too is a genuine double failure, not
  ///    an occlusion artifact — confirmed on-device: a rescued TAT corner
  ///    that had actually locked onto a false feature (a cluster of
  ///    filled bubbles, not the real mark) produced exactly this pattern
  ///    and warped the whole sheet unusably, with nothing catching it
  ///    once this check was made unconditionally non-blocking.
  ///  * **measured** — a real candidate WAS found post-warp, just too far
  ///    (>[_warpRejectPx]) from where the homography says it must land.
  ///    This is positive, direct evidence the correction is wrong, not an
  ///    absence of evidence — it blocks regardless of how confidently
  ///    that same corner was found pre-warp, since pre-warp confidence
  ///    only ever spoke to whether a real square was *there*, never to
  ///    whether the *homography derived from all 4 corners together*
  ///    actually maps it correctly.
  ({bool ok, bool degraded, String? message, double maxErrorPx, int worstIdx})
      _classifyWarpVerification(
    _WarpVerification v,
    List<CornerConfidence> preWarpConfidence,
  ) {
    const labels = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];
    var worstIdx = 0;
    for (var i = 1; i < v.errorPx.length; i++) {
      if (v.errorPx[i] > v.errorPx[worstIdx]) worstIdx = i;
    }

    int? rejectIdx;
    var rejectIsMeasured = false;
    var anyDegraded = false;
    for (var i = 0; i < v.errorPx.length; i++) {
      final err = v.errorPx[i];
      if (err <= _warpWarnPx) continue;
      anyDegraded = true;
      if (err <= _warpRejectPx) continue;
      final measured = v.redetected[i] != null;
      final confidentPreWarp = preWarpConfidence[i] == CornerConfidence.confident;
      // A measured mismatch blocks outright; an inconclusive one only
      // blocks when this corner wasn't already confidently found pre-warp
      // (see this method's own doc comment for why those are different).
      final blocks = measured || !confidentPreWarp;
      if (blocks && (rejectIdx == null || err > v.errorPx[rejectIdx])) {
        rejectIdx = i;
        rejectIsMeasured = measured;
      }
    }

    if (rejectIdx != null) {
      final i = rejectIdx;
      final err = v.errorPx[i];
      return (
        ok: false,
        degraded: false,
        maxErrorPx: err,
        worstIdx: i,
        message: rejectIsMeasured
            ? 'The ${labels[i]} corner does not land where it should after straightening the photo (${err.toStringAsFixed(0)}px off) — the perspective correction for this photo is not trustworthy. Retake with the sheet flatter and the camera steadier.'
            : 'The ${labels[i]} corner mark was not confidently found, and straightening the photo could not confirm it either. Retake with that corner clearly visible.',
      );
    }

    final maxErr = v.errorPx[worstIdx];
    if (anyDegraded) {
      return (
        ok: true,
        degraded: true,
        maxErrorPx: maxErr,
        worstIdx: worstIdx,
        message: maxErr.isFinite
            ? 'Perspective correction is only approximate for this photo (${maxErr.toStringAsFixed(0)}px off at ${labels[worstIdx]}) — retake for best accuracy if possible.'
            : 'Perspective correction could not be double-checked at the ${labels[worstIdx]} corner (shadow/glare on the warped image) — proceeding anyway since it was confidently found on the original photo.',
      );
    }
    return (
      ok: true,
      degraded: false,
      maxErrorPx: maxErr,
      worstIdx: worstIdx,
      message: null,
    );
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
    // Expected marker anchor per corner — the single point used both to
    // center the Stage-1 search box AND, via [_QuadrantSearch.anchorX]/
    // `anchorY`, to score every candidate's `positionScore` in
    // [_findMarkerInRegion]. These used to be computed independently: the
    // anchor passed for scoring was the literal page-quad VERTEX (fractions
    // (0,0)/(1,0)/(0,1)/(1,1)), not the actual expected fiducial position —
    // for any template with an inset marker (every real one; a printed
    // corner square is never at the literal page edge), that measured
    // `positionScore` against the wrong point, penalizing even a
    // perfectly-found real marker by however far it sits from the bare
    // page corner. Confirmed by direct code review, not assumed. Now both
    // derive from `template.cornerMarkers` in one place, pageQuad-or-
    // direct-fraction exactly as before — an inset marker (AT's right edge
    // at 0.867, PT's bottom at 0.761) lands the box AND the scoring anchor
    // on the real mark, not generic page-corner margin.
    final halfExtent = _stage1HalfExtentFrac * math.min(w, h);
    final stage1s = <cv.Rect>[];
    final anchors = <(double, double)>[];
    for (final marker in template.cornerMarkers) {
      final (cx, cy) = pageQuad == null
          ? (marker.xFrac * w, marker.yFrac * h)
          : _bilinearInterpolate(pageQuad, marker.xFrac, marker.yFrac);
      anchors.add((cx, cy));
      stage1s.add(_clampedRect(
        cx - halfExtent,
        cy - halfExtent,
        cx + halfExtent,
        cy + halfExtent,
        width,
        height,
      ));
    }
    // Fixed regardless of `halfExtent` above — see
    // [kFiducialAnchorToleranceFrac]'s doc comment.
    final anchorToleranceSide = 2 * kFiducialAnchorToleranceFrac * math.min(w, h);
    final stage1AnchorScale = math.max(
      1.0,
      0.25 * anchorToleranceSide * math.sqrt2,
    );

    return [
      for (var i = 0; i < 4; i++)
        (
          stage1: stage1s[i],
          quadrant: regions[i],
          anchorX: anchors[i].$1,
          anchorY: anchors[i].$2,
          stage1AnchorScale: stage1AnchorScale,
        ),
    ];
  }

  /// Approximate pixels-per-PDF-point scale for the RAW (not yet warped)
  /// photo — used only to size the search box for [_findInteriorAnchorsRaw],
  /// which (unlike [_detectInteriorFiducials]) has no canonical/warped image
  /// to measure against yet. Derived from [pageQuad]'s own top edge length
  /// when available (the same page-boundary estimate [_quadrantsFor] already
  /// trusts for corner search positions), or from the raw image width
  /// assuming the sheet fills the frame — the same fallback assumption
  /// [_quadrantsFor] makes when [_detectPageQuad] found no boundary.
  double _rawPxPerPt(
    int width,
    List<(double, double)>? pageQuad,
    OmrExamTemplate template,
  ) {
    if (pageQuad == null) return width / template.pageWidthPt;
    final tl = pageQuad[0], tr = pageQuad[1];
    final topWidthPx = math.sqrt(
      math.pow(tr.$1 - tl.$1, 2) + math.pow(tr.$2 - tl.$2, 2),
    );
    return topWidthPx > 0 ? topWidthPx / template.pageWidthPt : width / template.pageWidthPt;
  }

  /// Searches for TAT's interior per-Test fiducials (`tatAboveI/II/III`,
  /// `tatBelowI/II/III`, `dividerLeft/Right`) directly in the RAW (only
  /// rotated-for-orientation, never yet warped) image — the same "search a
  /// small box around the expected position" technique [_quadrantsFor] uses
  /// for the 4 outer corners, just against each interior mark's own
  /// (smaller) printed size and using [_rawPxPerPt] instead of a canonical
  /// warp's exact scale, since no warp exists yet at this point in
  /// [_refineCorners].
  ///
  /// Added 2026-09-18 so a capture with a marginal outer corner isn't left
  /// with zero benefit from TAT's own extra printed redundancy: only
  /// [CornerConfidence.confident] results are returned — these feed
  /// [_crossCheckCornersByGeometry]'s corner-rescue affine as trusted extra
  /// anchor points (see its `extraAnchors` param), so this deliberately
  /// only returns marks with the same strength of evidence the affine
  /// already trusts an outer corner to have. No-op (returns const `[]`
  /// immediately) for a template with no interior fiducials (AT/QTM/PT),
  /// so this costs nothing for them.
  List<({cv.Point2f point, double xFrac, double yFrac})> _findInteriorAnchorsRaw(
    cv.Mat gray,
    List<(double, double)>? pageQuad,
    OmrExamTemplate template,
  ) {
    if (template.interiorFiducials.isEmpty) return const [];
    final w = gray.width.toDouble();
    final h = gray.height.toDouble();
    final pxPerPt = _rawPxPerPt(gray.width, pageQuad, template);
    final found = <({cv.Point2f point, double xFrac, double yFrac})>[];
    for (final fiducial in template.interiorFiducials) {
      final (cx, cy) = pageQuad == null
          ? (fiducial.xFrac * w, fiducial.yFrac * h)
          : _bilinearInterpolate(pageQuad, fiducial.xFrac, fiducial.yFrac);
      final halfExtent = (fiducial.halfSizePt + 14) * pxPerPt;
      final box = _clampedRect(
        cx - halfExtent, cy - halfExtent, cx + halfExtent, cy + halfExtent,
        gray.width, gray.height,
      );
      final r = _findMarkerInRegion(
        gray, box, cx, cy,
        expectedSidePx: 2 * fiducial.halfSizePt * pxPerPt,
      );
      final c = r.centroid;
      if (c != null && r.confidence == CornerConfidence.confident) {
        found.add((point: c, xFrac: fiducial.xFrac, yFrac: fiducial.yFrac));
      }
    }
    return found;
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
  ///
  /// [anchorScaleOverride], when given, replaces the default
  /// region-size-derived position-scoring tolerance — see
  /// [kFiducialAnchorToleranceFrac]'s doc comment for why the Stage-1
  /// caller always passes one: without it, a search region enlarged for
  /// user positioning freedom would also silently loosen how strongly
  /// position scoring prefers a candidate near the true expected spot.
  _MarkerSearchResult _findMarkerInRegion(
    cv.Mat gray,
    cv.Rect region,
    double anchorX,
    double anchorY, {
    String? debugTag,
    double? anchorScaleOverride,
    double? expectedSidePx,
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
                    final anchorScale = anchorScaleOverride ??
                        math.max(
                          1.0,
                          0.25 *
                              math.sqrt(region.width * region.width +
                                  region.height * region.height),
                        );

                    // Winner tracked by COMBINED score — higher is better now
                    // (squareness-led), not the old "closest wins".
                    double bestScore = -1;
                    double runnerUpScore = -1;
                    double bestSquareness = 0;
                    double bestContrast = 0;
                    double bestArea = 0;
                    double bestDistance = double.infinity;
                    cv.Rect? bestRect;
                    var bestContourIndex = -1;
                    final rejected = <_RejectedCandidate>[];
                    void reject(
                      cv.Rect r,
                      double sq,
                      double sc,
                      String why, {
                      double area = 0,
                      double contrast = 0,
                    }) {
                      rejected.add(_RejectedCandidate(
                        cv.Rect(region.x + r.x, region.y + r.y, r.width, r.height),
                        sq,
                        sc,
                        why,
                        area: area,
                        contrast: contrast,
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
                      // Post-warp TAT squares have a known physical size.
                      // Include the contour dilation's two-pixel growth.
                      if (expectedSidePx != null && !tatMarkerShapeMatches(
                          expectedSidePx: expectedSidePx,
                          shortSide: shortSide.toDouble(), longSide: longSide.toDouble(),
                          extent: extent)) {
                        continue;
                      }

                      // Local contrast against this blob's own neighborhood.
                      // Computed up front — before any of the cheap gates
                      // below — so every rejection reason (including `area`
                      // and `fill_ratio`) carries a real contrast/area
                      // reading for the debug overlay/log, not just the
                      // survivors that reach full shape scoring. A real
                      // fiducial candidate rejected this early is otherwise
                      // invisible in the debug output — exactly the gap that
                      // made an earlier real-square-vs-bubble mixup hard to
                      // diagnose from the overlay alone.
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

                      void log(String s) {
                        if (_kFiducialDebug && debugTag != null) {
                          _fidLog('q=$debugTag c#$ci '
                              'bbox=(${rect.x},${rect.y},${rect.width},${rect.height}) '
                              'area=${area.toStringAsFixed(0)} contrast=${contrast.toStringAsFixed(1)} $s');
                        }
                      }

                      // ---- cheap early rejects (bound cost before the
                      // heavier shape metrics) ----
                      if (area < 8 || area > imageAreaCap) {
                        reject(rect, 0, 0, 'area', area: area, contrast: contrast);
                        log('REJECT area (need 8..${imageAreaCap.toStringAsFixed(0)})');
                        continue;
                      }
                      // Deliberately loose: a genuinely rotated square fills
                      // its *axis-aligned* box only ~0.5 at 45° in-plane
                      // rotation, and a handheld photo's *projective* (not
                      // just in-plane) perspective distortion can push a
                      // real printed square's bbox-fill ratio well below
                      // that — confirmed against a real handheld QTM capture
                      // where the true bottom-right square was rejected here
                      // before its shape metrics were even computed. Real
                      // discrimination is the rotation-invariant
                      // `rectangularity`/`solidity`/ink-density inside the
                      // squareness score below, not this cheap pre-filter —
                      // this only needs to reject genuine noise/slivers, and
                      // an answer bubble's own extent (~0.785 for a filled
                      // circle) sits comfortably above even this lowered
                      // floor, so lowering it doesn't reopen the
                      // bubble-as-fiducial problem.
                      if (boxArea <= 0 || extent < _markerMinFillRatio) {
                        reject(rect, 0, 0, 'fill_ratio', area: area, contrast: contrast);
                        log('REJECT fill_ratio (extent=${extent.toStringAsFixed(3)}<$_markerMinFillRatio)');
                        continue;
                      }
                      if (aspect > _markerMaxAspect) {
                        reject(rect, 0, 0, 'aspect', area: area, contrast: contrast);
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
                          'dist=${distance.toStringAsFixed(1)} '
                          'pos=${positionScore.toStringAsFixed(3)} score=${candScore.toStringAsFixed(3)}');

                      if (contrast < _markerMinContrast) {
                        reject(rect, squareness, candScore, 'contrast', area: area, contrast: contrast);
                        continue;
                      }
                      if (squareness < _markerMinSquarenessLow) {
                        reject(rect, squareness, candScore, 'low_squareness', area: area, contrast: contrast);
                        continue;
                      }
                      if (candScore > bestScore) {
                        runnerUpScore = bestScore;
                        if (bestRect != null) {
                          reject(bestRect, bestSquareness, bestScore, 'outscored',
                              area: bestArea, contrast: bestContrast);
                        }
                        bestScore = candScore;
                        bestSquareness = squareness;
                        bestContrast = contrast;
                        bestArea = area;
                        bestDistance = distance;
                        bestRect = rect;
                        bestContourIndex = ci;
                      } else {
                        runnerUpScore = math.max(runnerUpScore, candScore);
                        reject(rect, squareness, candScore, 'outscored', area: area, contrast: contrast);
                      }
                    }

                    rejected.sort((a, b) => b.squareness.compareTo(a.squareness));
                    final topRejects = rejected.take(5).toList();

                    if (bestRect == null ||
                        (expectedSidePx != null && tatMarkerMatchIsAmbiguous(bestScore, runnerUpScore))) {
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
                      // Temporary diagnostics comparing the detected marker with its anchor.
                      _fidLog(
                        'q=$debugTag winner=(${centroid.x.toStringAsFixed(1)},${centroid.y.toStringAsFixed(1)}) '
                        'expected=(${anchorX.toStringAsFixed(1)},${anchorY.toStringAsFixed(1)}) '
                        'distance=${bestDistance.toStringAsFixed(1)} '
                        'positionScore=${posScoreBest.toStringAsFixed(3)} '
                        'squareness=${bestSquareness.toStringAsFixed(3)} '
                        'contrast=${bestContrast.toStringAsFixed(1)} '
                        'tier=${tier.name}',
                      );
                    }

                    return _MarkerSearchResult(
                      centroid: centroid,
                      bboxGlobal: bboxGlobal,
                      confidence: tier,
                      squareness: bestSquareness,
                      contrast: bestContrast,
                      anchorDistance: bestDistance,
                      positionScore: posScoreBest,
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

  /// Classify marks by comparing bubble scores within each item to reduce lighting bias.
  /// The lowest score provides a blank reference, including for two-choice items.
  /// Equally filled choices (including all-marked rows) can read as blank.
  OmrScanResult _readBubbles(
    cv.Mat inkMap,
    OmrExamTemplate template,
    int canonicalWidth,
    int canonicalHeight,
    OmrMeshCorrection mesh,
  ) {
    // Sample the printed X/Y radii independently to match oval bubbles.
    final bubbleSampleHalfPxX = template.bubbleRadiusPt * _canonicalPxPerPt;
    final bubbleSampleHalfPxY = template.bubbleRadiusYPt * _canonicalPxPerPt;
    final ambiguousMargin = _ambiguousMarginFor(template.examCode);
    final blankFloor = _blankFillFloorFor(template.examCode);
    final presenceGap = _markPresenceGapFor(template.examCode);
    final bubbleDebug = _kBubbleDebug;
    // Use the wider recenter grid when mesh correction couldn't run (no
    // interior fiducials on this template) — the single global homography
    // leaves more local drift to compensate for.
    final recenterGrid = mesh.isActive
        ? _itemRecenterShiftFracs
        : _itemRecenterShiftFracsWide;
    final items = <OmrItemResult>[];
    // Kept alongside [items] so the classifier can re-decide every item once
    // the whole sheet has been measured -- its sheet-relative feature needs a
    // median over every bubble, which is only known after the loop.
    final classifierBubbles = <List<BubbleScores>>[];
    final classifierItems = <OmrItemResult>[];
    for (final section in template.sections) {
      for (final itemNumber in section.items.keys.toList()..sort()) {
        final choices = section.items[itemNumber]!;

        var measured = _measureItemAt(
          inkMap,
          choices,
          bubbleSampleHalfPxX,
          bubbleSampleHalfPxY,
          canonicalWidth,
          canonicalHeight,
          0,
          0,
          mesh,
        );
        var hasSomething = measured.bestFill >= blankFloor &&
            (measured.bestFill - measured.floorReference) >= presenceGap;
        var isAmbiguous = hasSomething &&
            _isAmbiguousMargin(measured, ambiguousMargin, presenceGap);
        var recentered = false;

        // Only spend the extra search on items the flat/relative checks
        // above still can't confidently place -- a confidently blank or
        // confidently marked item is left untouched, so this can only
        // rescue an uncertain result, never destabilize a good one.
        if (!hasSomething || isAmbiguous) {
          for (final dxFrac in recenterGrid) {
            for (final dyFrac in recenterGrid) {
              if (dxFrac == 0 && dyFrac == 0) continue;
              final candidate = _measureItemAt(
                inkMap,
                choices,
                bubbleSampleHalfPxX,
                bubbleSampleHalfPxY,
                canonicalWidth,
                canonicalHeight,
                dxFrac * bubbleSampleHalfPxX,
                dyFrac * bubbleSampleHalfPxY,
                mesh,
              );
              final candidateMargin = candidate.bestFill - candidate.runnerUpFill;
              final currentMargin = measured.bestFill - measured.runnerUpFill;
              if (candidateMargin > currentMargin) {
                measured = candidate;
                recentered = true;
              }
            }
          }
          if (recentered) {
            hasSomething = measured.bestFill >= blankFloor &&
                (measured.bestFill - measured.floorReference) >= presenceGap;
            isAmbiguous = hasSomething &&
                _isAmbiguousMargin(measured, ambiguousMargin, presenceGap);
          }
        }

        final bestChoice = measured.bestChoice;
        final bestFill = measured.bestFill;
        final runnerUpFill = measured.runnerUpFill;
        final floorReference = measured.floorReference;
        final measurements = measured.measurements;
        final markedChoice = hasSomething && !isAmbiguous ? bestChoice : null;
        items.add(
          OmrItemResult(
            sectionName: section.name,
            itemNumber: itemNumber,
            markedChoice: markedChoice,
            isAmbiguous: isAmbiguous,
          ),
        );
        if (OmrBubbleClassifier.enabled) {
          classifierBubbles.add(<BubbleScores>[
            for (final (choice, m) in measured.measurements)
              BubbleScores(
                choice: choice,
                ring: m.ringFill,
                whole: m.wholeFill,
                center: m.centerFill,
                score: m.score,
              ),
          ]);
          classifierItems.add(
            OmrItemResult(
              sectionName: section.name,
              itemNumber: itemNumber,
              markedChoice: null,
            ),
          );
        }
        if (bubbleDebug) {
          final debugResult = markedChoice ?? (isAmbiguous ? 'AMBIGUOUS' : 'BLANK');
          final buf = StringBuffer('Q$itemNumber\n');
          for (final (choice, m) in measurements) {
            buf.writeln(
              '$choice: ring=${m.ringFill.toStringAsFixed(3)} '
              'whole=${m.wholeFill.toStringAsFixed(3)} '
              'center=${m.centerFill.toStringAsFixed(3)} '
              'score=${m.score.toStringAsFixed(3)}',
            );
          }
          buf.writeln('best=$bestChoice');
          buf.writeln('runner=${runnerUpFill.toStringAsFixed(3)}');
          buf.writeln('floor=${floorReference.toStringAsFixed(3)}');
          buf.writeln(
            'presenceGap=${(bestFill - floorReference).toStringAsFixed(3)}',
          );
          buf.writeln('margin=${(bestFill - runnerUpFill).toStringAsFixed(3)}');
          if (recentered) buf.writeln('recentered=true');
          buf.write('result=$debugResult');
          _bubbleLog(buf.toString());
        }
      }
    }
    if (OmrBubbleClassifier.enabled &&
        classifierBubbles.length == items.length &&
        classifierBubbles.isNotEmpty) {
      final medianScore = OmrBubbleClassifier.sheetMedianScore(classifierBubbles);
      for (var i = 0; i < classifierBubbles.length; i++) {
        final verdict =
            OmrBubbleClassifier.classify(classifierBubbles[i], medianScore);
        items[i] = OmrItemResult(
          sectionName: classifierItems[i].sectionName,
          itemNumber: classifierItems[i].itemNumber,
          markedChoice: verdict.markedChoice,
          isAmbiguous: verdict.isAmbiguous,
        );
      }
    }
    return OmrScanResult(examCode: template.examCode, items: items);
  }

  /// True when [measured]'s best-to-runner-up gap is too small to call the
  /// item decisively marked -- either by the flat per-exam [ambiguousMargin],
  /// by (see [_ambiguousRelativeMarginFloor]) falling well short of the
  /// item's own presence gap despite a comfortably strong signal, or (see
  /// [_noCompetitorGapFraction]) because there simply isn't a real second
  /// choice regardless of how faint the winner itself is.
  ///
  /// [markPresenceGap] is the item's per-exam presence gap
  /// ([_markPresenceGapFor]), which both of those rescue paths scale
  /// against so that an exam with deliberately compressed thresholds (TAT)
  /// keeps the same relationships rather than being judged on AT/QTM's
  /// wider absolute numbers.
  bool _isAmbiguousMargin(
    _ItemMeasurement measured,
    double ambiguousMargin,
    double markPresenceGap,
  ) {
    final margin = measured.bestFill - measured.runnerUpFill;
    if (margin >= ambiguousMargin) return false;
    final presenceGap = measured.bestFill - measured.floorReference;
    final strongPresence =
        presenceGap >= markPresenceGap * _strongPresenceGapMultiplier;
    final decisiveRelativeToOwnSignal =
        strongPresence && (margin / presenceGap) >= _ambiguousRelativeMarginFloor;
    final runnerUpGapFromFloor = measured.runnerUpFill - measured.floorReference;
    final noRealCompetitor =
        runnerUpGapFromFloor < markPresenceGap * _noCompetitorGapFraction;
    return !(decisiveRelativeToOwnSignal || noRealCompetitor);
  }

  /// Measures every choice in one item with the same (shiftXPx, shiftYPx)
  /// applied to each -- modeling a local row-level registration drift
  /// rather than a per-bubble one -- and reduces the result to the ranked
  /// fields [_readBubbles] and its recenter search need.
  _ItemMeasurement _measureItemAt(
    cv.Mat inkMap,
    List<BubblePos> choices,
    double halfPxX,
    double halfPxY,
    int canonicalWidth,
    int canonicalHeight,
    double shiftXPx,
    double shiftYPx,
    OmrMeshCorrection mesh,
  ) {
    final measurements = [
      for (final bubble in choices)
        (
          bubble.choice,
          _measureBubble(
            inkMap,
            bubble,
            halfPxX,
            halfPxY,
            canonicalWidth,
            canonicalHeight,
            mesh,
            shiftXPx: shiftXPx,
            shiftYPx: shiftYPx,
          ),
        ),
    ];
    final fills = [
      for (final m in measurements) (m.$1, m.$2.score),
    ]..sort((a, b) => b.$2.compareTo(a.$2)); // descending by score

    // Use the lowest other score as the local blank reference.
    final floorReference = fills.sublist(1).map((e) => e.$2).reduce(math.min);

    return (
      measurements: measurements,
      bestChoice: fills[0].$1,
      bestFill: fills[0].$2,
      runnerUpFill: fills[1].$2, // every item has >=2 choices
      floorReference: floorReference,
    );
  }

  /// Measure ring, whole, and center ink fractions (255 = ink), then blend scores.
  /// The ring excludes the printed choice letter; center ink retains pencil evidence.
  /// These signals overlap, so the blend reweights center ink rather than adding
  /// independent votes. Separate X/Y radii match flattened printed bubbles.
  ({double ringFill, double wholeFill, double centerFill, double score})
      _measureBubble(
    cv.Mat inkMap,
    BubblePos bubble,
    double halfPxX,
    double halfPxY,
    int canonicalWidth,
    int canonicalHeight,
    OmrMeshCorrection mesh, {
    double shiftXPx = 0,
    double shiftYPx = 0,
  }) {
    // Mesh-correct the bubble's own canonical position first (a no-op
    // whenever `mesh.isActive` is false — see [OmrMeshCorrection.correct])
    // — the ambiguous-item recenter search's shift is then applied
    // relative to that corrected point, not the naive one, so a locally
    // bent bubble's recenter search still starts from where the bubble
    // actually is.
    final (correctedX, correctedY) = mesh.correct(bubble.xFrac * canonicalWidth, bubble.yFrac * canonicalHeight);
    final cx = correctedX + shiftXPx;
    final cy = correctedY + shiftYPx;
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
    final ringFill = ringArea > 0
        ? ((outerFill * outerArea) - (innerFill * innerArea)) / ringArea
        : outerFill;

    // Ring-dominant weights; validate against real captures before retuning.
    final score = _clamp01(
      0.55 * ringFill + 0.30 * outerFill + 0.15 * innerFill,
    );

    return (
      ringFill: ringFill,
      wholeFill: outerFill,
      centerFill: innerFill,
      score: score,
    );
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
