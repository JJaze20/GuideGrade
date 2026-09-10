import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/omr_scan_result.dart';
import 'omr_alignment_check.dart';
import 'omr_templates.dart';

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
  /// local background to count as a real mark (not a shadow edge).
  static const double _markerMinContrast = 20;

  /// A candidate blob's contour area must fill at least this fraction of
  /// its own bounding box to count as a mark. The printed marks (solid
  /// square or thin tick — see [_findMarkerInRegion]) are both clean filled
  /// shapes; background clutter that happens to be dark and roughly the
  /// right size (fabric texture, shadows, a keyboard key) rarely fills its
  /// bounding box this tightly, so this rejects that clutter instead of
  /// confidently reporting a mark "found" on whatever's actually in frame.
  static const double _markerMinFillRatio = 0.55;

  /// A candidate blob's bounding box must not be more elongated than this
  /// (longer side / shorter side). The thinnest legitimate mark is the
  /// tick (~2.5pt stroke over a 12pt span, aspect ~4.8), so this allows
  /// real photo blur/perspective slack above that while still rejecting
  /// long edges — a table line, a run of header text — that happen to
  /// cross the search window.
  static const double _markerMaxAspect = 7.0;

  /// A candidate blob's circularity (4*pi*area/perimeter^2 — 1.0 for a
  /// perfect circle, ~0.785 for a square) must be at or below this. A
  /// solid, well-filled pencil bubble is round, high-contrast, and (being
  /// roughly circular) has a near-1:1 bounding-box aspect ratio — close
  /// enough to the printed corner marker's own fill-ratio and aspect that
  /// both checks above pass a filled bubble as readily as the real mark.
  /// Confirmed on a real device: zooming in close enough that only one
  /// marked item was in frame let the search latch onto that item's own
  /// filled bubbles as "corner marks", passing every other check, instead
  /// of correctly finding nothing. Circularity is the one property that
  /// actually distinguishes them — the printed marker is a solid filled
  /// *square* (see tool/generate_sheets.dart's corner-marker drawing:
  /// `drawRect` + `fillPath`, not an ellipse), not a circle. 0.88 sits with
  /// real margin above a square's ~0.785 (room for corners softened by
  /// blur/dilation) and real margin below a circle's 1.0.
  static const double _markerMaxCircularity = 0.88;

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
  /// Returns whether each of the 4 fiducial marks is currently found,
  /// independently, in [top-left, top-right, bottom-left, bottom-right]
  /// order — unlike [locateCorners], this doesn't require all 4 to form a
  /// plausible rectangle together, since each corner's little viewfinder
  /// square needs to react on its own as the user moves the sheet, not
  /// just an aggregate pass/fail.
  ///
  /// Searches the same way [_refineCorners] does (see [_quadrantsFor],
  /// [_findMarkerInRegion]) — each of the photo's own 4 quadrants,
  /// directly, not a small window around a predicted position — so the
  /// live guide and the post-capture gate can never disagree about
  /// whether a mark is findable in a given frame.
  List<bool> checkCornersFromLuma(
    Uint8List lumaBytes,
    int width,
    int height,
    int bytesPerRow,
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
        return [
          for (final (region, anchorX, anchorY) in _quadrantsFor(
            gray.width,
            gray.height,
            pageQuad,
          ))
            _findMarkerInRegion(gray, region, anchorX, anchorY) != null,
        ];
      } finally {
        if (!identical(gray, full)) gray.dispose();
      }
    } finally {
      full.dispose();
    }
  }

  /// Shared by [locateCorners] and [checkCornersFromLuma] so a captured
  /// photo and a live preview frame are judged by identical logic.
  AlignmentCheck _checkAlignment(cv.Mat gray, OmrExamTemplate template) {
    try {
      final (oriented, _, _) = _orientAndFindCorners(gray, template);
      if (!identical(oriented, gray)) oriented.dispose();
      return const AlignmentCheck.aligned();
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
        final (oriented, corners, _) = _orientAndFindCorners(gray, template);
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
        List<cv.Point2f> corners;
        int? rotationCode;
        try {
          (oriented, corners, rotationCode) = _orientAndFindCorners(
            gray,
            template,
          );
        } on StateError {
          return null;
        }
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
        List<cv.Point2f> corners;
        int? rotationCode;
        try {
          (oriented, corners, rotationCode) = _orientAndFindCorners(gray, template);
        } on StateError {
          return null;
        }
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
        List<cv.Point2f> corners;
        int? rotationCode;
        try {
          (oriented, corners, rotationCode) = _orientAndFindCorners(
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
              for (final c in corners) {
                cv.circle(
                  cornersDebug,
                  cv.Point(c.x.round(), c.y.round()),
                  16,
                  cv.Scalar(0, 0, 255),
                  thickness: 5,
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

  /// Finds each of the sheet's 4 fiducial corner marks by searching the
  /// photo's own 4 quadrants directly (see [_quadrantsFor] and
  /// [_findMarkerInRegion]) — every quadrant is searched in full, so a
  /// wrong page-boundary estimate can no longer hide the true mark outside
  /// a too-small window the way the old seed-and-search design could.
  ///
  /// [_detectPageQuad]'s estimate is still used, but only to pick which
  /// candidate blob *within* that full quadrant search is scored as the
  /// real mark: measuring distance to the literal photo corner instead
  /// (when no boundary is visible, or as the whole-frame fallback) is
  /// only correct when the sheet fills the frame edge-to-edge. Whenever
  /// there's visible background around the sheet — the common case — a
  /// fold, shadow, or texture sitting right at the photo's actual corner
  /// will always be closer to that anchor than the true mark is, and wins
  /// on distance alone. A rough page-boundary estimate, even an imperfect
  /// one, sits far closer to the true mark than random background clutter
  /// at the frame's edge does, which is enough to correctly break that
  /// tie. Returns the 4 refined centroids in [top-left, top-right,
  /// bottom-left, bottom-right] order.
  List<cv.Point2f> _refineCorners(cv.Mat gray, OmrExamTemplate template) {
    const labels = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];
    final pageQuad = _detectPageQuad(gray);
    final quadrants = _quadrantsFor(gray.width, gray.height, pageQuad);
    // ---- TEMPORARY fiducial-selection instrumentation (diagnostic only) ----
    if (_kFiducialDebug) {
      _fidLog(
        '===== pass on ${gray.width}x${gray.height} image | '
        'pageQuad=${pageQuad == null ? "null (fallback: literal photo corners)" : pageQuad.map((p) => "(${p.$1.toStringAsFixed(0)},${p.$2.toStringAsFixed(0)})").join(" ")} =====',
      );
      for (var i = 0; i < quadrants.length; i++) {
        final (region, ax, ay) = quadrants[i];
        _fidLog(
          'anchor q=${labels[i]} = (${ax.toStringAsFixed(1)},${ay.toStringAsFixed(1)}) '
          'searchRegion=(${region.x},${region.y},${region.width},${region.height})',
        );
      }
    }
    // ----------------------------------------------------------------------
    final found = List<cv.Point2f?>.generate(quadrants.length, (i) {
      final (region, anchorX, anchorY) = quadrants[i];
      return _findMarkerInRegion(
        gray,
        region,
        anchorX,
        anchorY,
        debugTag: _kFiducialDebug ? labels[i] : null,
      );
    });
    // ---- TEMPORARY: winners + final four corner coordinates ----
    if (_kFiducialDebug) {
      for (var i = 0; i < found.length; i++) {
        final p = found[i];
        _fidLog(
          'WINNER  q=${labels[i]} = '
          '${p == null ? "NOT FOUND" : "(${p.x.toStringAsFixed(1)},${p.y.toStringAsFixed(1)})"}',
        );
      }
      _fidLog(
        'final corners TL/TR/BL/BR = '
        '${found.map((p) => p == null ? "null" : "(${p.x.toStringAsFixed(1)},${p.y.toStringAsFixed(1)})").join(" ")}',
      );
    }
    // -----------------------------------------------------------

    // All 4 fiducial marks must be found directly — no reconstructing a
    // missing one from the other 3. An earlier version tolerated exactly 1
    // missing corner, estimating it via parallelogram-diagonal math from
    // the other 3 (a photographed rectangle's diagonals share a midpoint
    // under mild perspective distortion). That let a scan proceed on an
    // estimate rather than a confirmed detection — precisely for the
    // occluded/uncertain cases (a thumb, a crease, a glare spot) most
    // likely to also be skewed, which is the opposite of where an estimate
    // should be trusted. Requiring a clean 4/4 makes "not enough was
    // detected" a hard rejection instead of a silent guess feeding into
    // perspective correction and bubble sampling.
    final missing = [
      for (var i = 0; i < found.length; i++)
        if (found[i] == null) i,
    ];
    if (missing.isNotEmpty) {
      final names = missing.map((i) => labels[i]).join(', ');
      throw StateError(
        'Could not find the $names alignment mark${missing.length > 1 ? 's' : ''}. '
        'Page not fully detected. Please align the sheet and try again.',
      );
    }

    final resolved = found.cast<cv.Point2f>();
    _validateQuad(resolved, template, gray);
    return resolved;
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
  (cv.Mat, List<cv.Point2f>, int?) _orientAndFindCorners(
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

  /// The 4 regions to search for each corner mark — one full quadrant of
  /// the photo per mark, in [top-left, top-right, bottom-left,
  /// bottom-right] order — paired with the point each quadrant's best
  /// candidate is scored against for distance (see [_findMarkerInRegion]):
  /// bilinearly interpolated from [pageQuad] when [_detectPageQuad] found
  /// a page boundary, or that quadrant's literal photo corner otherwise
  /// (correct when the sheet fills the frame edge-to-edge, so there's no
  /// boundary edge to have detected in the first place).
  ///
  /// The *search region* itself is always the full quadrant regardless —
  /// only the scoring anchor depends on [pageQuad]. A wrong or imprecise
  /// page-boundary estimate used to mean the true mark could fall outside
  /// a small search window built from it and never even be examined; now
  /// it only means the anchor is slightly off, and the true mark — closer
  /// to a decent estimate than any unrelated background clutter sitting
  /// at the photo's literal corner — still wins on distance.
  ///
  /// Identifying *which* corner a mark is doesn't need the template at
  /// all: every exam's 4 corner marks sit one to a quadrant of the printed
  /// page by construction (see tool/generate_sheets.dart's
  /// `_cornerMarkers`), so quadrant identity alone is enough. Quadrants
  /// overlap slightly past the exact midpoint ([_quadrantOverlapFrac]) so
  /// a mark sitting close to the frame's center — a small or off-center
  /// sheet — still falls inside its own quadrant.
  List<(cv.Rect, double, double)> _quadrantsFor(
    int width,
    int height,
    List<(double, double)>? pageQuad,
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
    return [
      for (var i = 0; i < 4; i++) (regions[i], anchors[i].$1, anchors[i].$2),
    ];
  }

  /// Searches all of [region] for the fiducial mark, scoring every
  /// candidate blob by its distance to ([anchorX], [anchorY]) — the
  /// sheet's own estimated corner, or the photo's literal corner as a
  /// fallback (see [_quadrantsFor]) — combined with contrast.
  ///
  /// This replaces an earlier design that only *searched* a small window
  /// around that same predicted position: when the estimate was off — a
  /// textured background confusing it, a broken contour from a shadow —
  /// the true mark could sit outside the search window entirely and would
  /// never even be examined, reporting "not found" for a mark that was in
  /// fact clearly visible in the photo, with no way to tell "the marker
  /// isn't there" apart from "we looked in the wrong place".
  /// Searching the whole quadrant removes that failure mode: the mark is
  /// found by what it actually looks like (a small, solid, high-contrast
  /// square) and where it genuinely is, not by whether an earlier,
  /// separate guess happened to be close enough.
  ///
  /// Rejects implausibly tiny (speckle) or large (a shadow, a block of
  /// clutter) blobs, filters by fill-ratio/aspect/contrast to keep only
  /// blobs that actually look like the printed mark, then takes whichever
  /// survivor's centroid is closest to the anchor corner.
  cv.Point2f? _findMarkerInRegion(
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

                    double bestScore = double.infinity;
                    cv.Rect? bestRect;
                    var bestContourIndex = -1;
                    for (var ci = 0; ci < contours.length; ci++) {
                      final contour = contours[ci];
                      final area = cv.contourArea(contour);
                      // ---- metrics ----
                      // rect / boxArea / longSide / shortSide / perimeter /
                      // circularity are computed here (ahead of the first
                      // `continue`) ONLY so the temporary instrumentation
                      // below can print a uniform row for every candidate.
                      // cv.boundingRect and cv.arcLength are pure and their
                      // values are used exactly where they were before; no
                      // accept/reject condition changed.
                      final rect = cv.boundingRect(contour);
                      final boxArea = (rect.width * rect.height).toDouble();
                      final longSide = math.max(rect.width, rect.height);
                      final shortSide = math.max(
                        1,
                        math.min(rect.width, rect.height),
                      );
                      final aspect = longSide / shortSide;
                      final extent = boxArea > 0 ? area / boxArea : 0.0;
                      final perimeter = cv.arcLength(contour, true);
                      final circularity = perimeter > 0
                          ? 4 * math.pi * area / (perimeter * perimeter)
                          : 0.0;

                      // ---- diagnostic-only extras (never gate anything) ----
                      var approxVerts = -1;
                      var rectangularity = -1.0;
                      var inkDensity = -1.0;
                      var solidity = -1.0;
                      if (_kFiducialDebug && debugTag != null && area >= 8) {
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
                      }

                      double? candContrast;
                      double? candDistance;
                      double? candScore;
                      void logCand(String outcome) {
                        if (!_kFiducialDebug || debugTag == null) return;
                        _fidLog(
                          'q=$debugTag c#$ci '
                          'bbox=(${rect.x},${rect.y},${rect.width},${rect.height}) '
                          'w=${rect.width} h=${rect.height} '
                          'cArea=${area.toStringAsFixed(1)} '
                          'boxArea=${boxArea.toStringAsFixed(1)} '
                          'extent=${extent.toStringAsFixed(3)} '
                          'aspect=${aspect.toStringAsFixed(2)} '
                          'peri=${perimeter.toStringAsFixed(1)} '
                          'circ=${circularity.toStringAsFixed(3)} '
                          'contrast=${candContrast?.toStringAsFixed(1) ?? "-"} '
                          'dist=${candDistance?.toStringAsFixed(1) ?? "-"} '
                          'score=${candScore?.toStringAsFixed(3) ?? "-"} | '
                          'approxV=$approxVerts '
                          'rectangularity=${rectangularity.toStringAsFixed(3)} '
                          'inkDensity=${inkDensity.toStringAsFixed(3)} '
                          'solidity=${solidity.toStringAsFixed(3)} '
                          '=> $outcome',
                        );
                      }

                      if (area < 8 || area > imageArea * 0.02) {
                        logCand(
                          'REJECT area_bounds (need 8..${(imageArea * 0.02).toStringAsFixed(0)})',
                        );
                        continue;
                      }

                      // Reject blobs that don't actually look like a printed
                      // mark (a clean filled square or thin tick) — this is
                      // the main defense against reporting "found" on
                      // whatever dark clutter happens to sit in this
                      // quadrant when the camera isn't even pointed at a
                      // sheet.
                      if (boxArea <= 0 || area / boxArea < _markerMinFillRatio) {
                        logCand('REJECT fill_ratio (extent<$_markerMinFillRatio)');
                        continue;
                      }
                      if (longSide / shortSide > _markerMaxAspect) {
                        logCand('REJECT aspect (>$_markerMaxAspect)');
                        continue;
                      }

                      if (perimeter <= 0) {
                        logCand('REJECT perimeter<=0');
                        continue;
                      }
                      if (circularity > _markerMaxCircularity) {
                        logCand('REJECT circularity (>$_markerMaxCircularity)');
                        continue;
                      }

                      final globalCx = region.x + rect.x + rect.width / 2;
                      final globalCy = region.y + rect.y + rect.height / 2;
                      final distance = math.sqrt(
                        math.pow(globalCx - anchorX, 2) +
                            math.pow(globalCy - anchorY, 2),
                      );
                      candDistance = distance;

                      // Contrast is measured against this blob's own local
                      // neighborhood, not one mean for the whole quadrant.
                      // A quadrant search region can be a large fraction of
                      // the photo — including a lot of background well
                      // outside the page — so a single region-wide mean
                      // gets dragged toward whatever dominates that area.
                      // On a photo with substantial dark background around
                      // the sheet, that pulls the "background" reading
                      // dark enough that the real mark's genuine contrast
                      // against the white page next to it reads as too low
                      // to pass _markerMinContrast, while background
                      // clutter sitting in that same dark area can read as
                      // adequate contrast against the same skewed number.
                      // A small local box around each candidate — sized to
                      // its own blob, not the search region — restores the
                      // "contrast against what's actually next to it"
                      // measurement that made this filter meaningful in
                      // the first place.
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
                      candContrast = contrast;
                      if (contrast < _markerMinContrast) {
                        logCand('REJECT contrast (<$_markerMinContrast)');
                        continue;
                      }

                      // Prefer blobs close to this quadrant's own photo
                      // corner that are also dark enough to be real
                      // fiducials, not shadow edges.
                      final score =
                          distance / math.max(contrast, _markerMinContrast);
                      candScore = score;
                      logCand(
                        score < bestScore ? 'SCORED (new best)' : 'SCORED',
                      );
                      if (score < bestScore) {
                        bestScore = score;
                        bestRect = rect;
                        bestContourIndex = ci;
                      }
                    }
                    if (bestRect == null) return null;
                    // The blob's true (area-weighted) centroid, not its
                    // bounding box's midpoint — the two only coincide for a
                    // perfectly clean, symmetric blob. Anything that
                    // distorts the thresholded/dilated shape asymmetrically
                    // (a shadow clipping one edge, motion blur smearing it
                    // one way, uneven lighting eating into one side more
                    // than another) shifts a bounding-box center away from
                    // the mark's real physical position without shifting
                    // the true centroid nearly as much — and since
                    // warpPerspective fits an exact transform through
                    // whichever 4 points it's given, even one corner's
                    // bounding-box-center error (while the other 3 are
                    // accurate) skews the whole warped image, which showed
                    // up as a subtly tilted result on a real scan. Computed
                    // by drawing just this one winning contour onto a small
                    // mask sized to its own bounding box (not the whole ROI
                    // — cheap, and immune to any other blob nearby) and
                    // taking cv.moments of that.
                    final rect = bestRect;
                    final mask = cv.Mat.zeros(rect.height, rect.width, cv.MatType.CV_8UC1);
                    try {
                      cv.drawContours(
                        mask,
                        contours,
                        bestContourIndex,
                        cv.Scalar.all(255),
                        thickness: -1,
                        offset: cv.Point(-rect.x, -rect.y),
                      );
                      final m = cv.moments(mask);
                      try {
                        final cx = m.m00 > 0
                            ? region.x + rect.x + m.m10 / m.m00
                            : region.x + rect.x + rect.width / 2;
                        final cy = m.m00 > 0
                            ? region.y + rect.y + m.m01 / m.m00
                            : region.y + rect.y + rect.height / 2;
                        return cv.Point2f(cx.toDouble(), cy.toDouble());
                      } finally {
                        m.dispose();
                      }
                    } finally {
                      mask.dispose();
                    }
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
