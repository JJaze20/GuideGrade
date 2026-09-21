/// Pure-Dart adapters between CamerAwesome's image-analysis frames and the
/// OMR detector's input contract (`OmrDecoder.checkCornersFromLuma`: a luma
/// plane plus its width, height and row stride, in the camera's raw sensor
/// orientation — the detector does its own rotation search).
///
/// Deliberately free of flutter/opencv/camerawesome imports so the logic can
/// be exercised under a plain `dart` run (`tool/verify_camera_adapters.dart`)
/// on a machine where `flutter test` cannot run (the OpenCV native build hook
/// needs CMake). Nothing here touches detector mathematics.
library;

import 'dart:typed_data';

/// A luma (Y) plane laid out the way `Mat.fromList(height, bytesPerRow, ...)`
/// requires: exactly `height * bytesPerRow` bytes.
class LumaFrame {
  final Uint8List bytes;
  final int width;
  final int height;
  final int bytesPerRow;

  const LumaFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
  });
}

/// Validates a raw Y plane from a YUV_420_888 analysis frame and returns it in
/// the exact shape the detector needs, or null if it can't be used safely
/// (better to skip one live frame than to hand OpenCV a mis-strided buffer).
///
/// Checked, not assumed:
///  * `pixelStride` must be 1 — a Y plane with interleaved pixels would make
///    `bytesPerRow`-based indexing read the wrong samples.
///  * `rowStride` must cover a full row.
///  * The buffer must reach the last pixel of the last row. Camera buffers
///    commonly omit the final row's trailing padding, so a buffer up to
///    `rowStride - width` bytes shorter than `rowStride * height` is padded
///    (a copy, rare and small); a longer one is trimmed with a zero-copy view.
LumaFrame? lumaFrameFromYPlane({
  required Uint8List bytes,
  required int width,
  required int height,
  required int rowStride,
  required int pixelStride,
}) {
  if (width <= 0 || height <= 0) return null;
  if (pixelStride != 1) return null;
  if (rowStride < width) return null;
  final minLength = rowStride * (height - 1) + width;
  if (bytes.length < minLength) return null;
  final fullLength = rowStride * height;
  final Uint8List exact;
  if (bytes.length == fullLength) {
    exact = bytes;
  } else if (bytes.length > fullLength) {
    exact = Uint8List.sublistView(bytes, 0, fullLength);
  } else {
    exact = Uint8List(fullLength)..setRange(0, bytes.length, bytes);
  }
  return LumaFrame(
    bytes: exact,
    width: width,
    height: height,
    bytesPerRow: rowStride,
  );
}

/// Which rotation the live detector applied to the raw frame before its
/// winning search (mirrors `FrameRotation` in omr_alignment_check.dart, kept
/// separate so this file has no dependencies).
enum DetectorRotation { none, clockwise90, counterClockwise90 }

/// The size of the frame after rotating a `rawWidth x rawHeight` buffer
/// clockwise by [rotationDegrees] (0/90/180/270) — i.e. the upright display
/// frame CamerAwesome reports rotation for.
({int width, int height}) uprightSize(
  int rawWidth,
  int rawHeight,
  int rotationDegrees,
) {
  final swapped = _normalize(rotationDegrees) % 180 == 90;
  return swapped
      ? (width: rawHeight, height: rawWidth)
      : (width: rawWidth, height: rawHeight);
}

/// Maps a point given as a fraction (0-1) of the detector's winning-
/// orientation frame back to a fraction of the raw sensor buffer, undoing the
/// rotation `checkCornersFromLuma` applied before searching.
(double, double) detectorFractionToRaw(
  double fx,
  double fy,
  DetectorRotation rotation,
) {
  switch (rotation) {
    case DetectorRotation.none:
      return (fx, fy);
    // cv.rotate(CLOCKWISE): (x, y) -> (1 - y, x) in fractions; inverse below.
    case DetectorRotation.clockwise90:
      return (fy, 1 - fx);
    // cv.rotate(COUNTERCLOCKWISE): (x, y) -> (y, 1 - x); inverse below.
    case DetectorRotation.counterClockwise90:
      return (1 - fy, fx);
  }
}

/// Maps a raw-buffer fraction to a fraction of the upright display frame,
/// given the clockwise rotation (degrees) CamerAwesome reports for the frame.
(double, double) rawFractionToUpright(
  double fx,
  double fy,
  int rotationDegrees,
) {
  switch (_normalize(rotationDegrees)) {
    case 90:
      return (1 - fy, fx);
    case 180:
      return (1 - fx, 1 - fy);
    case 270:
      return (fy, 1 - fx);
    default:
      return (fx, fy);
  }
}

/// Re-expresses a fraction of the FULL raw buffer as a fraction of the
/// visible (cropped) region, when CameraX cropped the analysis frame to match
/// the preview. [crop] is in raw-buffer pixels. A null or full-frame crop is
/// the identity. Returns null-safe values clamped only by the caller (a
/// point outside the crop legitimately maps outside 0-1).
(double, double) rawFractionToCropFraction(
  double fx,
  double fy, {
  required int rawWidth,
  required int rawHeight,
  ({double left, double top, double right, double bottom})? crop,
}) {
  if (crop == null) return (fx, fy);
  final cw = crop.right - crop.left;
  final ch = crop.bottom - crop.top;
  if (cw <= 0 || ch <= 0) return (fx, fy);
  return ((fx * rawWidth - crop.left) / cw, (fy * rawHeight - crop.top) / ch);
}

/// True when [crop] covers the whole raw buffer (within a pixel), i.e. the
/// analysis frame and the preview show the same field of view.
bool cropIsFullFrame(
  int rawWidth,
  int rawHeight,
  ({double left, double top, double right, double bottom})? crop,
) {
  if (crop == null) return true;
  return crop.left.abs() < 1 &&
      crop.top.abs() < 1 &&
      (crop.right - rawWidth).abs() < 1 &&
      (crop.bottom - rawHeight).abs() < 1;
}

/// Whether two frame shapes have the same aspect ratio within [tolerance]
/// (relative). CamerAwesome's analysis and preview streams are configured
/// separately, so this is checked rather than assumed before a detector
/// fraction is drawn over the preview.
bool sameAspect(
  double aWidth,
  double aHeight,
  double bWidth,
  double bHeight, {
  double tolerance = 0.02,
}) {
  if (aWidth <= 0 || aHeight <= 0 || bWidth <= 0 || bHeight <= 0) return false;
  final a = aWidth / aHeight;
  final b = bWidth / bHeight;
  return (a / b - 1).abs() <= tolerance;
}

int _normalize(int degrees) => ((degrees % 360) + 360) % 360;

/// Crops [frame] to the region the camera actually shows and captures.
///
/// CameraX may hand the analysis stream a larger buffer than the preview and
/// the still photo cover, and describe the visible part with a crop rectangle
/// (in raw-buffer pixels, before rotation). Confirmed on a real device: a
/// 1080x1080 buffer whose crop rect was 1080x608, i.e. only the middle band is
/// the picture the user sees and photographs. Detecting corners in the WHOLE
/// buffer let the live check turn green on marks that sit outside the visible
/// region, while the captured photo cut them off — so the live guide said
/// "aligned" and every capture was then rejected.
///
/// Returns [frame] itself when there is nothing to crop (no rectangle, the
/// whole buffer, or a rectangle too small to trust), otherwise a new,
/// tightly packed frame (`bytesPerRow == width`) holding only the visible
/// region. Rotation is untouched: the rectangle is in the raw orientation,
/// like [frame].
LumaFrame cropLumaFrame(
  LumaFrame frame,
  ({double left, double top, double right, double bottom})? crop,
) {
  if (crop == null || cropIsFullFrame(frame.width, frame.height, crop)) return frame;
  final left = crop.left.round().clamp(0, frame.width - 1);
  final top = crop.top.round().clamp(0, frame.height - 1);
  final right = crop.right.round().clamp(left + 1, frame.width);
  final bottom = crop.bottom.round().clamp(top + 1, frame.height);
  final w = right - left;
  final h = bottom - top;
  if (w < 16 || h < 16) return frame;
  final out = Uint8List(w * h);
  for (var row = 0; row < h; row++) {
    final src = (top + row) * frame.bytesPerRow + left;
    out.setRange(row * w, row * w + w, frame.bytes, src);
  }
  return LumaFrame(bytes: out, width: w, height: h, bytesPerRow: w);
}
