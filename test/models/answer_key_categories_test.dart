import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/answer_key.dart';

void main() {
  test('a key saved by an older build with category entries among the answers is repaired on load', () {
    final k = AnswerKey.fromJson({
      'examCode': 'AT',
      'correctChoices': {
        'Section 1|1': 'D',
        'Section 1|2': 'K',
        'category|Section 1|1': 'VC',
        'category|Section 1|2': 'VR',
      },
    });
    expect(k.correctChoices.length, 2, reason: 'not 4 "answers" for 2 items');
    expect(k.choiceFor('Section 1', 1), 'D');
    expect(k.categoryFor('Section 1', 1), 'VC');
    expect(k.categoryFor('Section 1', 2), 'VR');
  });

  test('an explicit itemCategories entry wins over a stray flat one', () {
    final k = AnswerKey.fromJson({
      'examCode': 'AT',
      'correctChoices': {'Section 1|1': 'D', 'category|Section 1|1': 'VC'},
      'itemCategories': {'Section 1|1': 'FR'},
    });
    expect(k.categoryFor('Section 1', 1), 'FR');
  });

  test('a key without categories is unchanged, and the cloud shape round-trips', () {
    final clean = AnswerKey.fromJson({'examCode': 'TAT', 'correctChoices': {'Test I|1': 'T'}});
    expect(clean.correctChoices.length, 1);
    expect(clean.itemCategories, isEmpty);

    const withCats = AnswerKey(
      examCode: 'AT',
      correctChoices: {'Section 1|1': 'D'},
      itemCategories: {'Section 1|1': 'VC'},
    );
    final back = AnswerKey.fromJson(jsonDecode(jsonEncode(withCats.toJson())) as Map<String, dynamic>);
    expect(back.itemCategories, withCats.itemCategories);
    final viaCloud = AnswerKey.fromCloudAnswers('AT', withCats.toCloudAnswers());
    expect(viaCloud.correctChoices, withCats.correctChoices);
    expect(viaCloud.itemCategories, withCats.itemCategories);
  });
}
