import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/exam_score.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/models/local_batch.dart';

/// Phase 3 — verifies that the value actually persisted for a scanned
/// sheet ([LocalScanResult], built by [buildLocalScanResult], which BOTH
/// AppState.persistCapturedSessionToBatch and AppState.finishRescan now
/// call) carries the official exam-aware score, not the old generic one.
///
/// The exam-score arithmetic itself is covered exhaustively by
/// test/core/omr/exam_score_test.dart; these tests are about the wiring.

// --- Per-item builders (see also exam_score_test.dart). ---

ScoredItem _correct(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: 'A',
    );

ScoredItem _wrong(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: 'B',
    );

ScoredItem _blank(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: null,
      isAmbiguous: false,
      correctChoice: 'B',
    );

/// Key does not cover this item (correctChoice == null): graded neither
/// right nor wrong.
ScoredItem _ungraded(String section, int n) => ScoredItem(
      sectionName: section,
      itemNumber: n,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: null,
    );

List<ScoredItem> _fill(
  String section, {
  int correct = 0,
  int wrong = 0,
  int blank = 0,
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
  for (var i = 0; i < ungraded; i++) {
    items.add(_ungraded(section, n++));
  }
  return items;
}

/// Runs the exact mapping both persistence paths use.
LocalScanResult _persist(ScoredResult scored) => buildLocalScanResult(
      scored,
      computeExamScoreForCode(scored),
      processedByUid: 'uid-1',
      processedByName: 'Officer J',
    );

void main() {
  group('1. Admission Test persistence', () {
    test(
        '60 correct with only 65 graded key entries -> raw 60, totalItems 72, '
        'percentage 60/72 (never 60/65)', () {
      final scored = ScoredResult(
        examCode: 'AT',
        items: _fill('Answer Document', correct: 60, wrong: 5, ungraded: 7),
      );

      final result = _persist(scored);

      expect(result.rawScore, 60);
      expect(result.totalItems, 72);
      expect(result.totalGraded, 65); // 60 correct + 5 definite wrong
      expect(result.percentage, closeTo(83.33, 0.01)); // 60 / 72 * 100
      // Guards against regression to answer-key-coverage denominator:
      expect(result.percentage, isNot(closeTo(92.31, 0.5))); // 60 / 65 * 100
      expect(result.status, 'Graded');
      expect(result.hasTatBreakdown, isFalse);
      expect(result.tatTotal, isNull);
      expect(result.processedByUid, 'uid-1');
      expect(result.processedByName, 'Officer J');
    });

    test('72 correct -> raw 72, percentage 100', () {
      final result = _persist(ScoredResult(
        examCode: 'AT',
        items: _fill('Answer Document', correct: 72),
      ));
      expect(result.rawScore, 72);
      expect(result.totalItems, 72);
      expect(result.percentage, 100.0);
    });
  });

  group('2. QTM persistence', () {
    test('35 correct / 25 wrong -> raw 35, totalItems 60, no invented '
        'official percentage', () {
      final scored = ScoredResult(
        examCode: 'QTM',
        items: _fill('Qualifying Test in Mathematics', correct: 35, wrong: 25),
      );

      final result = _persist(scored);

      expect(result.rawScore, 35); // correct answers only
      expect(result.totalItems, 60);
      expect(result.status, 'Graded');
      expect(result.hasTatBreakdown, isFalse);

      // QTM has no official percentage. This phase preserves the existing
      // generic value rather than inventing a rule or forcing 0%.
      expect(result.percentage, scored.percentage);
      expect(result.percentage, isNot(0.0));
    });

    test('wrong and blank answers contribute 0 to the QTM raw score', () {
      final result = _persist(ScoredResult(
        examCode: 'QTM',
        items: _fill('Qualifying Test in Mathematics',
            correct: 40, wrong: 12, blank: 8),
      ));
      expect(result.rawScore, 40);
      expect(result.totalItems, 60);
    });
  });

  group('3. TAT persistence — full breakdown', () {
    test(
        'T1 25 correct -> 50, T2 10c/10w -> 0, T3 15c/5w -> 10; '
        'total 60, raw 60, totalItems 130', () {
      final scored = ScoredResult(
        examCode: 'TAT',
        items: [
          ..._fill('Test I', correct: 25, blank: 5), // 30 items, no wrong
          ..._fill('Test II', correct: 10, wrong: 10, blank: 60), // 80 items
          ..._fill('Test III', correct: 15, wrong: 5), // 20 items
        ],
      );

      final result = _persist(scored);

      expect(result.tatTest1Correct, 25);
      expect(result.tatTest1Wrong, 0);
      expect(result.tatTest1Score, 50);

      expect(result.tatTest2Correct, 10);
      expect(result.tatTest2Wrong, 10);
      expect(result.tatTest2Score, 0);

      expect(result.tatTest3Correct, 15);
      expect(result.tatTest3Wrong, 5);
      expect(result.tatTest3Score, 10);

      expect(result.tatTotal, 60);
      expect(result.rawScore, 60); // headline mirrors tatTotal
      expect(result.totalItems, 130);
      expect(result.status, 'Graded');
      expect(result.hasTatBreakdown, isTrue);
    });

    test('the persisted TAT breakdown survives a JSON round-trip', () {
      final result = _persist(ScoredResult(
        examCode: 'TAT',
        items: [
          ..._fill('Test I', correct: 25, blank: 5),
          ..._fill('Test II', correct: 10, wrong: 10, blank: 60),
          ..._fill('Test III', correct: 15, wrong: 5),
        ],
      ));

      final restored = LocalScanResult.fromJson(result.toJson());
      expect(restored.tatTest1Score, 50);
      expect(restored.tatTest2Score, 0);
      expect(restored.tatTest3Score, 10);
      expect(restored.tatTotal, 60);
      expect(restored.rawScore, 60);
      expect(restored.totalItems, 130);
    });
  });

  group('4. TAT negative-floor persistence', () {
    test('T2 5c/15w and T3 5c/15w both persist 0, nothing negative', () {
      final result = _persist(ScoredResult(
        examCode: 'TAT',
        items: [
          ..._fill('Test I', blank: 30),
          ..._fill('Test II', correct: 5, wrong: 15, blank: 60),
          ..._fill('Test III', correct: 5, wrong: 15),
        ],
      ));

      expect(result.tatTest2Score, 0);
      expect(result.tatTest3Score, 0);
      expect(result.tatTest2Score! >= 0, isTrue);
      expect(result.tatTest3Score! >= 0, isTrue);
      expect(result.tatTotal, 0);
      expect(result.tatTotal! >= 0, isTrue);
      expect(result.rawScore >= 0, isTrue);
    });
  });

  group('5. Rescan consistency', () {
    // A full AppState.finishRescan integration run is excessively invasive
    // (it needs Firebase auth, real captured image files, and background
    // compute isolates for OCR). Instead we pin the guarantee both paths
    // rely on: persistCapturedSessionToBatch and finishRescan call the
    // SAME buildLocalScanResult(scored, computeExamScoreForCode(scored),..)
    // and that mapping is deterministic for a given ScoredResult.
    test('buildLocalScanResult is deterministic for identical input', () {
      ScoredResult tat() => ScoredResult(
            examCode: 'TAT',
            items: [
              ..._fill('Test I', correct: 22, wrong: 8),
              ..._fill('Test II', correct: 40, wrong: 10, blank: 30),
              ..._fill('Test III', correct: 12, wrong: 8),
            ],
          );

      final a = _persist(tat());
      final b = _persist(tat());

      expect(a.toJson()..remove('scannedAt'),
          b.toJson()..remove('scannedAt'));
      expect(a.rawScore, b.rawScore);
      expect(a.tatTotal, b.tatTotal);
    });

    test('an unregistered exam code falls back to the generic values', () {
      final scored = ScoredResult(
        examCode: 'ZZZ',
        items: _fill('whatever', correct: 4, wrong: 1),
      );
      // computeExamScoreForCode returns null -> generic branch.
      final result = _persist(scored);
      expect(result.rawScore, scored.rawScore);
      expect(result.totalItems, scored.items.length);
      expect(result.percentage, scored.percentage);
      expect(result.tatTotal, isNull);
    });
  });

  group('graded / ungraded status is unchanged', () {
    test('a sheet the answer key does not cover persists as Ungraded', () {
      final result = _persist(ScoredResult(
        examCode: 'AT',
        items: _fill('Answer Document', ungraded: 72),
      ));
      expect(result.status, 'Ungraded');
      expect(result.rawScore, 0);
      expect(result.percentage, 0.0);
    });
  });
}
