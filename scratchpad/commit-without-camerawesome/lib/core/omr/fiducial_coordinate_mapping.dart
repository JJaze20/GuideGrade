/// Pure coordinate-mapping helpers for the live fiducial diagnostic overlay
/// (see `ExamScanningScreen`'s `_diagnosticsEnabled`). Deliberately
/// dependency-free — no opencv_dart or camera import — so this logic can be
/// unit-tested on its own; a file that transitively imports opencv_dart
/// currently can't be exercised by a plain `flutter test` run in this
/// project's dev environment (opencv_dart's dartcv4 native build hooks run
/// even for unrelated tests and fail without a CMake/MSVC toolchain on
/// PATH), so keeping this math isolated is what makes it testable at all.
///
/// ASSUMPTION requiring on-device confirmation (see the diagnostic
/// overlay's own on-screen caption, and the doc comment on
/// `OmrDecoder.checkCornersFromLuma`'s returned `rotation`): whichever of
/// the 3 orientations the live corner search tried actually matched the
/// sheet is treated as the SAME orientation the camera plugin renders the
/// upright preview in, so a detected point's fraction in that winning
/// orientation is used directly against the preview's own logical
/// (already-oriented) size — no separate un-rotation step. Both the search
/// and the platform preview are correcting the same raw sensor buffer to
/// "upright as the user is holding the phone", so they should agree, but
/// this hasn't been confirmed against a real device: if the overlay's dots
/// consistently land rotated/mirrored relative to the fixed aim guides
/// while the guides themselves are correctly aimed at the physical marks,
/// that assumption is the first thing to check.
library;

import 'dart:math' as math;
import 'dart:ui';

/// The scale factor and top-left offset at which a [sourceSize] image
/// renders when displayed with `BoxFit.cover` inside a [destSize] box —
/// the exact fit `ExamScanningScreen._buildCameraLayer` uses for the live
/// camera preview. Shared here so the diagnostic overlay maps a detected
/// point through the identical crop/scale the preview itself uses, instead
/// of a separately-maintained approximation that could quietly drift from
/// it. Degenerate (zero-area) [sourceSize] returns an identity fit rather
/// than dividing by zero.
({double scale, Offset topLeft}) coverFit(Size sourceSize, Size destSize) {
  if (sourceSize.width <= 0 || sourceSize.height <= 0) {
    return (scale: 1.0, topLeft: Offset.zero);
  }
  final scale = math.max(
    destSize.width / sourceSize.width,
    destSize.height / sourceSize.height,
  );
  final renderedWidth = sourceSize.width * scale;
  final renderedHeight = sourceSize.height * scale;
  return (
    scale: scale,
    topLeft: Offset(
      (destSize.width - renderedWidth) / 2,
      (destSize.height - renderedHeight) / 2,
    ),
  );
}

/// Maps a normalized (0-1) fraction of [sourceSize] (the live corner
/// search's winning-orientation frame — see this library's own doc comment
/// for the orientation assumption) to a widget-local pixel [Offset] within
/// a [destSize] viewfinder displaying that frame with `BoxFit.cover` (see
/// [coverFit]).
Offset fractionToWidgetOffset({
  required double fx,
  required double fy,
  required Size sourceSize,
  required Size destSize,
}) {
  final fit = coverFit(sourceSize, destSize);
  return Offset(
    fit.topLeft.dx + fx * sourceSize.width * fit.scale,
    fit.topLeft.dy + fy * sourceSize.height * fit.scale,
  );
}

/// Inverse of [fractionToWidgetOffset]: maps a widget-local pixel
/// [position] (e.g. a tap on the viewfinder) back to a normalized (0-1)
/// fraction of [sourceSize], for the identical `BoxFit.cover` fit (see
/// [coverFit]). Used for tap-to-focus — the `camera` plugin's
/// `setFocusPoint`/`setExposurePoint` both take a (0,0)-(1,1) fraction of
/// the *displayed preview*, not raw widget pixels. Clamps to [0,1] since a
/// tap can land in the letterboxed/cropped-out margin `BoxFit.cover`
/// leaves outside the actual image on one axis.
Offset widgetOffsetToFraction({
  required Offset position,
  required Size sourceSize,
  required Size destSize,
}) {
  final fit = coverFit(sourceSize, destSize);
  if (fit.scale <= 0 || sourceSize.width <= 0 || sourceSize.height <= 0) {
    return const Offset(0.5, 0.5);
  }
  final fx = (position.dx - fit.topLeft.dx) / (sourceSize.width * fit.scale);
  final fy = (position.dy - fit.topLeft.dy) / (sourceSize.height * fit.scale);
  return Offset(fx.clamp(0.0, 1.0), fy.clamp(0.0, 1.0));
}

/// The logical (already display-oriented) size of the frame a live corner
/// search actually ran against, derived from the camera's own reported
/// preview size plus which rotation the search applied.
/// [reportedPreviewSize] is the sensor's landscape-native size (see
/// `ExamScanningScreen._buildCameraLayer`'s doc comment on
/// `previewSize`) — a 90° search rotation swaps it to match, no rotation
/// leaves it as-is (the frame the search saw was landscape-native itself,
/// same as an un-rotated preview would be).
Size searchedFrameSize(Size reportedPreviewSize, {required bool rotated90}) {
  return rotated90
      ? Size(reportedPreviewSize.height, reportedPreviewSize.width)
      : reportedPreviewSize;
}
