import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/fiducial_coordinate_mapping.dart';

void main() {
  group('coverFit', () {
    test('wider destination than source scales by width and crops height', () {
      // Source is a tall 2x4 frame, destination is a wide 8x4 box -- cover
      // must scale up until the WIDTH matches, overshooting height, and
      // center the crop vertically.
      final fit = coverFit(const Size(2, 4), const Size(8, 4));
      expect(fit.scale, closeTo(4.0, 1e-9));
      // Rendered size is 8 x 16 inside an 8 x 4 box -> crops (16-4)/2 = 6 off
      // the top.
      expect(fit.topLeft.dx, closeTo(0, 1e-9));
      expect(fit.topLeft.dy, closeTo(-6.0, 1e-9));
    });

    test('taller destination than source scales by height and crops width', () {
      final fit = coverFit(const Size(4, 2), const Size(4, 8));
      expect(fit.scale, closeTo(4.0, 1e-9));
      expect(fit.topLeft.dy, closeTo(0, 1e-9));
      expect(fit.topLeft.dx, closeTo(-6.0, 1e-9));
    });

    test('matching aspect ratio has no crop and no offset', () {
      final fit = coverFit(const Size(4, 2), const Size(8, 4));
      expect(fit.scale, closeTo(2.0, 1e-9));
      expect(fit.topLeft, Offset.zero);
    });

    test('degenerate zero-area source falls back to identity instead of dividing by zero', () {
      final fit = coverFit(Size.zero, const Size(8, 4));
      expect(fit.scale, 1.0);
      expect(fit.topLeft, Offset.zero);
    });
  });

  group('fractionToWidgetOffset', () {
    test('maps the frame center to the destination center regardless of crop', () {
      final offset = fractionToWidgetOffset(
        fx: 0.5,
        fy: 0.5,
        sourceSize: const Size(2, 4),
        destSize: const Size(8, 4),
      );
      expect(offset.dx, closeTo(4.0, 1e-9));
      expect(offset.dy, closeTo(2.0, 1e-9));
    });

    test('maps a corner fraction consistently with the cover-fit crop', () {
      // Same 2x4 source in an 8x4 box as the coverFit test above: scale=4,
      // topLeft=(0,-6). The frame's own top-left (0,0) should land at
      // exactly that offset.
      final offset = fractionToWidgetOffset(
        fx: 0.0,
        fy: 0.0,
        sourceSize: const Size(2, 4),
        destSize: const Size(8, 4),
      );
      expect(offset.dx, closeTo(0.0, 1e-9));
      expect(offset.dy, closeTo(-6.0, 1e-9));
    });
  });

  group('widgetOffsetToFraction', () {
    test('is the exact inverse of fractionToWidgetOffset for an interior point', () {
      const sourceSize = Size(2, 4);
      const destSize = Size(8, 4);
      const originalFraction = (fx: 0.3, fy: 0.7);
      final widgetOffset = fractionToWidgetOffset(
        fx: originalFraction.fx,
        fy: originalFraction.fy,
        sourceSize: sourceSize,
        destSize: destSize,
      );
      final recovered = widgetOffsetToFraction(
        position: widgetOffset,
        sourceSize: sourceSize,
        destSize: destSize,
      );
      expect(recovered.dx, closeTo(originalFraction.fx, 1e-9));
      expect(recovered.dy, closeTo(originalFraction.fy, 1e-9));
    });

    test('clamps a tap position reported slightly outside the destination box', () {
      // BoxFit.cover always fully covers the destination box, so an
      // in-bounds tap can never itself land in a cropped-away margin --
      // but a gesture position a pixel or two outside the box (edge
      // rounding, or a drag that ends just past the boundary) must still
      // clamp to a valid [0,1] fraction instead of going negative or >1.
      final fraction = widgetOffsetToFraction(
        position: const Offset(-5, -10),
        sourceSize: const Size(2, 4),
        destSize: const Size(8, 4),
      );
      expect(fraction.dx, 0.0);
      expect(fraction.dy, 0.0);
    });

    test('degenerate zero-area source falls back to center instead of dividing by zero', () {
      final fraction = widgetOffsetToFraction(
        position: const Offset(4, 4),
        sourceSize: Size.zero,
        destSize: const Size(8, 4),
      );
      expect(fraction, const Offset(0.5, 0.5));
    });
  });

  group('searchedFrameSize', () {
    test('an unrotated search keeps the sensor-native (landscape) size as-is', () {
      const previewSize = Size(1920, 1080);
      final size = searchedFrameSize(previewSize, rotated90: false);
      expect(size, previewSize);
    });

    test('a 90-degree search rotation swaps width and height', () {
      const previewSize = Size(1920, 1080);
      final size = searchedFrameSize(previewSize, rotated90: true);
      expect(size, const Size(1080, 1920));
    });
  });
}
