import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Asserts [rect] is a real, independently croppable rectangle wholly
/// within the page (non-negative origin, positive size, right/bottom edges
/// not past the page bounds) — true for every template regardless of
/// layout, redesigned or legacy.
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
      'every template\'s Last/First/Middle Initial name fields are valid, '
      'independently croppable rectangles, consistently ~44pt from the left '
      'margin (unaffected by the AT/QTM redesign — OmrDecoder.cropNameFields '
      'crops each field independently, with no same-row assumption)', () {
    for (final template in omrTemplates.values) {
      final last = template.lastNameFieldRect;
      final first = template.firstNameFieldRect;
      final mi = template.middleInitialFieldRect;

      _expectValidFieldRect(last, 'lastNameFieldRect');
      _expectValidFieldRect(first, 'firstNameFieldRect');
      _expectValidFieldRect(mi, 'middleInitialFieldRect');

      expect(last.xFrac * template.pageWidthPt, closeTo(44, 0.01));
    }
  });

  test(
      'First Name and Middle Initial remain on the same row, contiguous, '
      'on every template — this relationship was NOT changed by the AT/QTM '
      'redesign', () {
    for (final template in omrTemplates.values) {
      final first = template.firstNameFieldRect;
      final mi = template.middleInitialFieldRect;

      expect(first.xFrac + first.widthFrac, closeTo(mi.xFrac, 0.00006));
      expect(first.yFrac, mi.yFrac);
      expect(first.heightFrac, mi.heightFrac);
    }
  });

  test(
      'AT/QTM (redesigned 9-fiducial sheets): Last Name is now on its own '
      'row, directly ABOVE First Name/Middle Initial — not contiguous with '
      'them on the same row anymore', () {
    for (final examCode in ['AT', 'QTM']) {
      final template = omrTemplates[examCode]!;
      final last = template.lastNameFieldRect;
      final first = template.firstNameFieldRect;

      // Same left margin as the First Name/MI row below it, but its own row.
      expect(last.xFrac, closeTo(first.xFrac, 0.00002));
      expect(last.yFrac, lessThan(first.yFrac));
      // Last Name's row does not overlap the First Name/MI row beneath it.
      expect(last.yFrac + last.heightFrac, lessThanOrEqualTo(first.yFrac + 0.00002));
    }
  });

  test(
      'TAT (legacy sheet, untouched by the redesign): Last Name is still '
      'contiguous with First Name on the SAME row, exactly as before', () {
    final template = omrTemplates['TAT']!;
    final last = template.lastNameFieldRect;
    final first = template.firstNameFieldRect;

    expect(last.xFrac + last.widthFrac, closeTo(first.xFrac, 0.00002));
    expect(last.yFrac, first.yFrac);
    expect(last.heightFrac, first.heightFrac);
  });
}
