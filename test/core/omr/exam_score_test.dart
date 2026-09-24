import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/exam_score.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Section names exactly as the registered exam templates declare them
/// (see lib/core/omr/omr_templates.dart).
const _atSection = 'Answer Document';
const _qtmSection = 'Qualifying Test in Mathematics';
const _tat1 = 'Test I';
const _tat2 = 'Test II';
const _tat3 = 'Test III';

OmrExamTemplate get _atTemplate => omrTemplates['AT']!;
OmrExamTemplate get _qtmTemplate => omrTemplates['QTM']!;
OmrExamTemplate get _tatTemplate => omrTemplates['TAT']!;

// --- Per-item builders. itemNumber is irrelevant to scoring; it only has
// to be present. ---

ScoredItem _correct(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: 'A',
    );

/// A definite wrong answer: a single unambiguous mark that disagrees with
/// the key.
ScoredItem _wrong(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: 'B',
    );

/// Blank: no mark. The key still covers the item (so it counts as graded).
ScoredItem _blank(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: null,
      isAmbiguous: false,
      correctChoice: 'B',
    );

/// Ambiguous: a mark is present and disagrees with the key, but the item
/// is flagged ambiguous — it must never count as wrong.
ScoredItem _ambiguous(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: 'A',
      isAmbiguous: true,
      correctChoice: 'B',
    );

/// Not covered by the answer key (correctChoice == null): graded neither
/// right nor wrong.
ScoredItem _ungraded(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: null,
    );

/// Builds a list for one section: [correct] correct, then [wrong] definite
/// wrong, then [blank] blank, then [ambiguous] ambiguous, then [ungraded]
/// key-less items. Item numbers are sequential from 1.
List<ScoredItem> _section(
  String section, {
  int correct = 0,
  int wrong = 0,
  int blank = 0,
  int ambiguous = 0,
  int ungraded = 0,
}) {
  final items = <ScoredItem>[];
  var n = 1;
  for (var i = 0; i < correct; i++) {
    items.add(_correct(section, n++));
  }
  for (var i = 0; i < wrong; i++) {
    items.add(_wrong(section, n++));
  }
  for (var i = 0; i < blank; i++) {
    items.add(_blank(section, n++));
  }
  for (var i = 0; i < ambiguous; i++) {
    items.add(_ambiguous(section, n++));
  }
  for (var i = 0; i < ungraded; i++) {
    items.add(_ungraded(section, n++));
  }
  return items;
}

ScoredResult _result(String examCode, List<ScoredItem> items) =>
    ScoredResult(examCode: examCode, items: items);

void main() {
  group('template itemization (sanity — templates are the source of truth)',
      () {
    int sum(OmrExamTemplate t) =>
        t.sections.fold<int>(0, (s, sec) => s + sec.itemCount);

    test('Admission Test = 6 sections of 12 items each = 72 '
        '(post-redesign: 2 rows x 3 columns aligned to the 9-fiducial mesh)',
        () {
      expect(_atTemplate.sections.map((s) => s.name).toList(), [
        'Section 1',
        'Section 2',
        'Section 3',
        'Section 4',
        'Section 5',
        'Section 6',
      ]);
      expect(_atTemplate.sections.map((s) => s.itemCount).toList(),
          [12, 12, 12, 12, 12, 12]);
      expect(sum(_atTemplate), 72);
    });

    test('QTM = 6 sections of 10 items each = 60 '
        '(post-redesign: 2 rows x 3 columns aligned to the 9-fiducial mesh)',
        () {
      expect(_qtmTemplate.sections.map((s) => s.name).toList(), [
        'Section 1',
        'Section 2',
        'Section 3',
        'Section 4',
        'Section 5',
        'Section 6',
      ]);
      expect(_qtmTemplate.sections.map((s) => s.itemCount).toList(),
          [10, 10, 10, 10, 10, 10]);
      expect(sum(_qtmTemplate), 60);
    });

    test('TAT = 30 + 80 + 20 = 130 items across three sections in order', () {
      expect(_tatTemplate.sections.map((s) => s.name).toList(),
          [_tat1, _tat2, _tat3]);
      expect(_tatTemplate.sections.map((s) => s.itemCount).toList(),
          [30, 80, 20]);
      expect(sum(_tatTemplate), 130);
    });
  });

  group('Admission Test — raw scoring, percentage on the fixed /72', () {
    test('1. 72 correct / 72 -> raw 72, percentage 100', () {
      final score = computeExamScore(
        _result('AT', _section(_atSection, correct: 72)),
        _atTemplate,
      );

      expect(score.model, ExamScoringModel.raw);
      expect(score.rawScore, 72);
      expect(score.totalItems, 72);
      expect(score.percentage, 100.0);
      expect(score.hasOfficialPercentage, isTrue);
      expect(score.isGraded, isTrue);
      expect(score.tatTotal, isNull);
    });

    test('2. 60 correct / 72 -> raw 60, percentage ~= 83.33', () {
      final score = computeExamScore(
        _result('AT', _section(_atSection, correct: 60, wrong: 12)),
        _atTemplate,
      );

      expect(score.rawScore, 60);
      expect(score.totalItems, 72);
      expect(score.percentage, closeTo(83.33, 0.01));
    });

    test('3. 0 correct / 72 -> raw 0, percentage 0', () {
      final allBlank = computeExamScore(
        _result('AT', _section(_atSection, blank: 72)),
        _atTemplate,
      );
      expect(allBlank.rawScore, 0);
      expect(allBlank.percentage, 0.0);
      expect(allBlank.isGraded, isTrue); // the key still covered 72 items

      final allWrong = computeExamScore(
        _result('AT', _section(_atSection, wrong: 72)),
        _atTemplate,
      );
      expect(allWrong.rawScore, 0);
      expect(allWrong.percentage, 0.0);
    });

    test(
        '4. partial answer-key coverage regression: denominator stays 72, '
        'never totalGraded', () {
      // 60 correct + 5 definite wrong + 7 items the key does not cover.
      final score = computeExamScore(
        _result(
          'AT',
          _section(_atSection, correct: 60, wrong: 5, ungraded: 7),
        ),
        _atTemplate,
      );

      expect(score.rawScore, 60);
      expect(score.totalItems, 72);
      expect(score.totalGraded, 65); // 60 + 5
      expect(score.percentage, closeTo(83.33, 0.01)); // 60 / 72 * 100
      // Explicitly NOT 60 / 65 * 100 = 92.31.
      expect(score.percentage, isNot(closeTo(92.31, 0.5)));
    });

    test('wrong, blank and ambiguous answers each contribute 0', () {
      final score = computeExamScore(
        _result(
          'AT',
          _section(_atSection,
              correct: 50, wrong: 10, blank: 8, ambiguous: 4),
        ),
        _atTemplate,
      );
      expect(score.rawScore, 50);
      expect(score.percentage, closeTo(50 / 72 * 100, 0.001));
    });
  });

  group('QTM — raw scoring, no official percentage', () {
    test('5. 60 correct -> raw 60', () {
      final score = computeExamScore(
        _result('QTM', _section(_qtmSection, correct: 60)),
        _qtmTemplate,
      );
      expect(score.model, ExamScoringModel.raw);
      expect(score.rawScore, 60);
      expect(score.totalItems, 60);
      expect(score.isGraded, isTrue);
    });

    test('6. 35 correct -> raw 35', () {
      final score = computeExamScore(
        _result('QTM', _section(_qtmSection, correct: 35, wrong: 25)),
        _qtmTemplate,
      );
      expect(score.rawScore, 35);
    });

    test('7. 0 correct -> raw 0', () {
      final score = computeExamScore(
        _result('QTM', _section(_qtmSection, blank: 60)),
        _qtmTemplate,
      );
      expect(score.rawScore, 0);
    });

    test('8. wrong and blank answers contribute 0', () {
      final score = computeExamScore(
        _result(
          'QTM',
          _section(_qtmSection, correct: 40, wrong: 12, blank: 8),
        ),
        _qtmTemplate,
      );
      expect(score.rawScore, 40);
    });

    test('QTM exposes no official percentage (0.0, flagged unofficial)', () {
      final score = computeExamScore(
        _result('QTM', _section(_qtmSection, correct: 60)),
        _qtmTemplate,
      );
      expect(score.percentage, 0.0);
      expect(score.hasOfficialPercentage, isFalse);
    });
  });

  group('TAT Test 1 — correct x 2', () {
    ExamScore tat1(int correct, {int wrong = 0}) => computeExamScore(
          _result('TAT', _section(_tat1, correct: correct, wrong: wrong)),
          _tatTemplate,
        );

    test('9. 30 correct -> 60', () {
      final s = tat1(30);
      expect(s.model, ExamScoringModel.tat);
      expect(s.isTat, isTrue);
      expect(s.tatTest1Correct, 30);
      expect(s.tatTest1Wrong, 0);
      expect(s.tatTest1Score, 60);
    });

    test('10. 15 correct -> 30', () {
      final s = tat1(15, wrong: 15);
      expect(s.tatTest1Correct, 15);
      expect(s.tatTest1Score, 30);
    });

    test('11. 0 correct -> 0 (wrong answers never subtract in Test 1)', () {
      final s = tat1(0, wrong: 30);
      expect(s.tatTest1Correct, 0);
      expect(s.tatTest1Wrong, 30);
      expect(s.tatTest1Score, 0);
    });
  });

  group('TAT Test 2 — max(0, correct - wrong)', () {
    ExamScore tat2({
      int correct = 0,
      int wrong = 0,
      int blank = 0,
      int ambiguous = 0,
    }) =>
        computeExamScore(
          _result(
            'TAT',
            _section(_tat2,
                correct: correct,
                wrong: wrong,
                blank: blank,
                ambiguous: ambiguous),
          ),
          _tatTemplate,
        );

    test('12. 80 correct, 0 wrong -> 80', () {
      final s = tat2(correct: 80);
      expect(s.tatTest2Correct, 80);
      expect(s.tatTest2Wrong, 0);
      expect(s.tatTest2Score, 80);
    });

    test('13. 10 correct, 10 wrong -> 0', () {
      expect(tat2(correct: 10, wrong: 10).tatTest2Score, 0);
    });

    test('14. 5 correct, 15 wrong -> 0', () {
      expect(tat2(correct: 5, wrong: 15).tatTest2Score, 0);
    });

    test('15. 50 correct, 20 wrong -> 30', () {
      final s = tat2(correct: 50, wrong: 20);
      expect(s.tatTest2Correct, 50);
      expect(s.tatTest2Wrong, 20);
      expect(s.tatTest2Score, 30);
    });

    test('16. negative raw (5 - 15) is clamped to 0, never negative', () {
      final s = tat2(correct: 5, wrong: 15);
      expect(s.tatTest2Score, 0);
      expect(s.tatTest2Score! >= 0, isTrue);
      expect(s.tatTotal! >= 0, isTrue);
      expect(s.rawScore >= 0, isTrue);
    });

    test('17. blank answers do not count as wrong', () {
      final s = tat2(correct: 10, blank: 20);
      expect(s.tatTest2Wrong, 0);
      expect(s.tatTest2Score, 10);
    });

    test('18. ambiguous answers do not count as wrong', () {
      final s = tat2(correct: 10, ambiguous: 15);
      expect(s.tatTest2Wrong, 0);
      expect(s.tatTest2Score, 10);
    });
  });

  group('TAT Test 3 — max(0, correct - wrong)', () {
    ExamScore tat3(int correct, int wrong) => computeExamScore(
          _result('TAT', _section(_tat3, correct: correct, wrong: wrong)),
          _tatTemplate,
        );

    test('19. 20 correct, 0 wrong -> 20', () {
      final s = tat3(20, 0);
      expect(s.tatTest3Correct, 20);
      expect(s.tatTest3Wrong, 0);
      expect(s.tatTest3Score, 20);
    });

    test('20. 10 correct, 10 wrong -> 0', () {
      expect(tat3(10, 10).tatTest3Score, 0);
    });

    test('21. 5 correct, 15 wrong -> 0', () {
      expect(tat3(5, 15).tatTest3Score, 0);
    });
  });

  group('TAT total = Test 1 + Test 2 + Test 3', () {
    test('22. 50 + 0 + 10 -> 60', () {
      final score = computeExamScore(
        _result('TAT', [
          ..._section(_tat1, correct: 25, wrong: 5), // 25 * 2 = 50
          ..._section(_tat2, correct: 10, wrong: 10), // max(0, 0) = 0
          ..._section(_tat3, correct: 15, wrong: 5), // max(0, 10) = 10
        ]),
        _tatTemplate,
      );

      expect(score.tatTest1Score, 50);
      expect(score.tatTest2Score, 0);
      expect(score.tatTest3Score, 10);
      expect(score.tatTotal, 60);
      expect(score.rawScore, 60); // headline number mirrors tatTotal
    });

    test('23. perfect TAT: 60 + 80 + 20 -> 160', () {
      final score = computeExamScore(
        _result('TAT', [
          ..._section(_tat1, correct: 30),
          ..._section(_tat2, correct: 80),
          ..._section(_tat3, correct: 20),
        ]),
        _tatTemplate,
      );

      expect(score.tatTest1Score, 60);
      expect(score.tatTest2Score, 80);
      expect(score.tatTest3Score, 20);
      expect(score.tatTotal, 160);
      expect(score.rawScore, 160);
    });

    test(
        '24. TAT total cannot exceed 160 for a template-conformant sheet; '
        'each test stays within its own maximum', () {
      // A realistic spread across all three tests (item counts within the
      // 30 / 80 / 20 the template declares).
      final mixed = computeExamScore(
        _result('TAT', [
          ..._section(_tat1, correct: 22, wrong: 8),
          ..._section(_tat2, correct: 61, wrong: 12, blank: 7),
          ..._section(_tat3, correct: 14, wrong: 6),
        ]),
        _tatTemplate,
      );
      expect(mixed.tatTest1Score! <= 60, isTrue);
      expect(mixed.tatTest2Score! <= 80, isTrue);
      expect(mixed.tatTest3Score! <= 20, isTrue);
      expect(mixed.tatTotal! <= 160, isTrue);
      expect(mixed.tatTotal,
          mixed.tatTest1Score! + mixed.tatTest2Score! + mixed.tatTest3Score!);

      // The maximum is reached only by the perfect sheet.
      final perfect = computeExamScore(
        _result('TAT', [
          ..._section(_tat1, correct: 30),
          ..._section(_tat2, correct: 80),
          ..._section(_tat3, correct: 20),
        ]),
        _tatTemplate,
      );
      expect(perfect.tatTotal, 160);
    });

    test('ungraded TAT (no answer key) -> every test 0, isGraded false', () {
      final score = computeExamScore(
        _result('TAT', [
          ..._section(_tat1, ungraded: 30),
          ..._section(_tat2, ungraded: 80),
          ..._section(_tat3, ungraded: 20),
        ]),
        _tatTemplate,
      );
      expect(score.isGraded, isFalse);
      expect(score.tatTest1Score, 0);
      expect(score.tatTest2Score, 0);
      expect(score.tatTest3Score, 0);
      expect(score.tatTotal, 0);
      expect(score.percentage, 0.0);
    });
  });

  group('computeExamScoreForCode (template resolved from omrTemplates)', () {
    test('resolves AT / QTM / TAT', () {
      expect(
        computeExamScoreForCode(_result('AT', _section(_atSection, correct: 72)))
            ?.rawScore,
        72,
      );
      expect(
        computeExamScoreForCode(
                _result('QTM', _section(_qtmSection, correct: 60)))
            ?.rawScore,
        60,
      );
      expect(
        computeExamScoreForCode(
                _result('TAT', _section(_tat1, correct: 30)))
            ?.tatTest1Score,
        60,
      );
    });

    test('returns null for an unregistered exam code', () {
      expect(computeExamScoreForCode(_result('NOPE', const [])), isNull);
    });
  });
}
