import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Goldens for the Last Name / First Name / Middle Name crop rectangles of
/// every sheet. These are the shipped values themselves (writing space only,
/// printed captions excluded), recorded as fixed numbers rather than
/// re-derived from layout constants, so a layout change can not silently move
/// the crops that staff read names from. They assert crop-box geometry, not
/// OCR behavior.
///
/// Every sheet has ONE row of open name fields (no per-letter cells, so every
/// box count is 0). AT and QTM give the Middle Name field room for a full name
/// rather than an initial; TAT's v5 row keeps its short M.I. box.
typedef _Rect = ({double x, double y, double w, double h});

void _expectRect(OmrFieldRect r, _Rect e, String label) {
  expect(r.xFrac, closeTo(e.x, 1e-5), reason: '$label x');
  expect(r.yFrac, closeTo(e.y, 1e-5), reason: '$label y');
  expect(r.widthFrac, closeTo(e.w, 1e-5), reason: '$label width');
  expect(r.heightFrac, closeTo(e.h, 1e-5), reason: '$label height');
}

void _testNameCrops(
  String examCode,
  _Rect last,
  _Rect first,
  _Rect middle, {
  double? minMiddleWidthPt,
}) {
  group('$examCode name-field crops', () {
    final exam = omrTemplates[examCode]!;

    test('last name, first name and middle name rectangles', () {
      _expectRect(exam.lastNameFieldRect, last, 'lastName');
      _expectRect(exam.firstNameFieldRect, first, 'firstName');
      _expectRect(exam.middleNameFieldRect, middle, 'middleName');
    });

    test('no letter cells: every box count is 0', () {
      expect(exam.lastNameBoxCount, 0);
      expect(exam.firstNameBoxCount, 0);
      expect(exam.middleNameBoxCount, 0);
    });

    test('the three fields share one row and sit edge to edge', () {
      final l = exam.lastNameFieldRect, f = exam.firstNameFieldRect, m = exam.middleNameFieldRect;
      expect(l.yFrac, f.yFrac);
      expect(f.yFrac, m.yFrac);
      expect(l.heightFrac, f.heightFrac);
      expect(l.xFrac + l.widthFrac, closeTo(f.xFrac, 1e-4));
      expect(f.xFrac + f.widthFrac, closeTo(m.xFrac, 1e-4));
    });

    if (minMiddleWidthPt != null) {
      test('the middle name field is long enough for a full name (>= $minMiddleWidthPt pt)', () {
        expect(exam.middleNameFieldRect.widthFrac * exam.pageWidthPt, greaterThanOrEqualTo(minMiddleWidthPt));
      });
    }
  });
}

void main() {
  _testNameCrops(
    'AT',
    (x: 0.07391, y: 0.12353, w: 0.31132, h: 0.02376),
    (x: 0.38523, y: 0.12353, w: 0.31132, h: 0.02376),
    (x: 0.69655, y: 0.12353, w: 0.13668, h: 0.02376),
    minMiddleWidthPt: 80,
  );
  _testNameCrops(
    'QTM',
    (x: 0.07190, y: 0.11752, w: 0.31085, h: 0.02137),
    (x: 0.38275, y: 0.11752, w: 0.31085, h: 0.02137),
    (x: 0.69359, y: 0.11752, w: 0.13647, h: 0.02137),
    minMiddleWidthPt: 80,
  );
  // TAT (portrait v5): straight from the sheet's geometry JSON.
  _testNameCrops(
    'TAT',
    (x: 0.07843, y: 0.11325, w: 0.24510, h: 0.02350),
    (x: 0.32353, y: 0.11325, w: 0.24510, h: 0.02350),
    (x: 0.56863, y: 0.11325, w: 0.05882, h: 0.02350),
  );
}
