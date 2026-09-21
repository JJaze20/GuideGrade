import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

void main() {
  test('OCR retains handwriting below captions across the full name row', () {
    for (final template in omrTemplates.values) {
      final last = template.lastNameFieldRect;
      final first = template.firstNameFieldRect;
      final mi = template.middleNameFieldRect;
      // AT and QTM start their name row at 44 pt; portrait TAT v5 at 48 pt.
      expect(last.xFrac * template.pageWidthPt, closeTo(template.examCode == 'TAT' ? 48 : 44, 0.01));
      expect(last.xFrac + last.widthFrac, closeTo(first.xFrac, 0.00002));
      expect(first.xFrac + first.widthFrac, closeTo(mi.xFrac, 0.00006));
      expect(last.yFrac, first.yFrac);
      expect(last.heightFrac, first.heightFrac);
    }
  });
}
