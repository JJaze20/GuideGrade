import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Regression checks for the AT-only "clip the caption strip off the top"
/// fix (see generate_sheets.dart's clipCaptionTop/atCaptionInsetPt and
/// omr_templates.dart's 2026-09-13 note). These assert the crop-box
/// geometry itself, not OCR behavior -- cleanNameOcrText's own tests cover
/// the text-cleanup fallback.
void main() {
  group('AT name-field crops (caption removed from the top only)', () {
    final at = omrTemplates['AT']!;
    // Original (pre-fix, full-box) rects, recorded as fixed goldens rather
    // than re-derived from layout constants -- this should only fail if
    // the actual shipped AT fractions regress, not because of an unrelated
    // layout change elsewhere.
    const originalLastName = (x: 0.07391, y: 0.10690, w: 0.18223, h: 0.04039);
    const originalFirstName = (x: 0.25615, y: 0.10690, w: 0.16705, h: 0.04039);
    const originalMi = (x: 0.42320, y: 0.10690, w: 0.06074, h: 0.04039);

    void expectTopClippedOnly(
      OmrFieldRect rect,
      ({double x, double y, double w, double h}) original,
      String label,
    ) {
      expect(
        rect.xFrac,
        closeTo(original.x, 1e-5),
        reason: '$label: left edge must not move',
      );
      expect(
        rect.widthFrac,
        closeTo(original.w, 1e-5),
        reason: '$label: width must not change',
      );
      expect(
        rect.yFrac,
        greaterThan(original.y),
        reason: '$label: top edge must move down',
      );
      expect(
        rect.yFrac + rect.heightFrac,
        closeTo(original.y + original.h, 1e-5),
        reason: '$label: bottom edge must stay put',
      );
      expect(
        rect.heightFrac,
        lessThan(original.h),
        reason: '$label: height must shrink to match the raised top',
      );
    }

    test('lastNameFieldRect: only the top edge moves', () {
      expectTopClippedOnly(at.lastNameFieldRect, originalLastName, 'lastName');
    });
    test('firstNameFieldRect: only the top edge moves', () {
      expectTopClippedOnly(
        at.firstNameFieldRect,
        originalFirstName,
        'firstName',
      );
    });
    test('middleInitialFieldRect: only the top edge moves', () {
      expectTopClippedOnly(at.middleInitialFieldRect, originalMi, 'middleInitial');
    });

    test('inset clears the caption baseline without eating the whole row', () {
      for (final rect in [
        at.lastNameFieldRect,
        at.firstNameFieldRect,
        at.middleInitialFieldRect,
      ]) {
        final insetPt = (rect.yFrac - originalLastName.y) * at.pageHeightPt;
        // The caption's own baseline sits 10pt down (_paintSimpleHeader);
        // the inset must clear at least that. It must also leave more than
        // half the original row height for handwriting -- a much bigger
        // inset would mean tall ascenders written right under the caption
        // get cut off by the crop itself, not just the caption.
        expect(insetPt, greaterThanOrEqualTo(10.0));
        expect(insetPt, lessThan(originalLastName.h * at.pageHeightPt / 2));
      }
    });
  });

  group('TAT/QTM name-field crops are untouched (AT-only fix)', () {
    test('TAT keeps its original full-box crop', () {
      final tat = omrTemplates['TAT']!;
      expect(tat.lastNameFieldRect.xFrac, closeTo(0.04701, 1e-5));
      expect(tat.lastNameFieldRect.yFrac, closeTo(0.13889, 1e-5));
      expect(tat.lastNameFieldRect.widthFrac, closeTo(0.29808, 1e-5));
      expect(tat.lastNameFieldRect.heightFrac, closeTo(0.02451, 1e-5));
      expect(tat.firstNameFieldRect.yFrac, closeTo(0.13889, 1e-5));
      expect(tat.middleInitialFieldRect.yFrac, closeTo(0.13889, 1e-5));
    });
    test('QTM keeps its original full-box crop', () {
      final qtm = omrTemplates['QTM']!;
      expect(qtm.lastNameFieldRect.xFrac, closeTo(0.07190, 1e-5));
      expect(qtm.lastNameFieldRect.yFrac, closeTo(0.10256, 1e-5));
      expect(qtm.lastNameFieldRect.widthFrac, closeTo(0.37647, 1e-5));
      expect(qtm.lastNameFieldRect.heightFrac, closeTo(0.02350, 1e-5));
      expect(qtm.firstNameFieldRect.yFrac, closeTo(0.10256, 1e-5));
      expect(qtm.middleInitialFieldRect.yFrac, closeTo(0.10256, 1e-5));
    });
  });
}
