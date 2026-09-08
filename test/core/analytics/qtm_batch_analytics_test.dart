import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/analytics/qtm_batch_analytics.dart';
import 'package:guidegrade/core/omr/qtm_result.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

final _fixedAt = DateTime.utc(2026, 1, 1);
var _seq = 0;

LocalScanResult _gradedResult(int rawScore, {double legacyPercentage = 0}) =>
    LocalScanResult(
      rawScore: rawScore,
      totalGraded: 60,
      totalItems: 60,
      // Legacy/generic value — analytics must never read this.
      percentage: legacyPercentage,
      status: 'Graded',
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScanResult _ungradedResult() => LocalScanResult(
      rawScore: 0,
      totalGraded: 0,
      totalItems: 60,
      percentage: 0,
      status: 'Ungraded',
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScan _scan({
  String? id,
  LocalScanResult? result,
  ExamineeInfo? examinee,
}) =>
    LocalScan(
      id: id ?? 's${_seq++}',
      imageFileName: 'images/x.jpg',
      capturedAt: _fixedAt,
      decoded: const OmrScanResult(examCode: 'QTM', items: []),
      result: result,
      examinee: examinee,
    );

LocalScan _graded(int rawScore, {String? id, ExamineeInfo? examinee, double legacyPercentage = 0}) =>
    _scan(
      id: id,
      result: _gradedResult(rawScore, legacyPercentage: legacyPercentage),
      examinee: examinee,
    );

LocalScan _ungraded({String? id}) => _scan(id: id, result: _ungradedResult());

/// A scan whose result is null (never graded at all).
LocalScan _noResult({String? id}) => _scan(id: id);

LocalBatch _batch(String examCode, List<LocalScan> scans) => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: examCode,
      examTitle: 't',
      description: '',
      expectedCount: 0,
      status: 'Completed',
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: _fixedAt,
      updatedAt: _fixedAt,
      scans: scans,
    );

QtmBatchAnalytics _analyse(List<LocalScan> scans) =>
    QtmBatchAnalytics.fromScans(scans);

void main() {
  group('1. Empty batch', () {
    final a = _analyse(const []);
    test('counts are all zero', () {
      expect(a.totalExaminees, 0);
      expect(a.gradedExaminees, 0);
      expect(a.ungradedExaminees, 0);
    });
    test('all graded aggregates are null', () {
      expect(a.averageRawScore, isNull);
      expect(a.averagePercentage, isNull);
      expect(a.highestRawScore, isNull);
      expect(a.lowestRawScore, isNull);
      expect(a.medianRawScore, isNull);
    });
    test('distributions and scorers are empty', () {
      expect(a.eligibilityDistribution, isEmpty);
      expect(a.scoreDistribution, isEmpty);
      expect(a.rankedScorers, isEmpty);
      expect(a.topScorers(), isEmpty);
    });
  });

  group('2. All scans ungraded', () {
    final a = _analyse([_ungraded(), _ungraded(), _noResult()]);
    test('totals split correctly', () {
      expect(a.totalExaminees, 3);
      expect(a.gradedExaminees, 0);
      expect(a.ungradedExaminees, 3);
    });
    test('graded aggregates null/empty', () {
      expect(a.averageRawScore, isNull);
      expect(a.averagePercentage, isNull);
      expect(a.medianRawScore, isNull);
      expect(a.eligibilityDistribution, isEmpty);
      expect(a.scoreDistribution, isEmpty);
      expect(a.rankedScorers, isEmpty);
    });
  });

  group('3. One graded examinee (raw 40)', () {
    final a = _analyse([_graded(40, id: 'g40')]);
    test('counts', () {
      expect(a.totalExaminees, 1);
      expect(a.gradedExaminees, 1);
      expect(a.ungradedExaminees, 0);
    });
    test('aggregates', () {
      expect(a.averageRawScore, 40.0);
      expect(a.averagePercentage, closeTo(40 / 60 * 100, 1e-9)); // 66.67
      expect(a.highestRawScore, 40);
      expect(a.lowestRawScore, 40);
      expect(a.medianRawScore, 40.0);
    });
    test('eligibility distribution has all three keys', () {
      expect(a.eligibilityDistribution.keys.toSet(),
          QtmEligibility.values.toSet());
      expect(a.eligibilityDistribution[QtmEligibility.allCoursesIncludingBscs], 1);
      expect(a.eligibilityDistribution[QtmEligibility.allCoursesExceptBscs], 0);
      expect(a.eligibilityDistribution[QtmEligibility.notEligible], 0);
    });
    test('score distribution has all six bands', () {
      expect(a.scoreDistribution.keys.toSet(), QtmScoreBand.values.toSet());
      expect(a.scoreDistribution[QtmScoreBand.band40to49], 1);
      expect(
        a.scoreDistribution.values.fold<int>(0, (x, y) => x + y),
        1,
      );
    });
    test('ranking', () {
      expect(a.rankedScorers, hasLength(1));
      final s = a.rankedScorers.single;
      expect(s.rank, 1);
      expect(s.scanId, 'g40');
      expect(s.rawScore, 40);
      expect(s.percentage, closeTo(66.666, 0.01));
      expect(s.eligibility, QtmEligibility.allCoursesIncludingBscs);
      expect(a.topScorers(), hasLength(1));
    });
  });

  group('4. Mixed graded/ungraded', () {
    final a = _analyse([_graded(30), _graded(10), _ungraded()]);
    test('totals', () {
      expect(a.totalExaminees, 3);
      expect(a.gradedExaminees, 2);
      expect(a.ungradedExaminees, 1);
    });
    test('only graded scans feed aggregates', () {
      expect(a.averageRawScore, 20.0);
      expect(a.averagePercentage, closeTo(20 / 60 * 100, 1e-9)); // 33.33
      expect(a.highestRawScore, 30);
      expect(a.lowestRawScore, 10);
      expect(a.medianRawScore, 20.0);
      expect(a.eligibilityDistribution[QtmEligibility.allCoursesIncludingBscs], 1);
      expect(a.eligibilityDistribution[QtmEligibility.notEligible], 1);
      expect(a.eligibilityDistribution[QtmEligibility.allCoursesExceptBscs], 0);
      expect(a.scoreDistribution[QtmScoreBand.band30to39], 1);
      expect(a.scoreDistribution[QtmScoreBand.band10to19], 1);
      expect(a.rankedScorers, hasLength(2));
    });
  });

  group('5–10. official eligibility boundaries (single graded scan each)', () {
    const cases = <int, (double, QtmEligibility)>{
      0: (0.0, QtmEligibility.notEligible),
      14: (23.333333, QtmEligibility.notEligible),
      15: (25.0, QtmEligibility.allCoursesExceptBscs),
      17: (28.333333, QtmEligibility.allCoursesExceptBscs),
      18: (30.0, QtmEligibility.allCoursesIncludingBscs),
      60: (100.0, QtmEligibility.allCoursesIncludingBscs),
    };
    cases.forEach((raw, expected) {
      final (pct, elig) = expected;
      test('raw $raw -> ${pct.toStringAsFixed(2)}% / $elig', () {
        final a = _analyse([_graded(raw)]);
        expect(a.averageRawScore, raw.toDouble());
        expect(a.averagePercentage, closeTo(pct, 1e-4));
        expect(a.eligibilityDistribution[elig], 1);
        expect(a.rankedScorers.single.percentage, closeTo(pct, 1e-4));
        expect(a.rankedScorers.single.eligibility, elig);
      });
    });
  });

  group('11. average raw score, multiple graded', () {
    test('[10,20,30,40] -> 25.0', () {
      final a = _analyse([_graded(10), _graded(20), _graded(30), _graded(40)]);
      expect(a.averageRawScore, 25.0);
    });
  });

  group('12. average official percentage, multiple graded', () {
    test('[12,30] -> mean(20.0, 50.0) == 35.0', () {
      final a = _analyse([_graded(12), _graded(30)]);
      expect(a.averagePercentage, closeTo(35.0, 1e-9));
    });
  });

  group('13. median — odd count', () {
    test('[10,40,25] -> 25.0', () {
      final a = _analyse([_graded(10), _graded(40), _graded(25)]);
      expect(a.medianRawScore, 25.0);
    });
  });

  group('14. median — even count', () {
    test('[10,20,30,50] -> (20+30)/2 == 25.0', () {
      final a = _analyse([_graded(10), _graded(20), _graded(30), _graded(50)]);
      expect(a.medianRawScore, 25.0);
    });
  });

  group('15. duplicate scores', () {
    final a = _analyse([_graded(30), _graded(30), _graded(30)]);
    test('aggregates', () {
      expect(a.averageRawScore, 30.0);
      expect(a.medianRawScore, 30.0);
      expect(a.highestRawScore, 30);
      expect(a.lowestRawScore, 30);
      expect(a.scoreDistribution[QtmScoreBand.band30to39], 3);
    });
    test('all share dense rank 1', () {
      expect(a.rankedScorers.map((s) => s.rank), everyElement(1));
      expect(a.rankedScorers, hasLength(3));
    });
  });

  group('16. highest and lowest', () {
    test('[5,55,22] -> highest 55, lowest 5', () {
      final a = _analyse([_graded(5), _graded(55), _graded(22)]);
      expect(a.highestRawScore, 55);
      expect(a.lowestRawScore, 5);
    });
  });

  group('17. score distribution boundaries', () {
    test('one scan at each of 0,9,10,19,20,29,30,39,40,49,50,60', () {
      final a = _analyse([
        for (final raw in [0, 9, 10, 19, 20, 29, 30, 39, 40, 49, 50, 60])
          _graded(raw),
      ]);
      expect(a.gradedExaminees, 12);
      expect(a.scoreDistribution, {
        QtmScoreBand.band0to9: 2,
        QtmScoreBand.band10to19: 2,
        QtmScoreBand.band20to29: 2,
        QtmScoreBand.band30to39: 2,
        QtmScoreBand.band40to49: 2,
        QtmScoreBand.band50to60: 2,
      });
    });
  });

  group('18. eligibility distribution counts', () {
    test('3 per band', () {
      final a = _analyse([
        for (final raw in [0, 10, 14, 15, 16, 17, 18, 30, 60]) _graded(raw),
      ]);
      expect(a.eligibilityDistribution, {
        QtmEligibility.allCoursesIncludingBscs: 3,
        QtmEligibility.allCoursesExceptBscs: 3,
        QtmEligibility.notEligible: 3,
      });
    });
  });

  group('19. ranking with duplicate scores (dense)', () {
    test('[60,60,59,58] -> ranks [1,1,2,3]', () {
      final a = _analyse([_graded(60), _graded(60), _graded(59), _graded(58)]);
      expect(a.rankedScorers.map((s) => s.rawScore).toList(), [60, 60, 59, 58]);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 1, 2, 3]);
    });
  });

  group('20. top scorers — ties at the cutoff', () {
    final a = _analyse([_graded(60), _graded(59), _graded(59), _graded(58)]);
    test('limit 2 includes both 59s (ranks 1,2,2)', () {
      final top = a.topScorers(limit: 2);
      expect(top.map((s) => s.rawScore).toList(), [60, 59, 59]);
      expect(top.map((s) => s.rank).toList(), [1, 2, 2]);
    });
    test('limit 1 -> just the 60', () {
      expect(a.topScorers(limit: 1).map((s) => s.rawScore).toList(), [60]);
    });
    test('limit 0 and negative -> empty', () {
      expect(a.topScorers(limit: 0), isEmpty);
      expect(a.topScorers(limit: -3), isEmpty);
    });
    test('default limit 5 returns all four here', () {
      expect(a.topScorers(), hasLength(4));
    });
  });

  group('21. incomplete / missing examinee identity does not crash', () {
    final complete = ExamineeInfo(
        firstName: 'Ann', lastName: 'Cruz', examineeNumber: 'E-100');
    final nameOnly = ExamineeInfo(
        firstName: 'Ben', lastName: 'Diaz', examineeNumber: '');
    const empty = ExamineeInfo(firstName: '', lastName: '', examineeNumber: '');

    final a = _analyse([
      _graded(50, id: 'complete', examinee: complete),
      _graded(40, id: 'nameOnly', examinee: nameOnly),
      _graded(30, id: 'emptyTag', examinee: empty),
      _graded(20, id: 'noTag'), // examinee == null
    ]);

    QtmRankedScorer by(String scanId) =>
        a.rankedScorers.firstWhere((s) => s.scanId == scanId);

    test('no exception; all four ranked', () {
      expect(a.rankedScorers, hasLength(4));
      expect(a.gradedExaminees, 4);
    });
    test('complete tag exposes number + name', () {
      expect(by('complete').examineeNumber, 'E-100');
      expect(by('complete').displayName, 'Cruz, Ann');
    });
    test('name-only tag: number null, name present', () {
      expect(by('nameOnly').examineeNumber, isNull);
      expect(by('nameOnly').displayName, 'Diaz, Ben');
    });
    test('blank tag: number null, displayName "Unnamed"', () {
      expect(by('emptyTag').examineeNumber, isNull);
      expect(by('emptyTag').displayName, 'Unnamed');
    });
    test('no examinee object: number null, name null', () {
      expect(by('noTag').examineeNumber, isNull);
      expect(by('noTag').displayName, isNull);
    });
  });

  group('22. legacy percentage regression', () {
    test('raw 26 with legacy percentage 99.9 -> official ~43.33%, never 99.9',
        () {
      final a = _analyse([_graded(26, legacyPercentage: 99.9)]);
      expect(a.averageRawScore, 26.0);
      expect(a.averagePercentage, closeTo(26 / 60 * 100, 1e-9)); // 43.333...
      expect(a.averagePercentage, closeTo(43.33, 0.01));
      expect(a.averagePercentage, isNot(closeTo(99.9, 1.0)));
      expect(a.rankedScorers.single.percentage, closeTo(43.33, 0.01));
      expect(a.rankedScorers.single.percentage, isNot(closeTo(99.9, 1.0)));
    });
  });

  group('23. fromBatch', () {
    test('non-QTM batch is rejected with ArgumentError', () {
      expect(
        () => QtmBatchAnalytics.fromBatch(_batch('AT', const [])),
        throwsArgumentError,
      );
      expect(
        () => QtmBatchAnalytics.fromBatch(_batch('TAT', [_graded(30)])),
        throwsArgumentError,
      );
    });
    test('QTM batch delegates to the scan analysis', () {
      final a = QtmBatchAnalytics.fromBatch(
        _batch('QTM', [_graded(40), _ungraded()]),
      );
      expect(a.totalExaminees, 2);
      expect(a.gradedExaminees, 1);
      expect(a.averageRawScore, 40.0);
    });
  });

  group('immutability of exposed collections', () {
    final a = _analyse([_graded(40), _graded(20)]);
    test('rankedScorers / distributions are unmodifiable', () {
      expect(a.rankedScorers.clear, throwsUnsupportedError);
      expect(() => a.eligibilityDistribution[QtmEligibility.notEligible] = 9,
          throwsUnsupportedError);
      expect(() => a.scoreDistribution[QtmScoreBand.band0to9] = 9,
          throwsUnsupportedError);
      expect(a.topScorers().clear, throwsUnsupportedError);
    });
  });

  group('QtmScoreBand.forRawScore', () {
    test('band edges and out-of-range', () {
      expect(QtmScoreBand.forRawScore(0), QtmScoreBand.band0to9);
      expect(QtmScoreBand.forRawScore(9), QtmScoreBand.band0to9);
      expect(QtmScoreBand.forRawScore(10), QtmScoreBand.band10to19);
      expect(QtmScoreBand.forRawScore(49), QtmScoreBand.band40to49);
      expect(QtmScoreBand.forRawScore(50), QtmScoreBand.band50to60);
      expect(QtmScoreBand.forRawScore(60), QtmScoreBand.band50to60);
      expect(QtmScoreBand.forRawScore(-1), isNull);
      expect(QtmScoreBand.forRawScore(61), isNull);
    });
  });
}
