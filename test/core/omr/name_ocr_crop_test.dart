import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Asserts [rect] is a real, independently croppable rectangle wholly
/// within the page (non-negative origin, positive size, right/bottom edges
/// not past the page bounds) — true for every template regardless of
/// layout.
void _expectValidFieldRect(OmrFieldRect rect, String label) {
  expect(rect.xFrac, greaterThanOrEqualTo(0), reason: '$label.xFrac');
  expect(rect.yFrac, greaterThanOrEqualTo(0), reason: '$label.yFrac');
  expect(rect.widthFrac, greaterThan(0), reason: '$label.widthFrac');
  expect(rect.heightFrac, greaterThan(0), reason: '$label.heightFrac');
  expect(rect.xFrac + rect.widthFrac, lessThanOrEqualTo(1.0001),
      reason: '$label right edge must stay within the page');
  expect(rect.yFrac + rect.heightFrac, lessThanOrEqualTo(1.0001),
      reason: '$label bottom edge must stay within the page');
}

void main() {
  test(
      'every template\'s Last/First/Middle Name fields are valid, '
      'independently croppable rectangles laid out as one contiguous row '
      '(AT/QTM start 44 pt from the left margin, portrait TAT v5 at 48 pt)',
      () {
    for (final template in omrTemplates.values) {
      final last = template.lastNameFieldRect;
      final first = template.firstNameFieldRect;
      final mi = template.middleNameFieldRect;

      _expectValidFieldRect(last, 'lastNameFieldRect');
      _expectValidFieldRect(first, 'firstNameFieldRect');
      _expectValidFieldRect(mi, 'middleNameFieldRect');

      // AT and QTM start their name row at 44 pt; portrait TAT v5 at 48 pt.
      expect(last.xFrac * template.pageWidthPt,
          closeTo(template.examCode == 'TAT' ? 48 : 44, 0.01));

      // Last -> First -> Middle touch edge to edge...
      expect(last.xFrac + last.widthFrac, closeTo(first.xFrac, 0.00002));
      expect(first.xFrac + first.widthFrac, closeTo(mi.xFrac, 0.00006));

      // ...on the same row.
      expect(last.yFrac, first.yFrac);
      expect(last.heightFrac, first.heightFrac);
      expect(first.yFrac, mi.yFrac);
      expect(first.heightFrac, mi.heightFrac);
    }
  });
}
