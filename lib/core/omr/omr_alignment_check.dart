/// How convincingly one of the four printed corner squares was located in a
/// given frame.
///
///  * [none] — no square-shaped, dark-enough blob near that corner.
///  * [low] — something square-ish was found, but weak (blur, shadow,
///    perspective, partial occlusion), or it was only confirmed via the
///    geometry-assisted rescue search (a real blob at the position the
///    other three markers predict).
///  * [confident] — a crisp, well-shaped, high-contrast square.
enum CornerConfidence { none, low, confident }

/// Overall live/post-capture assessment of a frame's four corner squares.
///
///  * [green] — all four [CornerConfidence.confident]. Ready to scan.
///  * [yellow] — a usable 4-point quad exists (≥3 confident, the rest
///    [CornerConfidence.low] with real marker evidence). Recoverable —
///    capture is allowed; the authoritative post-capture pass decides.
///  * [red] — fewer than four corners could be established, or the four
///    points don't form a plausible sheet. Not recoverable from this frame.
enum AlignmentVerdict { green, yellow, red }

/// Result of `OmrDecoder.locateCorners` — whether the four fiducial marks
/// were found for a given photo + template, AND (since the post-capture
/// pass is the only place that can reject a bad photo before it enters the
/// batch) whether the resulting perspective warp actually lands them back
/// at their known canonical positions. Does not do bubble sampling — that
/// stays exclusive to the much more expensive `decode()`.
///
/// Plain data, no native/Web-specific dependency, so both the native
/// (opencv_dart-backed) and Web (stub) `OmrDecoder` implementations share
/// this exact same type — see omr_decoder.dart's conditional export.
class AlignmentCheck {
  /// Back-compat gate for callers that only branch on pass/fail — true for
  /// [AlignmentVerdict.green] and [AlignmentVerdict.yellow], false for
  /// [AlignmentVerdict.red].
  final bool aligned;

  /// User-facing note. Null on a clean pass; a "corner X is only
  /// geometrically consistent" hint on [AlignmentVerdict.yellow]; the
  /// retake reason on [AlignmentVerdict.red].
  final String? message;

  final AlignmentVerdict verdict;

  /// Per-corner confidence in TL, TR, BL, BR order. `const []` when the
  /// search threw before four corners could be assessed.
  final List<CornerConfidence> corners;

  /// Per-corner canonical-pixel distance between each fiducial's post-warp
  /// re-detected position and its expected template position (TL, TR, BL,
  /// BR) — populated once a homography was actually fit and re-verified.
  /// Null when the post-warp check never ran (e.g. corners weren't even
  /// found pre-warp).
  final List<double>? reprojectionErrorPx;

  /// True only when [aligned] is false specifically because the post-warp
  /// reprojection check failed — a homography was fit from four otherwise
  /// plausible corners, but re-detecting them on the corrected image didn't
  /// land close enough to where the template says they must be. Distinct
  /// from a pre-warp corner-search/geometry failure, which uses
  /// [AlignmentCheck.misaligned] with this false.
  final bool warpRejected;

  const AlignmentCheck.aligned()
      : aligned = true,
        message = null,
        verdict = AlignmentVerdict.green,
        corners = const [
          CornerConfidence.confident,
          CornerConfidence.confident,
          CornerConfidence.confident,
          CornerConfidence.confident,
        ],
        reprojectionErrorPx = null,
        warpRejected = false;

  /// A usable quad, but at least one corner is only [CornerConfidence.low]
  /// (or the post-warp reprojection error is nonzero but within tolerance).
  /// Still counts as [aligned] — the post-capture pass is authoritative.
  const AlignmentCheck.degraded(
    this.message,
    this.corners, [
    this.reprojectionErrorPx,
  ])  : aligned = true,
        verdict = AlignmentVerdict.yellow,
        warpRejected = false;

  const AlignmentCheck.misaligned(this.message)
      : aligned = false,
        verdict = AlignmentVerdict.red,
        corners = const [],
        reprojectionErrorPx = null,
        warpRejected = false;

  /// Four corners were found and a homography was fit, but re-detecting the
  /// markers on the warped image didn't land close enough to their expected
  /// canonical positions — the perspective correction for this photo isn't
  /// trustworthy. Unlike [misaligned], keeps the real per-corner confidence
  /// tiers and the measured errors, since the pre-warp search itself did
  /// succeed; only the warp's own result is being rejected.
  const AlignmentCheck.warpMisaligned(
    this.message,
    this.corners,
    this.reprojectionErrorPx,
  )   : aligned = false,
        verdict = AlignmentVerdict.red,
        warpRejected = true;
}

/// Which of the (up to) 3 orientations `OmrDecoder.checkCornersFromLuma`
/// tries against a raw camera frame actually matched the sheet — a raw
/// preview frame can be sideways relative to the UI regardless of device
/// lock (see that method's own doc comment). Carried out to the live
/// diagnostic overlay (see `ExamScanningScreen`) because mapping a detected
/// point back onto the displayed preview needs to know which orientation
/// its fraction is measured against — see `fiducial_coordinate_mapping.dart`.
enum FrameRotation { none, clockwise90, counterClockwise90 }

/// Coarse, user-facing category for why one corner search didn't land on
/// [CornerConfidence.confident] — surfaced only by the temporary opt-in
/// diagnostic overlay; never read by any detection/capture decision.
///
///  * [confident] — nothing to explain; the corner is locked.
///  * [shape] — the best candidate found (or, for a `none` result, the
///    closest rejected candidate) didn't look enough like a solid printed
///    square (see `OmrDecoder._squarenessOf`).
///  * [position] — a real, well-shaped, high-contrast candidate was found,
///    but too far from where it was expected — or, for a `none` result,
///    the closest rejected candidate mapped inside the answer grid or
///    failed the affine geometry check against the other corners.
///  * [contrast] — the closest rejected candidate wasn't dark enough
///    against its local background to count as ink.
///  * [noCandidate] — nothing at all cleared even the cheapest area/aspect
///    pre-filters near this corner.
enum CornerRejectionCategory { confident, shape, position, contrast, noCandidate }

/// Maps one of [OmrDecoder]'s internal candidate-rejection reason strings
/// (`area`, `aspect`, `fill_ratio`, `contrast`, `low_squareness`,
/// `inside_grid`, `geom_inconsistent`, `outscored`) to the coarser,
/// user-facing [CornerRejectionCategory] the diagnostic overlay actually
/// displays. Pure string mapping — kept here (not duplicated) so both the
/// decoder and any test of this mapping use the exact same rule.
CornerRejectionCategory categorizeRejectionReason(String rawReason) =>
    switch (rawReason) {
      'contrast' => CornerRejectionCategory.contrast,
      'area' || 'aspect' || 'fill_ratio' || 'low_squareness' =>
        CornerRejectionCategory.shape,
      'inside_grid' || 'geom_inconsistent' || 'outscored' =>
        CornerRejectionCategory.position,
      _ => CornerRejectionCategory.shape,
    };

/// Per-corner diagnostic detail for the temporary opt-in live diagnostic
/// overlay (see `ExamScanningScreen`'s `_diagnosticsEnabled`) — never used
/// by any detection/capture decision, purely descriptive of what the
/// decoder actually searched and found for one corner in one frame. Every
/// geometric field is a fraction (0-1) of whichever frame [FrameRotation]
/// says was searched, matching `checkCornersFromLuma`'s own `positions` —
/// resolution-independent by construction, same as the rest of the live
/// guide.
class CornerDiagnostic {
  /// This corner's Stage-1 search box.
  final ({double x0, double y0, double x1, double y1}) searchBoxFrac;

  /// The position this corner's search was anchored/scored against — the
  /// template-expected corner, possibly skewed by an inaccurate
  /// [FrameRotation]-relative page-boundary estimate (see
  /// `OmrDecoder._detectPageQuad`'s doc comment).
  final (double, double) anchorFrac;

  /// Winning candidate's centroid, or null if nothing was accepted.
  final (double, double)? centroidFrac;

  final CornerConfidence confidence;
  final double squareness;
  final double contrast;
  final double positionScore;
  final CornerRejectionCategory rejection;

  const CornerDiagnostic({
    required this.searchBoxFrac,
    required this.anchorFrac,
    required this.centroidFrac,
    required this.confidence,
    required this.squareness,
    required this.contrast,
    required this.positionScore,
    required this.rejection,
  });
}
