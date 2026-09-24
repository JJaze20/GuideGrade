import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_mesh_correction.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/omr/tat_marker_validation.dart';

/// Pure-geometry checks for the portrait TAT v5 scanning path. Real-photo
/// accuracy is NOT covered here (needs device captures).
void main() {
  final t = omrTemplates['TAT']!;

  OmrMeshCorrection build(Map<OmrFiducialRole, (double, double)> measured) =>
      OmrMeshCorrection.build(
        template: t,
        canonicalWidth: t.pageWidthPt.round(),
        canonicalHeight: t.pageHeightPt.round(),
        cornersMeasuredPx: [
          for (final c in t.cornerMarkers) (c.xFrac * t.pageWidthPt, c.yFrac * t.pageHeightPt),
        ],
        interiorMeasuredPx: measured,
      );

  final printed = {
    for (final f in t.interiorFiducials) f.role: (f.xFrac * t.pageWidthPt, f.yFrac * t.pageHeightPt),
  };

  group('TAT portrait v5 registration', () {
    test('is the portrait 612x936 sheet with ten interior marks', () {
      expect(t.templateVersion, 'TAT-portrait-v5');
      expect(t.pageWidthPt, lessThan(t.pageHeightPt));
      expect(t.interiorFiducials.length, 10);
    });

    test('every bubble of all three tests lies inside the corner marks', () {
      final l = t.cornerMarkers[0].xFrac, r = t.cornerMarkers[1].xFrac;
      final top = t.cornerMarkers[0].yFrac, bottom = t.cornerMarkers[2].yFrac;
      var count = 0;
      for (final s in t.sections) {
        for (final cells in s.items.values) {
          for (final b in cells) {
            count++;
            expect(b.xFrac, inInclusiveRange(l, r));
            expect(b.yFrac, inInclusiveRange(top, bottom));
          }
        }
      }
      expect(count, 320);
    });

    test('a flat sheet keeps the plain global warp', () {
      expect(build(printed).verdict, OmrMeshVerdict.planar);
    });

    test('mild paper bow is corrected and the mesh passes through the marks', () {
      final bow = {
        for (final e in printed.entries)
          e.key: (e.value.$1 + 6 * (1 - 2 * e.value.$1 / t.pageWidthPt), e.value.$2),
      };
      final mesh = build(bow);
      expect(mesh.isActive, isTrue);
      for (final p in mesh.points.values) {
        final q = mesh.correct(p.canonicalX, p.canonicalY);
        expect(q.$1, closeTo(p.measuredX, 1e-3));
        expect(q.$2, closeTo(p.measuredY, 1e-3));
      }
    });

    test('one hidden small mark per band is tolerated, a whole band is not', () {
      final bow = {
        for (final e in printed.entries)
          e.key: (e.value.$1 + 10 * (1 - 2 * e.value.$1 / t.pageWidthPt), e.value.$2),
      };
      final oneEach = {...bow}
        ..remove(OmrFiducialRole.tatAboveI21)
        ..remove(OmrFiducialRole.tatAboveIII11);
      expect(build(oneEach).isActive, isTrue);
      final noBandIII = {...bow}
        ..remove(OmrFiducialRole.tatAboveIII6)
        ..remove(OmrFiducialRole.tatAboveIII11);
      expect(build(noBandIII).shouldRejectCapture, isTrue);
    });

    test('a frame shifted as a whole is a wrong corner, not bending', () {
      final shifted = {for (final e in printed.entries) e.key: (e.value.$1 + 9, e.value.$2)};
      expect(build(shifted).verdict, OmrMeshVerdict.likelyMisregistered);
    });
  });

  group('TAT portrait orientation', () {
    test('picks as shot, turned 180 degrees, or refuses', () {
      expect(selectTatPortraitDirection(asShotCount: 6, asShotScore: 5.4, turnedCount: 0, turnedScore: 0), 0);
      expect(selectTatPortraitDirection(asShotCount: 0, asShotScore: 0, turnedCount: 6, turnedScore: 5.2), 1);
      expect(selectTatPortraitDirection(asShotCount: 2, asShotScore: 1.8, turnedCount: 1, turnedScore: 0.9), isNull);
      expect(selectTatPortraitDirection(asShotCount: 4, asShotScore: 3.6, turnedCount: 4, turnedScore: 3.5), isNull);
    });

    test('no small mark lands on another when the sheet is turned 180 degrees', () {
      final small = t.interiorFiducials.where((f) => f.halfSizePt < 4).toList();
      expect(small.length, 7);
      for (final f in small) {
        final rx = t.pageWidthPt - f.xFrac * t.pageWidthPt;
        final ry = t.pageHeightPt - f.yFrac * t.pageHeightPt;
        for (final g in small) {
          final dx = rx - g.xFrac * t.pageWidthPt, dy = ry - g.yFrac * t.pageHeightPt;
          expect(dx * dx + dy * dy, greaterThan(12 * 12));
        }
      }
    });
  });
}
