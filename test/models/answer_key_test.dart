import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/answer_key.dart';

void main() {
  test('legacy answer keys load without question text', () {
    final key = AnswerKey.fromJson({
      'examCode': 'AT',
      'correctChoices': {'Section 1|1': 'A'},
    });
    expect(key.questionTexts, isEmpty);
    expect(key.choiceFor('Section 1', 1), 'A');
  });

  test('question text survives JSON and keeps repeated TAT items distinct', () {
    const original = AnswerKey(
      examCode: 'TAT',
      correctChoices: {'Test I|1': 'A', 'Test II|1': 'B'},
      questionTexts: {'Test I|1': 'First question', 'Test II|1': 'Other question'},
    );
    final restored = AnswerKey.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );
    expect(restored.questionTexts, original.questionTexts);
    expect(restored.correctChoices, original.correctChoices);
    expect(restored.choiceFor('Test I', 1), 'A');
    expect(restored.choiceFor('Test II', 1), 'B');
  });
}
