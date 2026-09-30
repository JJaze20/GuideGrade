import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/constants/exam_catalog.dart';

void main() {
  group('examCatalog', () {
    test('QTM\'s canonical title is the formal name "Qualifying Test for '
        'Mathematics" -- not "Quantitative Math Test" and not the legacy OMR '
        'section identifier "Qualifying Test in Mathematics"', () {
      final qtm = examCatalog.firstWhere((e) => e.examCode == 'QTM');
      expect(qtm.title, 'Qualifying Test for Mathematics');
      expect(qtm.title, isNot(contains('Quantitative')));
      expect(qtm.title, isNot(contains(' in Mathematics')));
    });

    test('TAT and AT titles are unchanged', () {
      expect(examCatalog.firstWhere((e) => e.examCode == 'TAT').title,
          'Teaching Aptitude Test');
      expect(examCatalog.firstWhere((e) => e.examCode == 'AT').title,
          'Admission Test');
    });
  });

  group('examTypeDisplayLabel', () {
    test('QTM -> "Qualifying Test for Mathematics (QTM)"', () {
      expect(examTypeDisplayLabel('QTM'), 'Qualifying Test for Mathematics (QTM)');
    });

    test('TAT -> "Teaching Aptitude Test (TAT)"', () {
      expect(examTypeDisplayLabel('TAT'), 'Teaching Aptitude Test (TAT)');
    });

    test('AT -> "Admission Test (AT)"', () {
      expect(examTypeDisplayLabel('AT'), 'Admission Test (AT)');
    });

    test('an unrecognized code falls back to the bare code, never throws', () {
      expect(examTypeDisplayLabel('ZZZ'), 'ZZZ');
    });
  });
}
