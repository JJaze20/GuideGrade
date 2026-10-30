import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/at_categories.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/models/answer_key.dart';

/// Official AT key (OLSAT Levels E/F/G, Forms 3/4), item -> correct choice.
const _key = {
  1: 'D', 2: 'K', 3: 'D', 4: 'H', 5: 'B', 6: 'H', 7: 'E', 8: 'H', 9: 'B',
  10: 'K', 11: 'B', 12: 'J', 13: 'A', 14: 'H', 15: 'D', 16: 'J', 17: 'C',
  18: 'G', 19: 'C', 20: 'J', 21: 'B', 22: 'G', 23: 'A', 24: 'F', 25: 'E',
  26: 'H', 27: 'C', 28: 'F', 29: 'E', 30: 'H', 31: 'D', 32: 'K', 33: 'E',
  34: 'H', 35: 'E', 36: 'J', 37: 'D', 38: 'H', 39: 'D', 40: 'G', 41: 'E',
  42: 'G', 43: 'A', 44: 'J', 45: 'B', 46: 'H', 47: 'C', 48: 'F', 49: 'C',
  50: 'J', 51: 'B', 52: 'H', 53: 'D', 54: 'F', 55: 'E', 56: 'G', 57: 'D',
  58: 'K', 59: 'D', 60: 'G', 61: 'E', 62: 'G', 63: 'B', 64: 'H', 65: 'A',
  66: 'J', 67: 'E', 68: 'K', 69: 'C', 70: 'F', 71: 'E', 72: 'J',
};

/// A graded AT sheet where exactly [correct] items were answered right.
List<ScoredItem> _sheet(Set<int> correct) => [
      for (var i = 1; i <= 72; i++)
        ScoredItem(
          sectionName: 'Answer Document',
          itemNumber: i,
          markedChoice: correct.contains(i) ? _key[i] : 'X',
          isAmbiguous: false,
          correctChoice: _key[i],
        ),
    ];

void main() {
  test('official mapping has 72 items: VC 12, VR 24, FR 18, QR 18', () {
    expect(officialAtCategories.length, 72);
    int count(AtCategory c) => officialAtCategories.values.where((v) => v == c).length;
    expect(count(AtCategory.vc), 12);
    expect(count(AtCategory.vr), 24);
    expect(count(AtCategory.fr), 18);
    expect(count(AtCategory.qr), 18);
  });

  test('sheet 1 (33/72) -> VC 3, VR 8, FR 10, QR 12', () {
    final s = computeAtCategoryScores(
      _sheet({4, 5, 6, 7, 8, 9, 12, 17, 18, 19, 23, 26, 29, 30, 31, 32, 33, 35, 36,
          42, 44, 45, 46, 47, 49, 50, 51, 54, 58, 61, 63, 66, 67}),
      null,
    )!;
    expect(s.scoreOf(AtCategory.vc).right, 3);
    expect(s.scoreOf(AtCategory.vr).right, 8);
    expect(s.scoreOf(AtCategory.fr).right, 10);
    expect(s.scoreOf(AtCategory.qr).right, 12);
    expect(s.verbalRight, 11);
    expect(s.nonVerbalRight, 22);
    expect(s.totalRight, 33);
    expect(s.verbalTotal, 36);
    expect(s.nonVerbalTotal, 36);
  });

  test('sheet 2 (34/72) -> VC 6, VR 11, FR 7, QR 10', () {
    final s = computeAtCategoryScores(
      _sheet({1, 3, 4, 5, 7, 9, 10, 11, 12, 15, 16, 17, 18, 19, 20, 21, 23, 25, 26,
          27, 29, 31, 34, 35, 36, 37, 42, 43, 45, 46, 49, 50, 63, 71}),
      null,
    )!;
    expect(s.scoreOf(AtCategory.vc).right, 6);
    expect(s.scoreOf(AtCategory.vr).right, 11);
    expect(s.scoreOf(AtCategory.fr).right, 7);
    expect(s.scoreOf(AtCategory.qr).right, 10);
    expect(s.verbalRight, 17);
    expect(s.nonVerbalRight, 17);
    expect(s.totalRight, 34);
  });

  test("the answer key's own category overrides the official one", () {
    final key = AnswerKey(
      examCode: 'AT',
      correctChoices: const {},
      itemCategories: {AnswerKey.keyFor('Answer Document', 1): 'QR'},
    );
    final s = computeAtCategoryScores(_sheet({1}), key)!;
    expect(s.scoreOf(AtCategory.vc).right, 0);
    expect(s.scoreOf(AtCategory.vc).total, 11);
    expect(s.scoreOf(AtCategory.qr).right, 1);
    expect(s.scoreOf(AtCategory.qr).total, 19);
  });

  test('ungraded sheet -> null', () {
    final items = [
      const ScoredItem(
        sectionName: 'Answer Document',
        itemNumber: 1,
        markedChoice: 'A',
        isAmbiguous: false,
        correctChoice: null,
      ),
    ];
    expect(computeAtCategoryScores(items, null), isNull);
  });

  group('AnswerKey categories', () {
    const key = AnswerKey(
      examCode: 'AT',
      correctChoices: {'Section 1|1': 'D'},
      itemCategories: {'Section 1|1': 'VC'},
    );

    test('cloud answers merge and split back unchanged', () {
      final cloud = key.toCloudAnswers();
      expect(cloud, {'Section 1|1': 'D', 'category|Section 1|1': 'VC'});
      final back = AnswerKey.fromCloudAnswers('AT', cloud);
      expect(back.correctChoices, key.correctChoices);
      expect(back.itemCategories, key.itemCategories);
    });

    test('local JSON round-trips; old JSON without categories still loads', () {
      final back = AnswerKey.fromJson(key.toJson());
      expect(back.itemCategories, key.itemCategories);
      final old = AnswerKey.fromJson({
        'examCode': 'AT',
        'correctChoices': {'Section 1|1': 'D'},
      });
      expect(old.itemCategories, isEmpty);
    });

    test('a key with no categories pushes exactly its answers', () {
      const plain = AnswerKey(examCode: 'QTM', correctChoices: {'Section 1|1': 'A'});
      expect(plain.toCloudAnswers(), plain.correctChoices);
      expect(plain.toJson().containsKey('itemCategories'), isFalse);
    });
  });
}
