// Plain-`dart` checks for lib/core/camera/camera_frame_adapter.dart — the
// pure frame/coordinate adapters between CamerAwesome's analysis frames and
// the OMR detector. Run with `dart tool/verify_camera_adapters.dart` (a
// direct `dart <file>` run, since `flutter test`/`dart run` cannot execute
// on this machine: the OpenCV native build hook needs CMake).
//
// These are logic tests of the adapters only — they say nothing about real
// camera frames, which still need on-device confirmation.
// ignore_for_file: avoid_print, avoid_relative_lib_imports
import 'dart:typed_data';

import '../lib/core/camera/camera_frame_adapter.dart';

var _failures = 0;

void check(String name, bool ok) {
  if (ok) {
    print('PASS  $name');
  } else {
    print('FAIL  $name');
    _failures++;
  }
}

bool near(double a, double b) => (a - b).abs() < 1e-9;

bool pointNear((double, double) p, double x, double y) =>
    near(p.$1, x) && near(p.$2, y);

void main() {
  // --- lumaFrameFromYPlane -------------------------------------------------
  final exact = Uint8List(8 * 4);
  var f = lumaFrameFromYPlane(
    bytes: exact, width: 8, height: 4, rowStride: 8, pixelStride: 1,
  );
  check('tight plane passes through unchanged (same buffer)',
      f != null && identical(f.bytes, exact) && f.bytesPerRow == 8);

  final padded = Uint8List(10 * 4);
  f = lumaFrameFromYPlane(
    bytes: padded, width: 8, height: 4, rowStride: 10, pixelStride: 1,
  );
  check('padded rows keep the row stride as bytesPerRow',
      f != null && f.bytesPerRow == 10 && f.bytes.length == 40);

  // Buffer stops after the last pixel (no trailing padding on the last row).
  final shortLast = Uint8List(10 * 3 + 8);
  for (var i = 0; i < shortLast.length; i++) {
    shortLast[i] = i % 251;
  }
  f = lumaFrameFromYPlane(
    bytes: shortLast, width: 8, height: 4, rowStride: 10, pixelStride: 1,
  );
  check('short final row is padded to height*rowStride',
      f != null && f.bytes.length == 40);
  check('padding preserves original samples',
      f != null && f.bytes[0] == 0 && f.bytes[37] == 37 % 251);

  final long = Uint8List(10 * 4 + 100);
  f = lumaFrameFromYPlane(
    bytes: long, width: 8, height: 4, rowStride: 10, pixelStride: 1,
  );
  check('oversized buffer is trimmed to height*rowStride (view, no copy)',
      f != null && f.bytes.length == 40);

  check('pixelStride != 1 is rejected',
      lumaFrameFromYPlane(bytes: Uint8List(64), width: 8, height: 4,
          rowStride: 16, pixelStride: 2) == null);
  check('missing (0) pixelStride is rejected',
      lumaFrameFromYPlane(bytes: Uint8List(32), width: 8, height: 4,
          rowStride: 8, pixelStride: 0) == null);
  check('rowStride smaller than width is rejected',
      lumaFrameFromYPlane(bytes: Uint8List(32), width: 8, height: 4,
          rowStride: 7, pixelStride: 1) == null);
  check('buffer too short for the last pixel is rejected',
      lumaFrameFromYPlane(bytes: Uint8List(10 * 3 + 7), width: 8, height: 4,
          rowStride: 10, pixelStride: 1) == null);
  check('non-positive size is rejected',
      lumaFrameFromYPlane(bytes: Uint8List(0), width: 0, height: 4,
          rowStride: 0, pixelStride: 1) == null);

  // --- uprightSize ---------------------------------------------------------
  check('uprightSize 0 keeps shape',
      uprightSize(1920, 1080, 0) == (width: 1920, height: 1080));
  check('uprightSize 90 swaps',
      uprightSize(1920, 1080, 90) == (width: 1080, height: 1920));
  check('uprightSize 180 keeps shape',
      uprightSize(1920, 1080, 180) == (width: 1920, height: 1080));
  check('uprightSize 270 swaps',
      uprightSize(1920, 1080, 270) == (width: 1080, height: 1920));
  check('uprightSize normalizes -90',
      uprightSize(1920, 1080, -90) == (width: 1080, height: 1920));

  // --- detector rotation -> raw -------------------------------------------
  // A point at raw (0.25, 0.75) rotated CW becomes (1-0.75, 0.25) = (0.25,
  // 0.25) in the detector frame; mapping back must recover it.
  check('detector CW inverse recovers raw point',
      pointNear(detectorFractionToRaw(0.25, 0.25, DetectorRotation.clockwise90),
          0.25, 0.75));
  // CCW: (x, y) -> (y, 1-x) = (0.75, 0.75).
  check('detector CCW inverse recovers raw point',
      pointNear(
          detectorFractionToRaw(0.75, 0.75, DetectorRotation.counterClockwise90),
          0.25, 0.75));
  check('detector none is identity',
      pointNear(detectorFractionToRaw(0.3, 0.6, DetectorRotation.none), 0.3, 0.6));

  // Round trip for many points and both rotations.
  var roundTripOk = true;
  for (var x = 0.0; x <= 1.0; x += 0.125) {
    for (var y = 0.0; y <= 1.0; y += 0.125) {
      final cw = (1 - y, x);
      final ccw = (y, 1 - x);
      final backCw = detectorFractionToRaw(cw.$1, cw.$2, DetectorRotation.clockwise90);
      final backCcw = detectorFractionToRaw(ccw.$1, ccw.$2, DetectorRotation.counterClockwise90);
      if (!pointNear(backCw, x, y) || !pointNear(backCcw, x, y)) {
        roundTripOk = false;
      }
    }
  }
  check('detector rotation round trip (81 points x 2 rotations)', roundTripOk);

  // --- raw -> upright ------------------------------------------------------
  // Raw top-left corner of a sensor buffer that must be rotated 90 deg
  // clockwise to be upright ends up at the upright top-right.
  check('raw TL at rotation 90 -> upright TR',
      pointNear(rawFractionToUpright(0, 0, 90), 1, 0));
  check('raw TL at rotation 180 -> upright BR',
      pointNear(rawFractionToUpright(0, 0, 180), 1, 1));
  check('raw TL at rotation 270 -> upright BL',
      pointNear(rawFractionToUpright(0, 0, 270), 0, 1));
  check('raw TL at rotation 0 -> identity',
      pointNear(rawFractionToUpright(0, 0, 0), 0, 0));
  // Four successive 90 degree rotations return to the start.
  var p = (0.2, 0.7);
  for (var i = 0; i < 4; i++) {
    p = rawFractionToUpright(p.$1, p.$2, 90);
  }
  check('four 90-degree rotations are the identity', pointNear(p, 0.2, 0.7));

  // --- crop ---------------------------------------------------------------
  check('null crop is identity',
      pointNear(rawFractionToCropFraction(0.4, 0.6, rawWidth: 100, rawHeight: 50), 0.4, 0.6));
  final crop = (left: 10.0, top: 0.0, right: 90.0, bottom: 50.0);
  check('crop re-expresses a fraction of the visible region',
      pointNear(rawFractionToCropFraction(0.5, 0.5,
          rawWidth: 100, rawHeight: 50, crop: crop), 0.5, 0.5));
  check('a point at the crop edge maps to 0',
      pointNear(rawFractionToCropFraction(0.1, 0.0,
          rawWidth: 100, rawHeight: 50, crop: crop), 0.0, 0.0));
  check('a point outside the crop maps outside 0-1',
      rawFractionToCropFraction(0.0, 0.5,
          rawWidth: 100, rawHeight: 50, crop: crop).$1 < 0);
  check('full-frame crop is detected',
      cropIsFullFrame(100, 50, (left: 0, top: 0, right: 100, bottom: 50)));
  check('partial crop is not full-frame', !cropIsFullFrame(100, 50, crop));
  check('null crop counts as full-frame', cropIsFullFrame(100, 50, null));

  // --- cropLumaFrame: only the visible region is searched ------------------
  // Use a buffer big enough to clear cropLumaFrame's 16px minimum.
  const bigW = 40, bigH = 60, bigStride = 48;
  final big = Uint8List(bigStride * bigH);
  for (var r = 0; r < bigH; r++) {
    for (var c = 0; c < bigW; c++) {
      big[r * bigStride + c] = (r * 7 + c) % 251;
    }
  }
  final bigFrame = LumaFrame(bytes: big, width: bigW, height: bigH, bytesPerRow: bigStride);
  final cropped = cropLumaFrame(bigFrame, (left: 4, top: 10, right: 36, bottom: 50));
  check('crop has the crop rectangle\'s size',
      cropped.width == 32 && cropped.height == 40 && cropped.bytesPerRow == 32);
  check('crop buffer is tightly packed', cropped.bytes.length == 32 * 40);
  var pixelsMatch = true;
  for (var r = 0; r < 40 && pixelsMatch; r++) {
    for (var c = 0; c < 32; c++) {
      if (cropped.bytes[r * 32 + c] != big[(10 + r) * bigStride + 4 + c]) {
        pixelsMatch = false;
        break;
      }
    }
  }
  check('crop copies exactly the visible pixels (stride respected)', pixelsMatch);
  check('null crop returns the same frame', identical(cropLumaFrame(bigFrame, null), bigFrame));
  check('full-frame crop returns the same frame',
      identical(cropLumaFrame(bigFrame, (left: 0, top: 0, right: 40, bottom: 60)), bigFrame));
  check('a degenerate crop is ignored',
      identical(cropLumaFrame(bigFrame, (left: 5, top: 5, right: 9, bottom: 9)), bigFrame));
  check('an out-of-range crop is clamped, not thrown on',
      cropLumaFrame(bigFrame, (left: -5, top: 20, right: 100, bottom: 60)).width == 40);
  // The device's real geometry: 1080x1080 raw, crop 1080x608, rotated 90 =
  // portrait 608x1080 -- the preview's 9:16 shape.
  final cropUpright = uprightSize(1080, 608, 90);
  check('real device crop becomes a 9:16 portrait frame',
      sameAspect(cropUpright.width.toDouble(), cropUpright.height.toDouble(), 1080, 1920));
  check('uncropped real device buffer is NOT the preview\'s shape',
      !sameAspect(1080, 1080, 1080, 1920));

  // --- aspect --------------------------------------------------------------
  check('16:9 vs 16:9 same aspect', sameAspect(1920, 1080, 1280, 720));
  check('16:9 vs 4:3 differ', !sameAspect(1920, 1080, 1600, 1200));
  check('rotated shapes differ', !sameAspect(1920, 1080, 1080, 1920));
  check('zero size is never the same aspect', !sameAspect(0, 1080, 1, 1));

  print(_failures == 0 ? '\nAll checks passed.' : '\n$_failures check(s) FAILED.');
  if (_failures != 0) throw StateError('$_failures failed');
}
