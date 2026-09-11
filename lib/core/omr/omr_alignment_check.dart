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
/// were found for a given photo + template, without doing the (much more
/// expensive) perspective warp and bubble sampling.
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

  const AlignmentCheck.aligned()
      : aligned = true,
        message = null,
        verdict = AlignmentVerdict.green,
        corners = const [
          CornerConfidence.confident,
          CornerConfidence.confident,
          CornerConfidence.confident,
          CornerConfidence.confident,
        ];

  /// A usable quad, but at least one corner is only [CornerConfidence.low].
  /// Still counts as [aligned] — the post-capture pass is authoritative.
  const AlignmentCheck.degraded(this.message, this.corners)
      : aligned = true,
        verdict = AlignmentVerdict.yellow;

  const AlignmentCheck.misaligned(this.message)
      : aligned = false,
        verdict = AlignmentVerdict.red,
        corners = const [];
}
