import 'dart:math' as math;

import 'omr_templates.dart';

/// The 9 named control points a redesigned sheet's fiducials define: the 4
/// outer corners (always present, every template) plus the 5 interior
/// marks a redesigned template additionally prints (see
/// [OmrExamTemplate.interiorFiducials]/[OmrFiducialRole]).
///
/// Kept as one fixed enum (rather than just indexing `interiorFiducials`)
/// because the mesh's triangulation topology below is hardcoded against
/// these exact 9 roles — the same 9 positions on every AT/QTM redesigned
/// sheet, corners included.
enum OmrMeshVertex {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  dividerLeft,
  dividerRight,
  centerAboveAnswers,
  centerAtDivider,
  centerBelowAnswers,
}

/// One (canonical, measured) point pair for a mesh vertex, plus whether the
/// "measured" side is a real detection or just a fallback copy of the
/// canonical position (used when that interior fiducial wasn't confidently
/// found — see [OmrMeshCorrection.build]).
class OmrMeshPointStatus {
  final OmrMeshVertex vertex;
  final double canonicalX;
  final double canonicalY;
  final double measuredX;
  final double measuredY;
  final bool wasDetected;

  /// Straight-line distance between canonical and measured position, in
  /// canonical pixels — 0 for every corner (pinned exactly by the primary
  /// homography's own 4-point fit) and for any undetected interior point
  /// (falls back to its canonical position, i.e. "assume locally flat").
  double get residualPx {
    final dx = measuredX - canonicalX;
    final dy = measuredY - canonicalY;
    return math.sqrt(dx * dx + dy * dy);
  }

  const OmrMeshPointStatus({
    required this.vertex,
    required this.canonicalX,
    required this.canonicalY,
    required this.measuredX,
    required this.measuredY,
    required this.wasDetected,
  });
}

/// One interior fiducial's detection outcome, for [OmrMeshCorrection.diagnostics]
/// — kept as 3 explicit, mutually exclusive states rather than a single
/// pass/fail flag because "nothing found there" and "found, but not where
/// expected" are different evidence and call for different responses:
///
///  * [missing] — no candidate cleared even the loosest shape/contrast
///    bar near the expected position (obscured, poor lighting, blur). On
///    its own this says nothing about whether the sheet is actually
///    flat — never grounds for rejecting a capture by itself.
///  * [displaced] — a real candidate *was* found, but not at its expected
///    (canonical) position — positive, direct evidence of either local
///    bending or a wrong outer-corner match (see
///    [OmrMeshVerdict.likelyMisregistered]).
///  * [confirmed] — found within [OmrMeshCorrection.planarResidualPt] of
///    its expected position.
enum OmrMeshPointDetectionStatus { missing, displaced, confirmed }

/// Expected-vs-detected diagnostic for one interior fiducial — see
/// [OmrMeshCorrection.diagnostics].
class OmrMeshPointDiagnostic {
  final OmrMeshVertex vertex;
  final double expectedX;
  final double expectedY;

  /// Null exactly when [status] is [OmrMeshPointDetectionStatus.missing].
  final double? detectedX;
  final double? detectedY;

  /// Null exactly when [status] is [OmrMeshPointDetectionStatus.missing]
  /// (there is nothing to measure a distance to/from).
  final double? residualPt;

  final OmrMeshPointDetectionStatus status;

  const OmrMeshPointDiagnostic({
    required this.vertex,
    required this.expectedX,
    required this.expectedY,
    required this.detectedX,
    required this.detectedY,
    required this.residualPt,
    required this.status,
  });

  @override
  String toString() {
    final role = OmrMeshCorrection._roleFor(vertex)?.name ?? vertex.name;
    return switch (status) {
      OmrMeshPointDetectionStatus.missing =>
        '$role: MISSING (expected ${expectedX.toStringAsFixed(0)},${expectedY.toStringAsFixed(0)})',
      OmrMeshPointDetectionStatus.displaced =>
        '$role: DISPLACED ${residualPt!.toStringAsFixed(1)}pt (expected ${expectedX.toStringAsFixed(0)},'
            '${expectedY.toStringAsFixed(0)} -> detected ${detectedX!.toStringAsFixed(0)},${detectedY!.toStringAsFixed(0)})',
      OmrMeshPointDetectionStatus.confirmed =>
        '$role: confirmed (${residualPt!.toStringAsFixed(1)}pt)',
    };
  }
}

/// How confidently the sheet's real (non-planar) distortion could be
/// measured and corrected — see the class doc comment on
/// [OmrMeshCorrection] for what each level means for bubble sampling.
enum OmrMeshVerdict {
  /// No interior fiducials on this template at all (legacy sheet, TAT) —
  /// the decoder never attempts local correction; behavior is identical to
  /// before this feature existed.
  notApplicable,

  /// Interior fiducials were checked and landed within [
  /// OmrMeshCorrection.planarResidualPt] of their canonical positions —
  /// the capture is flat enough that the single global homography is
  /// already correct; no mesh warp applied.
  planar,

  /// Too few interior fiducials were confidently detected to trust a local
  /// correction (see [OmrMeshCorrection.minConfidentInteriorPoints]) —
  /// this says nothing about whether the sheet is actually flat or bent,
  /// only that there isn't enough independent evidence either way. Falls
  /// back to the global homography, same as [planar], but callers should
  /// treat this as weaker evidence, not a confirmed-flat capture.
  inconclusive,

  /// A real, moderate, measured deviation was found at one or more
  /// interior points and a piecewise-affine mesh correction was built and
  /// applied.
  meshApplied,

  /// A measured deviation was found, but it exceeds [
  /// OmrMeshCorrection.maxTrustedResidualPt] — bending too severe to
  /// correct reliably from 5 sparse interior points, AND the individual
  /// residuals don't share the [likelyMisregistered] "all pointing the
  /// same way" pattern (see that verdict). No mesh is applied; callers
  /// should surface this as a retake-with-a-flatter-sheet request.
  tooSevere,

  /// The detected interior points disagree with the initial 4-corner warp
  /// by a large, near-uniform amount — their residual vectors point the
  /// same way by roughly the same magnitude, which is the signature of the
  /// *entire* coordinate frame being off (almost always because one of the
  /// 4 outer corner marks was mismatched — e.g. locked onto a stray dark
  /// blob or the wrong quadrant) rather than the physical sheet actually
  /// bending. Genuine paper bending affects spatially separated points
  /// (e.g. the far-apart dividerLeft/dividerRight, or centerAboveAnswers
  /// vs. centerBelowAnswers) differently, not identically — see [build]'s
  /// coherence check. No mesh is applied here: a uniformly-wrong
  /// homography can't be fixed by locally bending a few points, since the
  /// error isn't local. Callers should surface this as "check corner
  /// detection," not "flatten the paper."
  likelyMisregistered,
}

/// Piecewise-affine local correction built from a redesigned sheet's 9
/// fiducials (4 corners + 5 interior marks — see [OmrFiducialRole]).
///
/// The 4 corners already exactly satisfy the sheet's primary perspective
/// homography by construction (a homography fit from exactly 4 point
/// correspondences reproduces all 4 exactly, zero residual) — only the 5
/// interior points can show a genuine measured deviation from where the
/// single global homography predicts they should land after warping.
/// That deviation is a direct, local measurement of how much the sheet
/// deviates from a true plane at each of those 5 known interior locations.
///
/// This deliberately does NOT warp the whole image (no generic remap is
/// available in this app's OpenCV binding — see the decoder's own doc
/// comment on where this is invoked). Instead it triangulates the 9
/// (canonical, measured) point pairs into 10 fixed triangles and, for any
/// queried canonical page position (a bubble center, a name-field corner,
/// an overlay marker), finds which triangle contains it and applies that
/// triangle's own affine correction — a standard piecewise-affine mesh
/// warp, evaluated per query point rather than per pixel. Two triangles
/// that share an edge always share the exact same 2 (canonical, measured)
/// vertex pairs by construction, so the piecewise map has no seam/
/// discontinuity at any internal triangle boundary (affine maps agree
/// exactly along any line through 2 shared point correspondences).
///
/// Deliberately regularized rather than a free-form fit to noise: with
/// only 5 independent (sparse) interior measurements and 4 exactly-pinned
/// corners, the map can only bend as much as those 5 points actually show
/// evidence for — it cannot invent unsupported curvature between measured
/// points (each triangle interpolates linearly between its own 3 known
/// vertices), and a query point outside every triangle (should not happen
/// for real page content — see [correct]'s fallback) is clamped to the
/// nearest triangle rather than extrapolated arbitrarily.
class OmrMeshCorrection {
  /// Below this per-point residual (PDF points — see [build]'s doc comment
  /// on why classification is done in points, not raw canonical px), treat
  /// the capture as planar and skip the mesh entirely — retains the
  /// existing, already-validated global-homography-only behavior for the
  /// common case (a normal, only-mildly-imperfect capture), rather than
  /// adding warp noise where there's no real distortion to correct.
  /// Equivalent to 3px at the decoder's own 2px/pt bubble-scoring scale.
  static const double planarResidualPt = 1.5;

  /// Above this per-point residual (PDF points), the sheet's real bend is
  /// judged too severe for a reliable local correction from only 5 sparse
  /// interior points — flagged as [OmrMeshVerdict.tooSevere] instead of
  /// applying a mesh that would be extrapolating past what the evidence
  /// supports. Equivalent to 90px at the decoder's own 2px/pt scale.
  static const double maxTrustedResidualPt = 45.0;

  /// Fewer confidently-detected interior points than this and there simply
  /// isn't enough independent evidence to justify a local correction
  /// either way (see [OmrMeshVerdict.inconclusive]).
  static const int minConfidentInteriorPoints = 2;

  /// The [OmrMeshVerdict.likelyMisregistered] coherence check only fires
  /// above this mean residual (PDF points) — a genuinely tiny, coherent
  /// wobble is just measurement noise, not evidence of a wrong corner.
  static const double misregistrationMinMeanResidualPt = 6.0;

  /// How tightly the detected points' residual *vectors* (not just
  /// magnitudes) must agree, as a fraction of their mean magnitude, to
  /// call the pattern "coherent" (i.e. the whole frame looks uniformly
  /// shifted) rather than "varied" (consistent with independent local
  /// bending at each point). Lower = stricter (requires closer agreement
  /// before suspecting a wrong corner).
  static const double misregistrationCoherenceRatio = 0.35;

  /// Kill switch for the two behavior-changing consequences of trusting an
  /// interior-fiducial detection: applying the mesh warp ([isActive]) and
  /// rejecting a capture on measured evidence ([shouldRejectCapture]).
  /// [verdict]/[diagnostics] are always computed and logged (see
  /// [OmrDecoder.decode]'s `_fidLog` calls) regardless of this flag.
  ///
  /// Briefly set to false on 2026-09-15 after a field test found the
  /// interior-fiducial *detection* step (not the triangulation/
  /// classification math here, which is unit-tested and correct in
  /// isolation given accurate measured points) unreliable enough in
  /// practice to make the correction net-harmful — a flat-sheet capture
  /// showed a corrupted grid region (Section 2), and a genuinely bent sheet
  /// read worse, not better. Re-enabled the same day at the user's explicit
  /// request, with that root cause still open — re-scanning to collect
  /// `[OMR FIDUCIAL DEBUG]` diagnostics (already logged either way) is how
  /// it actually gets fixed, not leaving this off indefinitely.
  static const bool _correctionEnabled = true;

  final Map<OmrMeshVertex, OmrMeshPointStatus> points;
  final OmrMeshVerdict verdict;

  /// Worst (largest) residual among the 5 interior points, in PDF points
  /// (scale-invariant — see [build]'s doc comment on why classification is
  /// done in points rather than raw canonical px) — 0 when [verdict] is
  /// [OmrMeshVerdict.notApplicable].
  final double worstResidualPt;

  /// px-per-pt scale this correction was built at (`canonicalWidth /
  /// template.pageWidthPt`) — kept only so [diagnostics] can convert each
  /// point's raw [OmrMeshPointStatus.residualPx] back to PDF points for
  /// display, matching how [worstResidualPt] itself was computed.
  final double _pxPerPt;

  const OmrMeshCorrection._(this.points, this.verdict, this.worstResidualPt, this._pxPerPt);

  /// The 10-triangle fan topology (see this class' doc comment): each
  /// triangle is 3 [OmrMeshVertex] entries, canonical-winding not
  /// significant (barycentric containment doesn't care about winding).
  /// The outer rectangle (topLeft/topRight/bottomRight/bottomLeft) is
  /// split at the divider row (dividerLeft/dividerRight, further split by
  /// centerAtDivider) into a top pentagon fanned out from
  /// centerAboveAnswers and a bottom pentagon fanned out from
  /// centerBelowAnswers — not a plain 3x3 grid, because (matching the
  /// actual printed sheets) the top/bottom center marks sit well inside
  /// the outer corners' own row, not level with them (see
  /// generate_sheets.dart's `_atCenterFiducials`/`_qtmCenterFiducials`).
  static const List<List<OmrMeshVertex>> _triangles = [
    // Top pentagon (topLeft, topRight, dividerRight, centerAtDivider,
    // dividerLeft), fanned from centerAboveAnswers.
    [OmrMeshVertex.topLeft, OmrMeshVertex.topRight, OmrMeshVertex.centerAboveAnswers],
    [OmrMeshVertex.topRight, OmrMeshVertex.dividerRight, OmrMeshVertex.centerAboveAnswers],
    [OmrMeshVertex.dividerRight, OmrMeshVertex.centerAtDivider, OmrMeshVertex.centerAboveAnswers],
    [OmrMeshVertex.centerAtDivider, OmrMeshVertex.dividerLeft, OmrMeshVertex.centerAboveAnswers],
    [OmrMeshVertex.dividerLeft, OmrMeshVertex.topLeft, OmrMeshVertex.centerAboveAnswers],
    // Bottom pentagon (dividerLeft, centerAtDivider, dividerRight,
    // bottomRight, bottomLeft), fanned from centerBelowAnswers.
    [OmrMeshVertex.dividerLeft, OmrMeshVertex.centerAtDivider, OmrMeshVertex.centerBelowAnswers],
    [OmrMeshVertex.centerAtDivider, OmrMeshVertex.dividerRight, OmrMeshVertex.centerBelowAnswers],
    [OmrMeshVertex.dividerRight, OmrMeshVertex.bottomRight, OmrMeshVertex.centerBelowAnswers],
    [OmrMeshVertex.bottomRight, OmrMeshVertex.bottomLeft, OmrMeshVertex.centerBelowAnswers],
    [OmrMeshVertex.bottomLeft, OmrMeshVertex.dividerLeft, OmrMeshVertex.centerBelowAnswers],
  ];

  static OmrFiducialRole? _roleFor(OmrMeshVertex v) => switch (v) {
        OmrMeshVertex.dividerLeft => OmrFiducialRole.dividerLeft,
        OmrMeshVertex.dividerRight => OmrFiducialRole.dividerRight,
        OmrMeshVertex.centerAboveAnswers => OmrFiducialRole.centerAboveAnswers,
        OmrMeshVertex.centerAtDivider => OmrFiducialRole.centerAtDivider,
        OmrMeshVertex.centerBelowAnswers => OmrFiducialRole.centerBelowAnswers,
        _ => null,
      };

  /// Builds the mesh (or a no-op [OmrMeshVerdict.notApplicable]/
  /// [OmrMeshVerdict.inconclusive]/[OmrMeshVerdict.tooSevere] result) from:
  ///  - [template]'s 4 [OmrExamTemplate.cornerMarkers] and 0-5
  ///    [OmrExamTemplate.interiorFiducials], converted to canonical px;
  ///  - [cornersMeasuredPx]: the SAME 4 points' actual post-warp canonical
  ///    position (TL, TR, BL, BR order) — in practice these already equal
  ///    the canonical position exactly (see the class doc comment), but
  ///    are threaded through rather than assumed so a caller's own
  ///    re-detection is what's authoritative;
  ///  - [interiorMeasuredPx]: a canonical (x,y) per detected interior
  ///    fiducial (by [OmrFiducialRole]), or absent when that mark wasn't
  ///    confidently found in this photo.
  ///
  /// Residuals are classified in PDF points, not raw canonical px —
  /// [canonicalWidth] is only ever `template.pageWidthPt` scaled by some
  /// px-per-pt factor, and that factor differs between callers (the
  /// decoder's own bubble-scoring resolution vs. a display/overlay
  /// viewer's, which uses page points directly — see
  /// [fromMeasuredFractions]). Comparing raw px against a fixed threshold
  /// would make the *same* real-world bend classify differently (and
  /// therefore apply or skip the mesh differently) depending only on which
  /// caller asked — exactly the "OMR reading and overlay disagree" failure
  /// mode this type exists to prevent. Converting to points first (via
  /// `canonicalWidth / template.pageWidthPt`) makes classification agree
  /// regardless of caller/resolution.
  factory OmrMeshCorrection.build({
    required OmrExamTemplate template,
    required int canonicalWidth,
    required int canonicalHeight,
    required List<(double, double)> cornersMeasuredPx,
    required Map<OmrFiducialRole, (double, double)> interiorMeasuredPx,
  }) {
    if (template.interiorFiducials.isEmpty) {
      return const OmrMeshCorrection._({}, OmrMeshVerdict.notApplicable, 0, 0);
    }

    final canonicalByRole = <OmrFiducialRole, (double, double)>{
      for (final f in template.interiorFiducials)
        f.role: (f.xFrac * canonicalWidth, f.yFrac * canonicalHeight),
    };

    final corners = const [
      OmrMeshVertex.topLeft,
      OmrMeshVertex.topRight,
      OmrMeshVertex.bottomLeft,
      OmrMeshVertex.bottomRight,
    ];
    final points = <OmrMeshVertex, OmrMeshPointStatus>{};
    for (var i = 0; i < corners.length; i++) {
      final c = template.cornerMarkers[i];
      final canonicalPt = (c.xFrac * canonicalWidth, c.yFrac * canonicalHeight);
      final measuredPt = i < cornersMeasuredPx.length ? cornersMeasuredPx[i] : canonicalPt;
      points[corners[i]] = OmrMeshPointStatus(
        vertex: corners[i],
        canonicalX: canonicalPt.$1,
        canonicalY: canonicalPt.$2,
        measuredX: measuredPt.$1,
        measuredY: measuredPt.$2,
        wasDetected: true,
      );
    }

    // See this factory's doc comment: classification happens in PDF
    // points, not raw canonical px, so it agrees regardless of which
    // px-per-pt scale the caller built this correction at.
    final pxPerPt = canonicalWidth / template.pageWidthPt;

    var detectedInteriorCount = 0;
    var worstResidualPx = 0.0;
    // Residual *vectors* (not just magnitudes) for every detected point,
    // in PDF points — feeds the coherence check below. Never includes an
    // undetected point's canonical-fallback "residual" (which is exactly
    // 0 by construction and would silently pull the mean toward zero,
    // masking a real coherent shift among the points that WERE found).
    final detectedResidualVectorsPt = <(double dx, double dy)>[];
    for (final vertex in const [
      OmrMeshVertex.dividerLeft,
      OmrMeshVertex.dividerRight,
      OmrMeshVertex.centerAboveAnswers,
      OmrMeshVertex.centerAtDivider,
      OmrMeshVertex.centerBelowAnswers,
    ]) {
      final role = _roleFor(vertex)!;
      final canonicalPt = canonicalByRole[role];
      if (canonicalPt == null) continue; // template doesn't print this mark
      final measuredPt = interiorMeasuredPx[role];
      final detected = measuredPt != null;
      if (detected) detectedInteriorCount++;
      final resolvedMeasured = measuredPt ?? canonicalPt;
      final status = OmrMeshPointStatus(
        vertex: vertex,
        canonicalX: canonicalPt.$1,
        canonicalY: canonicalPt.$2,
        measuredX: resolvedMeasured.$1,
        measuredY: resolvedMeasured.$2,
        wasDetected: detected,
      );
      points[vertex] = status;
      if (detected) {
        if (status.residualPx > worstResidualPx) worstResidualPx = status.residualPx;
        if (pxPerPt > 0) {
          detectedResidualVectorsPt.add((
            (measuredPt.$1 - canonicalPt.$1) / pxPerPt,
            (measuredPt.$2 - canonicalPt.$2) / pxPerPt,
          ));
        }
      }
    }

    final worstResidualPt = pxPerPt > 0 ? worstResidualPx / pxPerPt : worstResidualPx;

    // Coherence check: do the detected points' residual *vectors* point
    // the same way by roughly the same amount? See
    // [OmrMeshVerdict.likelyMisregistered]'s doc comment for why that
    // pattern — rather than a large-but-varied one — points at a mismatched
    // outer corner instead of genuine local bending.
    var isCoherentShift = false;
    if (detectedResidualVectorsPt.length >= minConfidentInteriorPoints) {
      final meanDx = detectedResidualVectorsPt.map((v) => v.$1).reduce((a, b) => a + b) /
          detectedResidualVectorsPt.length;
      final meanDy = detectedResidualVectorsPt.map((v) => v.$2).reduce((a, b) => a + b) /
          detectedResidualVectorsPt.length;
      final meanMagPt = math.sqrt(meanDx * meanDx + meanDy * meanDy);
      final avgDeviationPt = detectedResidualVectorsPt
              .map((v) => math.sqrt(math.pow(v.$1 - meanDx, 2) + math.pow(v.$2 - meanDy, 2)))
              .reduce((a, b) => a + b) /
          detectedResidualVectorsPt.length;
      isCoherentShift = meanMagPt >= misregistrationMinMeanResidualPt &&
          avgDeviationPt <= misregistrationCoherenceRatio * meanMagPt;
    }

    final OmrMeshVerdict verdict;
    if (detectedInteriorCount < minConfidentInteriorPoints) {
      verdict = OmrMeshVerdict.inconclusive;
    } else if (isCoherentShift) {
      verdict = OmrMeshVerdict.likelyMisregistered;
    } else if (worstResidualPt > maxTrustedResidualPt) {
      verdict = OmrMeshVerdict.tooSevere;
    } else if (worstResidualPt <= planarResidualPt) {
      verdict = OmrMeshVerdict.planar;
    } else {
      verdict = OmrMeshVerdict.meshApplied;
    }
    return OmrMeshCorrection._(points, verdict, worstResidualPt, pxPerPt);
  }

  /// Whether [correct] does anything other than return its input
  /// unchanged — false for [OmrMeshVerdict.notApplicable],
  /// [OmrMeshVerdict.planar] (correction would be a no-op anyway),
  /// [OmrMeshVerdict.inconclusive], and [OmrMeshVerdict.tooSevere] (not
  /// trusted enough to apply). Also unconditionally false while
  /// [_correctionEnabled] is false — see its doc comment.
  bool get isActive => _correctionEnabled && verdict == OmrMeshVerdict.meshApplied;

  /// Maps one canonical-page pixel position (e.g. a [BubblePos]'s
  /// `xFrac * canonicalWidth`, `yFrac * canonicalHeight`) to its corrected
  /// position in the same canonical pixel space, accounting for the
  /// locally-measured bend at whichever triangle contains it. Returns
  /// `(x, y)` unchanged whenever [isActive] is false.
  (double, double) correct(double canonicalX, double canonicalY) {
    if (!isActive) return (canonicalX, canonicalY);

    List<double>? bestBary;
    double bestViolation = double.infinity;
    List<OmrMeshVertex>? bestTriangle;
    for (final tri in _triangles) {
      final p0 = points[tri[0]];
      final p1 = points[tri[1]];
      final p2 = points[tri[2]];
      if (p0 == null || p1 == null || p2 == null) continue;
      final bary = _barycentric(
        canonicalX,
        canonicalY,
        p0.canonicalX,
        p0.canonicalY,
        p1.canonicalX,
        p1.canonicalY,
        p2.canonicalX,
        p2.canonicalY,
      );
      if (bary == null) continue; // degenerate (near-zero-area) triangle
      final violation = bary.map((b) => b < 0 ? -b : 0.0).reduce((a, b) => a > b ? a : b);
      if (violation == 0) {
        // Strictly inside (or on an edge of) this triangle — use it
        // directly rather than searching further.
        return _apply(bary, p0, p1, p2);
      }
      if (violation < bestViolation) {
        bestViolation = violation;
        bestBary = bary;
        bestTriangle = tri;
      }
    }
    // Not inside any triangle (only possible right at the mesh's own
    // outer boundary, from floating-point rounding, or for a query point
    // outside the fiducial-bounded content area entirely) — clamp to the
    // least-violated triangle rather than leaving it uncorrected or
    // extrapolating an arbitrary amount.
    if (bestBary == null || bestTriangle == null) return (canonicalX, canonicalY);
    final clamped = bestBary.map((b) => b < 0 ? 0.0 : b).toList();
    final sum = clamped.reduce((a, b) => a + b);
    if (sum <= 0) return (canonicalX, canonicalY);
    final normalized = clamped.map((b) => b / sum).toList();
    return _apply(
      normalized,
      points[bestTriangle[0]]!,
      points[bestTriangle[1]]!,
      points[bestTriangle[2]]!,
    );
  }

  (double, double) _apply(
    List<double> bary,
    OmrMeshPointStatus p0,
    OmrMeshPointStatus p1,
    OmrMeshPointStatus p2,
  ) {
    final x = bary[0] * p0.measuredX + bary[1] * p1.measuredX + bary[2] * p2.measuredX;
    final y = bary[0] * p0.measuredY + bary[1] * p1.measuredY + bary[2] * p2.measuredY;
    return (x, y);
  }

  /// Barycentric coordinates of (`qx`,`qy`) relative to triangle
  /// (`x0`,`y0`)-(`x1`,`y1`)-(`x2`,`y2`). Null when the triangle is
  /// degenerate (near-zero area — its 3 canonical points are, by
  /// construction, always well-separated real fiducial positions, so this
  /// should not trigger in practice; guarded anyway rather than dividing
  /// by ~0).
  static List<double>? _barycentric(
    double qx,
    double qy,
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
  ) {
    final v0x = x1 - x0, v0y = y1 - y0;
    final v1x = x2 - x0, v1y = y2 - y0;
    final v2x = qx - x0, v2y = qy - y0;
    final d00 = v0x * v0x + v0y * v0y;
    final d01 = v0x * v1x + v0y * v1y;
    final d11 = v1x * v1x + v1y * v1y;
    final d20 = v2x * v0x + v2y * v0y;
    final d21 = v2x * v1x + v2y * v1y;
    final denom = d00 * d11 - d01 * d01;
    if (denom.abs() < 1e-6) return null;
    final b1 = (d11 * d20 - d01 * d21) / denom;
    final b2 = (d00 * d21 - d01 * d20) / denom;
    final b0 = 1 - b1 - b2;
    return [b0, b1, b2];
  }

  /// Exports the 5 interior points' measured position as page fractions
  /// (0-1, resolution-independent) keyed by [OmrFiducialRole] name —
  /// suitable for persisting on [OmrScanResult.meshInteriorMeasuredFrac] so
  /// a later screen (the graded-overlay viewer) can rebuild this exact
  /// same correction via [OmrMeshCorrection.fromMeasuredFractions] without
  /// re-running fiducial detection on the image. Only includes points that
  /// were actually [OmrMeshPointStatus.wasDetected] — an undetected point
  /// is reconstructed as "assume flat there" on rebuild too, the same
  /// fallback [build] itself uses.
  Map<String, (double, double)> toMeasuredFractions(int canonicalWidth, int canonicalHeight) {
    final out = <String, (double, double)>{};
    for (final entry in points.entries) {
      final role = _roleFor(entry.key);
      if (role == null) continue; // a corner, not an interior point
      if (!entry.value.wasDetected) continue;
      out[role.name] = (entry.value.measuredX / canonicalWidth, entry.value.measuredY / canonicalHeight);
    }
    return out;
  }

  /// Rebuilds an [OmrMeshCorrection] from fractions previously saved by
  /// [toMeasuredFractions] — the corners are always treated as exact
  /// (matching [build]'s own assumption that the primary homography
  /// already pins them), so only [measuredFrac] (interior points) is
  /// needed, not a fresh corner re-detection.
  factory OmrMeshCorrection.fromMeasuredFractions({
    required OmrExamTemplate template,
    required int canonicalWidth,
    required int canonicalHeight,
    required Map<String, (double, double)>? measuredFrac,
  }) {
    final interiorMeasuredPx = <OmrFiducialRole, (double, double)>{};
    if (measuredFrac != null) {
      for (final role in OmrFiducialRole.values) {
        final frac = measuredFrac[role.name];
        if (frac == null) continue;
        interiorMeasuredPx[role] = (frac.$1 * canonicalWidth, frac.$2 * canonicalHeight);
      }
    }
    return OmrMeshCorrection.build(
      template: template,
      canonicalWidth: canonicalWidth,
      canonicalHeight: canonicalHeight,
      cornersMeasuredPx: [
        for (final c in template.cornerMarkers) (c.xFrac * canonicalWidth, c.yFrac * canonicalHeight),
      ],
      interiorMeasuredPx: interiorMeasuredPx,
    );
  }

  /// User-facing summary of [verdict] for actionable capture feedback (see
  /// the OMR redesign spec's validation requirements) — distinguishes
  /// "not enough evidence" from "measured and it's fine" from "measured
  /// and it's too much to trust" from "the corners themselves look wrong."
  String? get userMessage => switch (verdict) {
        OmrMeshVerdict.notApplicable => null,
        OmrMeshVerdict.planar => null,
        OmrMeshVerdict.inconclusive =>
          'Could not confirm the sheet lies flat (interior alignment marks were not clearly visible) — the standard perspective correction was used. Retake with even lighting and the full sheet in frame for the most accurate reading.',
        OmrMeshVerdict.meshApplied =>
          'The sheet was not perfectly flat; a local correction (up to ${worstResidualPt.toStringAsFixed(1)}pt) was applied using its interior alignment marks. Note: most of these marks sit on the page\'s centerline, so this does not confirm alignment is correct everywhere — e.g. inside the side answer blocks, away from the centerline and the divider row.',
        OmrMeshVerdict.tooSevere =>
          'This sheet is bent more than can be reliably corrected (~${worstResidualPt.toStringAsFixed(1)}pt at its interior alignment marks). Flatten the sheet and retake.',
        OmrMeshVerdict.likelyMisregistered =>
          'The interior alignment marks are offset from where the outer corners predict, by a similar amount in the same direction — this usually means one of the 4 outer corner marks was matched to the wrong feature, not that the paper is bent. Retake with all four corner squares clearly visible and unobstructed.',
      };

  /// Whether this capture's geometry is unreliable enough that the caller
  /// should reject it outright (with [rejectionReason]) rather than score
  /// it against a known-questionable mapping — true only for
  /// [OmrMeshVerdict.tooSevere] and [OmrMeshVerdict.likelyMisregistered],
  /// both of which are *positive* evidence of a problem (a real,
  /// out-of-tolerance measurement), not merely an absence of evidence.
  /// [OmrMeshVerdict.inconclusive] deliberately never rejects — missing or
  /// obscured interior marks (poor lighting, a thumb near the divider)
  /// says nothing about whether the sheet is actually fine, and this
  /// should not by itself block an otherwise-good handheld capture. Also
  /// unconditionally false while [_correctionEnabled] is false — a
  /// rejection is just as much a behavior-changing consequence of trusting
  /// possibly-bad detections as applying a warp is, so it's suppressed for
  /// the same reason (see that field's doc comment).
  bool get shouldRejectCapture =>
      _correctionEnabled &&
      (verdict == OmrMeshVerdict.tooSevere || verdict == OmrMeshVerdict.likelyMisregistered);

  /// Actionable rejection message for [shouldRejectCapture] — null when
  /// there's nothing to reject.
  String? get rejectionReason => shouldRejectCapture ? userMessage : null;

  /// One diagnostic row per interior fiducial the template defines (empty
  /// for [OmrMeshVerdict.notApplicable]) — expected vs. detected position
  /// and residual, for logging/debugging. Deliberately keeps "missing"
  /// (nothing found near the expected position) and "displaced" (found,
  /// but not where expected) as distinct [OmrMeshPointDiagnostic.status]
  /// values rather than collapsing both into one "not confirmed" bucket —
  /// see that enum's doc comment for why the difference matters.
  List<OmrMeshPointDiagnostic> get diagnostics {
    final out = <OmrMeshPointDiagnostic>[];
    for (final vertex in const [
      OmrMeshVertex.dividerLeft,
      OmrMeshVertex.dividerRight,
      OmrMeshVertex.centerAboveAnswers,
      OmrMeshVertex.centerAtDivider,
      OmrMeshVertex.centerBelowAnswers,
    ]) {
      final status = points[vertex];
      if (status == null) continue; // template doesn't print this mark
      final residualPt = status.wasDetected && _pxPerPt > 0 ? status.residualPx / _pxPerPt : null;
      out.add(OmrMeshPointDiagnostic(
        vertex: vertex,
        expectedX: status.canonicalX,
        expectedY: status.canonicalY,
        detectedX: status.wasDetected ? status.measuredX : null,
        detectedY: status.wasDetected ? status.measuredY : null,
        residualPt: residualPt,
        status: !status.wasDetected
            ? OmrMeshPointDetectionStatus.missing
            : (residualPt != null && residualPt > planarResidualPt)
                ? OmrMeshPointDetectionStatus.displaced
                : OmrMeshPointDetectionStatus.confirmed,
      ));
    }
    return out;
  }

}
