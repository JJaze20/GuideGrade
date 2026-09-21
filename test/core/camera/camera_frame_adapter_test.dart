import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/camera/camera_frame_adapter.dart';

void main() {
  group('lumaFrameFromYPlane', () {
    test('passes a tight plane through without copying', () {
      final bytes = Uint8List(8 * 4);
      final f = lumaFrameFromYPlane(
          bytes: bytes, width: 8, height: 4, rowStride: 8, pixelStride: 1);
      expect(f, isNotNull);
      expect(identical(f!.bytes, bytes), isTrue);
      expect(f.bytesPerRow, 8);
    });

    test('keeps the row stride and pads a short final row', () {
      final bytes = Uint8List(10 * 3 + 8);
      final f = lumaFrameFromYPlane(
          bytes: bytes, width: 8, height: 4, rowStride: 10, pixelStride: 1);
      expect(f!.bytesPerRow, 10);
      expect(f.bytes.length, 40);
    });

    test('trims an oversized buffer', () {
      final f = lumaFrameFromYPlane(
          bytes: Uint8List(140),
          width: 8,
          height: 4,
          rowStride: 10,
          pixelStride: 1);
      expect(f!.bytes.length, 40);
    });

    test('rejects unusable planes', () {
      expect(
          lumaFrameFromYPlane(
              bytes: Uint8List(64),
              width: 8,
              height: 4,
              rowStride: 16,
              pixelStride: 2),
          isNull);
      expect(
          lumaFrameFromYPlane(
              bytes: Uint8List(32),
              width: 8,
              height: 4,
              rowStride: 8,
              pixelStride: 0),
          isNull);
      expect(
          lumaFrameFromYPlane(
              bytes: Uint8List(32),
              width: 8,
              height: 4,
              rowStride: 7,
              pixelStride: 1),
          isNull);
      expect(
          lumaFrameFromYPlane(
              bytes: Uint8List(37),
              width: 8,
              height: 4,
              rowStride: 10,
              pixelStride: 1),
          isNull);
    });
  });

  group('coordinate adapters', () {
    test('uprightSize swaps for 90 and 270 only', () {
      expect(uprightSize(1920, 1080, 90), (width: 1080, height: 1920));
      expect(uprightSize(1920, 1080, 270), (width: 1080, height: 1920));
      expect(uprightSize(1920, 1080, 0), (width: 1920, height: 1080));
      expect(uprightSize(1920, 1080, 180), (width: 1920, height: 1080));
    });

    test('detector rotation inverse recovers the raw point', () {
      expect(detectorFractionToRaw(0.25, 0.25, DetectorRotation.clockwise90),
          (0.25, 0.75));
      expect(
          detectorFractionToRaw(
              0.75, 0.75, DetectorRotation.counterClockwise90),
          (0.25, 0.75));
    });

    test('raw corners map to the expected upright corners', () {
      expect(rawFractionToUpright(0, 0, 90), (1.0, 0.0));
      expect(rawFractionToUpright(0, 0, 180), (1.0, 1.0));
      expect(rawFractionToUpright(0, 0, 270), (0.0, 1.0));
    });

    test('crop handling', () {
      const crop = (left: 10.0, top: 0.0, right: 90.0, bottom: 50.0);
      expect(
          rawFractionToCropFraction(0.5, 0.5,
              rawWidth: 100, rawHeight: 50, crop: crop),
          (0.5, 0.5));
      expect(cropIsFullFrame(100, 50, crop), isFalse);
      expect(cropIsFullFrame(100, 50, null), isTrue);
    });

    test('sameAspect', () {
      expect(sameAspect(1920, 1080, 1280, 720), isTrue);
      expect(sameAspect(1920, 1080, 1600, 1200), isFalse);
    });
  });
}
