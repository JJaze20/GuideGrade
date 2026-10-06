import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/sheet_exam_identity.dart';

void main() {
  test('recognizes full exam titles across whitespace and punctuation', () {
    expect(identifySheetExam('ADMISSION TEST (AT)'), 'AT');
    expect(identifySheetExam('Qualifying Test\nin Mathematics (QTM)'), 'QTM');
    expect(identifySheetExam('TEACHING APTITUDE TEST (TAT)'), 'TAT');
  });
  test('ambiguous or incomplete titles do not identify an exam', () {
    for (final text in ['', 'AT QTM TAT', 'Matt Smith', 'ADMISSION',
      'NOTADMISSION TEST', 'ADMISSION TEST TEACHING APTITUDE TEST']) {
      expect(identifySheetExam(text), isNull);
    }
  });
}
