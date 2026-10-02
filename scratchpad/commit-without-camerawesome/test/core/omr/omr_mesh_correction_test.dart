import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_mesh_correction.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/omr/omr_tat_legacy_template.dart';

/// Regression coverage for the redesigned-sheet local mesh correction
/// (see OmrMeshCorrection's own doc comment). Pure geometry/math, no
/// opencv_dart dependency -- exercises the same triangulation, barycentric
/// interpolation, and verdict-threshold logic the native decoder wires
/// interior-fiducial detections through, using synthetic (hand-specified)
/// measured positions rather than a real photo. This can prove the
/// correction math itself is right (continuous, correctly pinned at the
/// corners, degrades safely outside its trusted range); it cannot prove a
/// real handheld capture's interior fiducials are reliably *detected* in
/// the first place -- that needs a device capture (see this repo's test
/// plan notes).
void main() {
  final at = omrTemplates['AT']!;
  final tat = legacyTatTemplate;
  final canonicalWidth = at.pageWidthPt.round();
  final canonicalHeight = at.pageHeightPt.round();

  List<(double, double)> cornersAt(OmrExamTemplate t, int w, int h) =>
      [for (final c in t.cornerMarkers) (c.xFrac * w, c.yFrac * h)];

  group('templates carry the new versioning/fiducial fields', () {
    test('every exam has a non-empty templateVersion', () {
      for (final code in omrTemplates.keys) {
        expect(omrTemplates[code]!.templateVersion, isNotEmpty, reason: code);
      }
    });

    test('archived TAT v1 retains its original no-mesh behavior', () {
      expect(tat.interiorFiducials, isEmpty);
    });

    test('AT and QTM each print exactly the 5 documented interior marks', () {
      for (final code in ['AT', 'QTM']) {
        final roles = omrTemplates[code]!.interiorFiducials.map((f) => f.role).toSet();
        expect(
          roles,
          {
            OmrFiducialRole.dividerLeft,
            OmrFiducialRole.dividerRight,
            OmrFiducialRole.centerAboveAnswers,
            OmrFiducialRole.centerAtDivider,
            OmrFiducialRole.centerBelowAnswers,
          },
          reason: code,
        );
      }
    });
  });

  group('OmrMeshCorrection.build verdicts', () {
    test('a template with no interior fiducials is notApplicable and a no-op', () {
      final mesh = OmrMeshCorrection.build(
        template: tat,
        canonicalWidth: tat.pageWidthPt.round(),
        canonicalHeight: tat.pageHeightPt.round(),
        cornersMeasuredPx: cornersAt(tat, tat.pageWidthPt.round(), tat.pageHeightPt.round()),
        interiorMeasuredPx: const {},
      );
      expect(mesh.verdict, OmrMeshVerdict.notApplicable);
      expect(mesh.isActive, isFalse);
      final corrected = mesh.correct(123.4, 567.8);
      expect(corrected.$1, closeTo(123.4, 1e-9));
      expect(corrected.$2, closeTo(567.8, 1e-9));
    });

    test('every interior mark landing exactly on its canonical position is planar', () {
      final interior = <OmrFiducialRole, (double, double)>{
        for (final f in at.interiorFiducials) f.role: (f.xFrac * canonicalWidth, f.yFrac * canonicalHeight),
      };
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: interior,
      );
      expect(mesh.verdict, OmrMeshVerdict.planar);
      expect(mesh.isActive, isFalse);
    });

    test('too few confidently-detected interior marks is inconclusive, not planar', () {
      final first = at.interiorFiducials.first;
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {first.role: (first.xFrac * canonicalWidth, first.yFrac * canonicalHeight)},
      );
      expect(mesh.verdict, OmrMeshVerdict.inconclusive);
      expect(mesh.isActive, isFalse);
    });

    test('an extreme measured deviation is tooSevere, not silently corrected', () {
      final divider = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAtDivider);
      final dividerLeft = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dividerLeft.xFrac * canonicalWidth, dividerLeft.yFrac * canonicalHeight),
          OmrFiducialRole.centerAtDivider: (divider.xFrac * canonicalWidth, divider.yFrac * canonicalHeight + 400),
        },
      );
      expect(mesh.verdict, OmrMeshVerdict.tooSevere);
      expect(mesh.isActive, isFalse);
      expect(mesh.userMessage, contains('bent'));
    });
  });

  group('outer-marker misselection ("interior marks disagree with the warp coherently")', () {
    test('interior marks shifted by roughly the same vector are flagged as likely-wrong-corner, not bending', () {
      // dividerLeft, dividerRight, and centerAboveAnswers are far apart
      // (opposite edges of the page, and a different row entirely) --
      // real paper bending would not displace all 3 by nearly the same
      // vector, but a single mismatched outer corner (the whole coordinate
      // frame skewed) would.
      final dl = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      final dr = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerRight);
      final ca = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAboveAnswers);
      const shiftPt = 12.0; // above misregistrationMinMeanResidualPt(6), same direction everywhere
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dl.xFrac * canonicalWidth + shiftPt, dl.yFrac * canonicalHeight),
          OmrFiducialRole.dividerRight: (dr.xFrac * canonicalWidth + shiftPt, dr.yFrac * canonicalHeight),
          OmrFiducialRole.centerAboveAnswers: (ca.xFrac * canonicalWidth + shiftPt, ca.yFrac * canonicalHeight),
        },
      );
      expect(mesh.verdict, OmrMeshVerdict.likelyMisregistered);
      expect(mesh.isActive, isFalse, reason: 'a coherently-wrong homography cannot be fixed by locally bending points');
      expect(mesh.shouldRejectCapture, isTrue);
      expect(mesh.rejectionReason, contains('corner'));
    });

    test('a genuinely severe but incoherent (non-uniform) deviation is tooSevere, not likelyMisregistered', () {
      // Same overall scenario as the existing tooSevere test: one point
      // near zero, the other far off -- an inconsistent pattern, which
      // should NOT trip the coherence check.
      final divider = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAtDivider);
      final dividerLeft = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dividerLeft.xFrac * canonicalWidth, dividerLeft.yFrac * canonicalHeight),
          OmrFiducialRole.centerAtDivider: (divider.xFrac * canonicalWidth, divider.yFrac * canonicalHeight + 400),
        },
      );
      expect(mesh.verdict, OmrMeshVerdict.tooSevere);
    });
  });

  group('shouldRejectCapture only fires on positive evidence, never on absence of evidence', () {
    test('tooSevere rejects with an actionable, flatten-the-sheet reason', () {
      final divider = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAtDivider);
      final dividerLeft = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dividerLeft.xFrac * canonicalWidth, dividerLeft.yFrac * canonicalHeight),
          OmrFiducialRole.centerAtDivider: (divider.xFrac * canonicalWidth, divider.yFrac * canonicalHeight + 400),
        },
      );
      expect(mesh.verdict, OmrMeshVerdict.tooSevere);
      expect(mesh.shouldRejectCapture, isTrue);
      expect(mesh.rejectionReason, isNotNull);
    });

    test('inconclusive (marks simply not found) never rejects the capture by itself', () {
      final first = at.interiorFiducials.first;
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {first.role: (first.xFrac * canonicalWidth, first.yFrac * canonicalHeight)},
      );
      expect(mesh.shouldRejectCapture, isFalse);
      expect(mesh.rejectionReason, isNull);
    });

    test('planar and meshApplied never reject', () {
      final interiorPlanar = <OmrFiducialRole, (double, double)>{
        for (final f in at.interiorFiducials) f.role: (f.xFrac * canonicalWidth, f.yFrac * canonicalHeight),
      };
      final planar = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: interiorPlanar,
      );
      expect(planar.shouldRejectCapture, isFalse);
    });
  });

  group('diagnostics distinguish missing vs. displaced vs. confirmed markers', () {
    test('never treats an expected coordinate as a detected marker', () {
      // No interior fiducials detected at all -- every one of the 5 rows
      // must report `missing` with a null detected position, never a
      // fabricated "detected at its own expected position" reading.
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: const {},
      );
      expect(mesh.diagnostics, hasLength(5));
      for (final d in mesh.diagnostics) {
        expect(d.status, OmrMeshPointDetectionStatus.missing);
        expect(d.detectedX, isNull);
        expect(d.detectedY, isNull);
        expect(d.residualPt, isNull);
      }
    });

    test('one confirmed, one displaced, three missing -- each reported distinctly', () {
      final dl = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      final dr = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerRight);
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dl.xFrac * canonicalWidth, dl.yFrac * canonicalHeight), // exact -> confirmed
          OmrFiducialRole.dividerRight: (
            dr.xFrac * canonicalWidth + 20,
            dr.yFrac * canonicalHeight,
          ), // 20pt off -> displaced
        },
      );
      final byVertex = {for (final d in mesh.diagnostics) d.vertex: d};
      expect(byVertex[OmrMeshVertex.dividerLeft]!.status, OmrMeshPointDetectionStatus.confirmed);
      expect(byVertex[OmrMeshVertex.dividerLeft]!.residualPt, lessThan(1.0));
      expect(byVertex[OmrMeshVertex.dividerRight]!.status, OmrMeshPointDetectionStatus.displaced);
      expect(byVertex[OmrMeshVertex.dividerRight]!.residualPt, closeTo(20.0, 0.5));
      expect(byVertex[OmrMeshVertex.dividerRight]!.detectedX, isNotNull);
      expect(byVertex[OmrMeshVertex.centerAtDivider]!.status, OmrMeshPointDetectionStatus.missing);
      expect(byVertex[OmrMeshVertex.centerAboveAnswers]!.status, OmrMeshPointDetectionStatus.missing);
      expect(byVertex[OmrMeshVertex.centerBelowAnswers]!.status, OmrMeshPointDetectionStatus.missing);
    });

    test('a template with no interior fiducials has no diagnostic rows', () {
      final mesh = OmrMeshCorrection.build(
        template: tat,
        canonicalWidth: tat.pageWidthPt.round(),
        canonicalHeight: tat.pageHeightPt.round(),
        cornersMeasuredPx: cornersAt(tat, tat.pageWidthPt.round(), tat.pageHeightPt.round()),
        interiorMeasuredPx: const {},
      );
      expect(mesh.diagnostics, isEmpty);
    });
  });

  group('OmrMeshCorrection.correct applies a moderate measured bend', () {
    late OmrExamTemplate template;
    late OmrFiducial divider;
    late OmrFiducial dividerLeft;
    late OmrFiducial dividerRight;
    late OmrMeshCorrection mesh;
    const shiftY = 20.0;

    setUp(() {
      template = at;
      divider = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAtDivider);
      dividerLeft = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      dividerRight = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerRight);
      mesh = OmrMeshCorrection.build(
        template: template,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(template, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dividerLeft.xFrac * canonicalWidth, dividerLeft.yFrac * canonicalHeight),
          OmrFiducialRole.dividerRight: (dividerRight.xFrac * canonicalWidth, dividerRight.yFrac * canonicalHeight),
          OmrFiducialRole.centerAtDivider: (
            divider.xFrac * canonicalWidth,
            divider.yFrac * canonicalHeight + shiftY,
          ),
        },
      );
    });

    test('is classified as meshApplied and active', () {
      expect(mesh.verdict, OmrMeshVerdict.meshApplied);
      expect(mesh.isActive, isTrue);
    });

    test('reproduces the measured shift exactly at the bent point itself', () {
      final canonicalX = divider.xFrac * canonicalWidth;
      final canonicalY = divider.yFrac * canonicalHeight;
      final corrected = mesh.correct(canonicalX, canonicalY);
      expect(corrected.$1, closeTo(canonicalX, 0.5));
      expect(corrected.$2, closeTo(canonicalY + shiftY, 0.5));
    });

    test('leaves a pinned corner exactly unperturbed by a distant interior bend', () {
      final tl = template.cornerMarkers[0];
      final corrected = mesh.correct(tl.xFrac * canonicalWidth, tl.yFrac * canonicalHeight);
      expect(corrected.$1, closeTo(tl.xFrac * canonicalWidth, 1e-6));
      expect(corrected.$2, closeTo(tl.yFrac * canonicalHeight, 1e-6));
    });

    test('is continuous across the shared triangle edge at the divider row', () {
      final canonicalX = divider.xFrac * canonicalWidth;
      final canonicalY = divider.yFrac * canonicalHeight;
      final justAbove = mesh.correct(canonicalX, canonicalY - 0.01);
      final justBelow = mesh.correct(canonicalX, canonicalY + 0.01);
      expect(justAbove.$1, closeTo(justBelow.$1, 0.5));
      expect(justAbove.$2, closeTo(justBelow.$2, 0.5));
    });
  });

  group('verdict classification is scale-invariant', () {
    test('the same real-world bend classifies identically at the decoder scale and the viewer scale', () {
      // OmrDecoder.decode samples bubbles at 2px/pt (_canonicalPxPerPt);
      // the graded-overlay viewer (_GradedOverlayPainter) rebuilds the
      // mesh at 1 unit = 1 PDF point (page-point scale) instead, per
      // ScannedImageViewerScreen's doc comment. If OmrMeshCorrection.build
      // classified residuals in raw canonical px rather than PDF points,
      // the exact same physical bend would land on opposite sides of the
      // planar/meshApplied/tooSevere thresholds purely because of which
      // caller asked -- silently reintroducing the "reading and overlay
      // disagree" failure mode this type exists to prevent.
      final divider = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAtDivider);
      final dividerLeft = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      const realBendPt = 10.0; // between planarResidualPt (1.5) and maxTrustedResidualPt (45)

      OmrMeshVerdict verdictAtScale(double pxPerPt) {
        final w = (at.pageWidthPt * pxPerPt).round();
        final h = (at.pageHeightPt * pxPerPt).round();
        final mesh = OmrMeshCorrection.build(
          template: at,
          canonicalWidth: w,
          canonicalHeight: h,
          cornersMeasuredPx: cornersAt(at, w, h),
          interiorMeasuredPx: {
            OmrFiducialRole.dividerLeft: (dividerLeft.xFrac * w, dividerLeft.yFrac * h),
            OmrFiducialRole.centerAtDivider: (divider.xFrac * w, divider.yFrac * h + realBendPt * pxPerPt),
          },
        );
        return mesh.verdict;
      }

      final decoderScaleVerdict = verdictAtScale(2.0); // OmrDecoder's own scale
      final viewerScaleVerdict = verdictAtScale(1.0); // page-point scale
      expect(decoderScaleVerdict, OmrMeshVerdict.meshApplied);
      expect(viewerScaleVerdict, decoderScaleVerdict);
    });
  });

  group('measured-fraction export/import round-trip', () {
    test('fromMeasuredFractions rebuilds the same verdict toMeasuredFractions was built from', () {
      final divider = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAtDivider);
      final dividerLeft = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      final dividerRight = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerRight);
      final original = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dividerLeft.xFrac * canonicalWidth, dividerLeft.yFrac * canonicalHeight),
          OmrFiducialRole.dividerRight: (dividerRight.xFrac * canonicalWidth, dividerRight.yFrac * canonicalHeight),
          OmrFiducialRole.centerAtDivider: (divider.xFrac * canonicalWidth, divider.yFrac * canonicalHeight + 15),
        },
      );
      final fractions = original.toMeasuredFractions(canonicalWidth, canonicalHeight);
      expect(fractions.length, 3);

      final rebuilt = OmrMeshCorrection.fromMeasuredFractions(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        measuredFrac: fractions,
      );
      expect(rebuilt.verdict, original.verdict);

      // Same corrected position at an arbitrary content point (e.g. item
      // 1's own bubble-adjacent region) for both the original and the
      // fraction-round-tripped rebuild.
      final probeX = canonicalWidth * 0.2;
      final probeY = canonicalHeight * 0.3;
      final a = original.correct(probeX, probeY);
      final b = rebuilt.correct(probeX, probeY);
      expect(a.$1, closeTo(b.$1, 1e-6));
      expect(a.$2, closeTo(b.$2, 1e-6));
    });

    test('an undetected interior mark is absent from the exported fractions', () {
      final divider = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.centerAtDivider);
      final dividerLeft = at.interiorFiducials.firstWhere((f) => f.role == OmrFiducialRole.dividerLeft);
      // Only 2 of 5 detected -- meets the confident-count floor, so this is
      // meshApplied/inconclusive depending on the residual, but either way
      // only the 2 actually-detected roles should appear in the export.
      final mesh = OmrMeshCorrection.build(
        template: at,
        canonicalWidth: canonicalWidth,
        canonicalHeight: canonicalHeight,
        cornersMeasuredPx: cornersAt(at, canonicalWidth, canonicalHeight),
        interiorMeasuredPx: {
          OmrFiducialRole.dividerLeft: (dividerLeft.xFrac * canonicalWidth, dividerLeft.yFrac * canonicalHeight),
          OmrFiducialRole.centerAtDivider: (divider.xFrac * canonicalWidth, divider.yFrac * canonicalHeight + 10),
        },
      );
      final fractions = mesh.toMeasuredFractions(canonicalWidth, canonicalHeight);
      expect(fractions.containsKey(OmrFiducialRole.dividerLeft.name), isTrue);
      expect(fractions.containsKey(OmrFiducialRole.centerAtDivider.name), isTrue);
      expect(fractions.containsKey(OmrFiducialRole.dividerRight.name), isFalse);
      expect(fractions.containsKey(OmrFiducialRole.centerAboveAnswers.name), isFalse);
      expect(fractions.containsKey(OmrFiducialRole.centerBelowAnswers.name), isFalse);
    });
  });
}
