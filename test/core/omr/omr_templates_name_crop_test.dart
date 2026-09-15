import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Regression checks for the AT/QTM "clip the caption strip off the top"
/// fix (see generate_sheets.dart's clipCaptionTop/kNameCaptionHeight and
/// omr_templates.dart's generated note). These assert the crop-box
/// geometry itself, not OCR behavior -- cleanNameOcrText's own tests cover
/// the text-cleanup fallback.
typedef _OriginalBox = ({double x, double y, double w, double h});

void _expectTopClippedOnly(
  OmrFieldRect rect,
  _OriginalBox original,
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

/// Shared by AT and QTM (both now use the same two-row boxed Last Name/
/// (First Name+MI) header design, each with its own dedicated caption/box
/// split -- see generate_sheets.dart's _paintSimpleHeader/_paintQtmHeader).
void _testRedesignedNameCrop(
  String examCode,
  _OriginalBox originalLastName,
  _OriginalBox originalFirstName,
  _OriginalBox originalMi,
) {
  group('$examCode name-field crops (caption removed from the top only)', () {
    final exam = omrTemplates[examCode]!;

    test('lastNameFieldRect: only the top edge moves', () {
      _expectTopClippedOnly(exam.lastNameFieldRect, originalLastName, 'lastName');
    });
    test('firstNameFieldRect: only the top edge moves', () {
      _expectTopClippedOnly(exam.firstNameFieldRect, originalFirstName, 'firstName');
    });
    test('middleInitialFieldRect: only the top edge moves', () {
      _expectTopClippedOnly(exam.middleInitialFieldRect, originalMi, 'middleInitial');
    });

    test('inset clears the caption baseline without eating the whole row', () {
      for (final MapEntry(key: rect, value: original) in {
        exam.lastNameFieldRect: originalLastName,
        exam.firstNameFieldRect: originalFirstName,
        exam.middleInitialFieldRect: originalMi,
      }.entries) {
        final insetPt = (rect.yFrac - original.y) * exam.pageHeightPt;
        // The caption's own baseline sits 10pt down (_paintSimpleHeader/
        // _paintQtmHeader); the inset must clear at least that. It must
        // also leave more than half the original row height for
        // handwriting -- a much bigger inset would mean tall ascenders
        // written right under the caption get cut off by the crop itself.
        expect(insetPt, greaterThanOrEqualTo(10.0));
        expect(insetPt, lessThan(original.h * exam.pageHeightPt / 2));
      }
    });
  });
}

void main() {
  // Original (pre-fix, full-box) rects, recorded as fixed goldens rather
  // than re-derived from layout constants -- this should only fail if the
  // actual shipped AT/QTM fractions regress, not because of an unrelated
  // layout change elsewhere. Last Name has its own full-width row; First
  // Name/MI share the row below it, so their original y differs from Last
  // Name's.
  _testRedesignedNameCrop(
    'AT',
    (x: 0.07391, y: 0.10690, w: 0.75931, h: 0.04039),
    (x: 0.07391, y: 0.14966, w: 0.64541, h: 0.04039),
    (x: 0.71933, y: 0.14966, w: 0.11390, h: 0.04039),
  );
  _testRedesignedNameCrop(
    'QTM',
    (x: 0.07190, y: 0.10256, w: 0.75817, h: 0.03633),
    (x: 0.07190, y: 0.14102, w: 0.64444, h: 0.03633),
    (x: 0.71634, y: 0.14102, w: 0.11373, h: 0.03633),
  );

  group('TAT name-field crop is untouched (AT/QTM-only fix)', () {
    test('TAT keeps its original full-box crop', () {
      final tat = omrTemplates['TAT']!;
      expect(tat.lastNameFieldRect.xFrac, closeTo(0.04701, 1e-5));
      expect(tat.lastNameFieldRect.yFrac, closeTo(0.13889, 1e-5));
      expect(tat.lastNameFieldRect.widthFrac, closeTo(0.29808, 1e-5));
      expect(tat.lastNameFieldRect.heightFrac, closeTo(0.02451, 1e-5));
      expect(tat.firstNameFieldRect.yFrac, closeTo(0.13889, 1e-5));
      expect(tat.middleInitialFieldRect.yFrac, closeTo(0.13889, 1e-5));
    });
  });
}
