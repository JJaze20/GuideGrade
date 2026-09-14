/// Shared sizing for the fiducial "Stage-1" search prior — the box a user
/// aims each corner at in the live viewfinder, and the actual first-look
/// search region the decoder scores candidates against. Single source of
/// truth so the two can never drift apart (see `omr_decoder_native.dart`'s
/// `_quadrantsFor`/`_findMarkerInRegion` and `exam_scanning_screen.dart`'s
/// `_PageGuidePainter`).
///
/// This is a *prior*, never a hard boundary or a classification rule: a
/// miss inside this box always falls through to the full-quadrant Stage-2
/// search (unchanged), and every candidate found here — inside the box or
/// out — still has to clear the same squareness/contrast/area/position
/// scoring, the same answer-grid exclusion, and the same 4-marker geometry
/// cross-check as before. Enlarging this only changes how generous the
/// *fast path* is about where the user positions the physical sheet; it
/// does not loosen what counts as a real fiducial square.
library;

/// Half-extent of the Stage-1 search box, as a fraction of the shorter
/// dimension of whatever frame it's measured against (the raw captured/
/// live-preview image for the detector, the on-screen guide rectangle for
/// the UI viewfinder) — full box side = `2 * kFiducialSearchHalfExtentFrac`
/// of that dimension.
///
/// Doubled from the original 0.12 (24% box side) to 0.24 (48% box side) —
/// a starting value for real handheld/perspective-capture testing, per the
/// explicit ask for noticeably more positioning freedom than the original
/// tight box allowed. Tune here only; nothing else needs to change to
/// adjust this further.
const double kFiducialSearchHalfExtentFrac = 0.24;

/// How close to the expected corner position a candidate must be to score
/// well on *position* — expressed the same way as
/// [kFiducialSearchHalfExtentFrac] (fraction of the shorter image
/// dimension) but deliberately kept independent of it.
///
/// `_findMarkerInRegion`'s position score is `exp(-distance/anchorScale)`,
/// and until this constant existed `anchorScale` was derived directly from
/// the size of whatever region was being searched — which meant doubling
/// [kFiducialSearchHalfExtentFrac] to give users more room to position the
/// sheet *also* doubled how forgiving position-scoring was within that
/// larger box, silently loosening candidate ranking exactly where the
/// squareness/contrast gates are supposed to be doing the real work.
/// Confirmed on a real device: enlarging the search box alone caused two
/// corners on a busier sheet (TAT, which has header text/ID-table clutter
/// near the top corners) to stop being found at all — a nearby non-marker
/// blob was now scored competitively simply because the position penalty
/// for being far from the true anchor had also grown.
///
/// Kept at the *original* (pre-enlargement) tolerance so the true corner
/// is still preferred just as strongly as before, regardless of how large
/// the box someone is allowed to place it within has become — the search
/// AREA is what changed, not what "close to the expected spot" means.
const double kFiducialAnchorToleranceFrac = 0.12;

/// Live-viewfinder box size, as a fraction of the on-screen guide
/// rectangle's shorter side (see `_PageGuidePainter`), before the pixel
/// clamp below. Doubled alongside [kFiducialSearchHalfExtentFrac] so the
/// visual box a user aims for actually reflects the larger search area,
/// not just the underlying detector tolerance.
const double kFiducialViewfinderBoxSizeFraction = 0.34;

/// Pixel clamp on the rendered viewfinder box size — keeps it legible on a
/// small phone and not absurd on a tablet. Doubled from the original
/// [46, 92] range alongside the fraction above; on most phones the
/// fraction alone would otherwise be silently absorbed by a too-low
/// ceiling and the box would look no different from before.
const double kFiducialViewfinderBoxMinSize = 92;
const double kFiducialViewfinderBoxMaxSize = 184;
