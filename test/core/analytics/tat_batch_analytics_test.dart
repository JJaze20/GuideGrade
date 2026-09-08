import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/analytics/tat_batch_analytics.dart';
import 'package:guidegrade/core/omr/tat_result.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

final _fixedAt = DateTime.utc(2026, 1, 1);
var _seq = 0;

/// Low-level result builder. Any of the per-test scores / total may be left
/// null to model missing or legacy data. `tatTotal` is only set when
/// [total] is non-null (so [LocalScanResult.hasTatBreakdown] follows it).
LocalScanResult _result({
  String status = 'Graded',
  double legacyPercentage = 0,
  int? t1Score,
  int? t2Score,
  int? t3Score,
  int? total,
}) =>
    LocalScanResult(
      rawScore: total ?? 0,
      totalGraded: 130,
      totalItems: 130,
      // Legacy/generic value — analytics must never read this.
      percentage: legacyPercentage,
      status: status,
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
      tatTest1Correct: t1Score == null ? null : t1Score ~/ 2,
      tatTest1Wrong: t1Score == null ? null : 0,
      tatTest1Score: t1Score,
      tatTest2Correct: t2Score,
      tatTest2Wrong: t2Score == null ? null : 0,
      tatTest2Score: t2Score,
      tatTest3Correct: t3Score,
      tatTest3Wrong: t3Score == null ? null : 0,
      tatTest3Score: t3Score,
      tatTotal: total,
    );

/// A clean graded TAT result with a full breakdown. [total] defaults to the
/// sum of the three sub-scores.
LocalScanResult _gradedTat(
  int t1,
  int t2,
  int t3, {
  int? total,
  double legacyPercentage = 0,
}) =>
    _result(
      t1Score: t1,
      t2Score: t2,
      t3Score: t3,
      total: total ?? (t1 + t2 + t3),
      legacyPercentage: legacyPercentage,
    );

/// Graded but with no TAT breakdown at all (a pre-breakdown legacy record).
LocalScanResult _legacyGraded() => LocalScanResult(
      rawScore: 74,
      totalGraded: 130,
      totalItems: 130,
      percentage: 49,
      status: 'Graded',
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScanResult _ungradedResult() => _result(status: 'Ungraded');

LocalScan _scan({
  String? id,
  LocalScanResult? result,
  ExamineeInfo? examinee,
}) =>
    LocalScan(
      id: id ?? 's${_seq++}',
      imageFileName: 'images/x.jpg',
      capturedAt: _fixedAt,
      decoded: const OmrScanResult(examCode: 'TAT', items: []),
      result: result,
      examinee: examinee,
    );

LocalScan _graded(
  int t1,
  int t2,
  int t3, {
  String? id,
  ExamineeInfo? examinee,
  int? total,
  double legacyPercentage = 0,
}) =>
    _scan(
      id: id,
      result: _gradedTat(t1, t2, t3, total: total, legacyPercentage: legacyPercentage),
      examinee: examinee,
    );

/// A graded scan for an exact TAT [total], spreading it across the three
/// tests within their caps (60 / 80 / 20).
LocalScan _gradedForTotal(int total, {String? id}) {
  final t1 = total < 60 ? total : 60;
  final remainder = total - t1;
  final t2 = remainder < 80 ? remainder : 80;
  final t3 = remainder - t2;
  return _scan(id: id, result: _gradedTat(t1, t2, t3, total: total));
}

LocalScan _ungraded({String? id}) => _scan(id: id, result: _ungradedResult());

/// A scan whose result is null (never graded at all).
LocalScan _noResult({String? id}) => _scan(id: id);

LocalScan _legacyScan({String? id}) => _scan(id: id, result: _legacyGraded());

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

TatBatchAnalytics _analyse(List<LocalScan> scans) =>
    TatBatchAnalytics.fromScans(scans);

void main() {
  group('1. Empty batch', () {
    final a = _analyse(const []);
    test('counts are all zero', () {
      expect(a.totalExaminees, 0);
      expect(a.gradedExaminees, 0);
      expect(a.ungradedExaminees, 0);
      expect(a.analyzableExaminees, 0);
      expect(a.excludedGradedCount, 0);
    });
    test('all total aggregates are null', () {
      expect(a.averageTatTotal, isNull);
      expect(a.highestTatTotal, isNull);
      expect(a.lowestTatTotal, isNull);
      expect(a.medianTatTotal, isNull);
      expect(a.averageTatPercentage, isNull);
      expect(a.highestTatPercentage, isNull);
      expect(a.lowestTatPercentage, isNull);
      expect(a.medianTatPercentage, isNull);
    });
    test('per-test summaries are empty', () {
      for (final s in [a.test1, a.test2, a.test3]) {
        expect(s.scoreCount, 0);
        expect(s.average, isNull);
        expect(s.highest, isNull);
        expect(s.lowest, isNull);
        expect(s.median, isNull);
        expect(s.averagePercentOfMax, isNull);
      }
      expect(a.test1.maxPossible, 60);
      expect(a.test2.maxPossible, 80);
      expect(a.test3.maxPossible, 20);
    });
    test('distributions, scorers and rate are empty/null', () {
      expect(a.eligibilityDistribution, isEmpty);
      expect(a.totalScoreDistribution, isEmpty);
      expect(a.test1Distribution, isEmpty);
      expect(a.test2Distribution, isEmpty);
      expect(a.test3Distribution, isEmpty);
      expect(a.rankedScorers, isEmpty);
      expect(a.topScorers(), isEmpty);
      expect(a.meetsRequirementRate, isNull);
      expect(a.strongestTestByPercent, isNull);
      expect(a.weakestTestByPercent, isNull);
    });
  });

  group('2. All scans ungraded', () {
    final a = _analyse([_ungraded(), _ungraded(), _noResult()]);
    test('totals split correctly', () {
      expect(a.totalExaminees, 3);
      expect(a.gradedExaminees, 0);
      expect(a.ungradedExaminees, 3);
      expect(a.analyzableExaminees, 0);
      expect(a.excludedGradedCount, 0);
    });
    test('aggregates null / empty', () {
      expect(a.averageTatTotal, isNull);
      expect(a.medianTatTotal, isNull);
      expect(a.averageTatPercentage, isNull);
      expect(a.eligibilityDistribution, isEmpty);
      expect(a.totalScoreDistribution, isEmpty);
      expect(a.rankedScorers, isEmpty);
      expect(a.meetsRequirementRate, isNull);
    });
  });

  group('3. One graded examinee (50 / 30 / 10 -> total 90)', () {
    final a = _analyse([_graded(50, 30, 10, id: 'g90')]);
    test('counts', () {
      expect(a.totalExaminees, 1);
      expect(a.gradedExaminees, 1);
      expect(a.analyzableExaminees, 1);
      expect(a.ungradedExaminees, 0);
      expect(a.excludedGradedCount, 0);
    });
    test('total aggregates', () {
      expect(a.averageTatTotal, 90.0);
      expect(a.highestTatTotal, 90);
      expect(a.lowestTatTotal, 90);
      expect(a.medianTatTotal, 90.0);
      expect(a.averageTatPercentage, closeTo(90 * 100 / 160, 1e-9)); // 56.25
      expect(a.highestTatPercentage, closeTo(56.25, 1e-9));
      expect(a.lowestTatPercentage, closeTo(56.25, 1e-9));
      expect(a.medianTatPercentage, closeTo(56.25, 1e-9));
    });
    test('per-test summaries', () {
      expect(a.test1.scoreCount, 1);
      expect(a.test1.average, 50.0);
      expect(a.test1.highest, 50);
      expect(a.test1.lowest, 50);
      expect(a.test1.median, 50.0);
      expect(a.test1.averagePercentOfMax, closeTo(50 / 60 * 100, 1e-9));
      expect(a.test2.average, 30.0);
      expect(a.test2.averagePercentOfMax, closeTo(30 / 80 * 100, 1e-9));
      expect(a.test3.average, 10.0);
      expect(a.test3.averagePercentOfMax, closeTo(10 / 20 * 100, 1e-9));
    });
    test('eligibility distribution has both keys', () {
      expect(a.eligibilityDistribution.keys.toSet(),
          TatEligibility.values.toSet());
      expect(a.meetsRequirementCount, 1);
      expect(a.doesNotMeetRequirementCount, 0);
      expect(a.meetsRequirementRate, 100.0);
    });
    test('score distribution has all eight bands', () {
      expect(a.totalScoreDistribution.keys.toSet(),
          TatTotalBand.values.toSet());
      expect(a.totalScoreDistribution[TatTotalBand.band80to99], 1);
      expect(
        a.totalScoreDistribution.values.fold<int>(0, (x, y) => x + y),
        1,
      );
    });
    test('ranking', () {
      expect(a.rankedScorers, hasLength(1));
      final s = a.rankedScorers.single;
      expect(s.rank, 1);
      expect(s.scanId, 'g90');
      expect(s.tatTotal, 90);
      expect(s.percentage, closeTo(56.25, 1e-9));
      expect(s.eligibility, TatEligibility.meetsRequirement);
      expect(a.topScorers(), hasLength(1));
    });
  });

  group('4. Multiple graded examinees', () {
    final a = _analyse([
      _graded(20, 10, 4), // 34
      _graded(30, 20, 6), // 56
      _graded(40, 30, 8), // 78
      _graded(50, 40, 10), // 100
    ]);
    test('counts', () {
      expect(a.totalExaminees, 4);
      expect(a.gradedExaminees, 4);
      expect(a.analyzableExaminees, 4);
      expect(a.excludedGradedCount, 0);
    });
    test('total aggregates', () {
      expect(a.averageTatTotal, (34 + 56 + 78 + 100) / 4); // 67.0
      expect(a.highestTatTotal, 100);
      expect(a.lowestTatTotal, 34);
      expect(a.medianTatTotal, (56 + 78) / 2); // 67.0
    });
    test('per-test summaries', () {
      expect(a.test1.average, (20 + 30 + 40 + 50) / 4); // 35.0
      expect(a.test2.average, (10 + 20 + 30 + 40) / 4); // 25.0
      expect(a.test3.average, (4 + 6 + 8 + 10) / 4); // 7.0
      expect(a.test1.highest, 50);
      expect(a.test3.lowest, 4);
    });
  });

  group('5. Mixed graded / ungraded / legacy', () {
    final a = _analyse([
      _graded(30, 40, 10), // analyzable, total 80
      _graded(20, 20, 5), // analyzable, total 45
      _ungraded(),
      _legacyScan(),
    ]);
    test('counts partition the batch', () {
      expect(a.totalExaminees, 4);
      expect(a.gradedExaminees, 3); // two clean + legacy
      expect(a.analyzableExaminees, 2);
      expect(a.ungradedExaminees, 1);
      expect(a.excludedGradedCount, 1);
    });
    test('only analyzable records feed aggregates', () {
      expect(a.averageTatTotal, (80 + 45) / 2); // 62.5
      expect(a.highestTatTotal, 80);
      expect(a.lowestTatTotal, 45);
      expect(a.rankedScorers, hasLength(2));
    });
  });

  group('6. Average total', () {
    test('[40, 60, 80, 100] -> 70.0', () {
      final a = _analyse([
        _gradedForTotal(40),
        _gradedForTotal(60),
        _gradedForTotal(80),
        _gradedForTotal(100),
      ]);
      expect(a.averageTatTotal, 70.0);
    });
  });

  group('7. Highest total', () {
    test('[24, 130, 55] -> 130', () {
      final a = _analyse([
        _gradedForTotal(24),
        _gradedForTotal(130),
        _gradedForTotal(55),
      ]);
      expect(a.highestTatTotal, 130);
    });
  });

  group('8. Lowest total', () {
    test('[24, 130, 55] -> 24', () {
      final a = _analyse([
        _gradedForTotal(24),
        _gradedForTotal(130),
        _gradedForTotal(55),
      ]);
      expect(a.lowestTatTotal, 24);
    });
  });

  group('9. Median — odd count', () {
    test('[30, 100, 60] -> 60.0', () {
      final a = _analyse([
        _gradedForTotal(30),
        _gradedForTotal(100),
        _gradedForTotal(60),
      ]);
      expect(a.medianTatTotal, 60.0);
    });
  });

  group('10. Median — even count', () {
    test('[30, 60, 90, 120] -> (60 + 90) / 2 == 75.0', () {
      final a = _analyse([
        _gradedForTotal(30),
        _gradedForTotal(60),
        _gradedForTotal(90),
        _gradedForTotal(120),
      ]);
      expect(a.medianTatTotal, 75.0);
    });
  });

  group('11. Test 1 summary', () {
    test('scores [10, 30, 50] -> avg 30, high 50, low 10, median 30', () {
      final a = _analyse([
        _graded(10, 0, 0),
        _graded(30, 0, 0),
        _graded(50, 0, 0),
      ]);
      expect(a.test1.scoreCount, 3);
      expect(a.test1.average, 30.0);
      expect(a.test1.highest, 50);
      expect(a.test1.lowest, 10);
      expect(a.test1.median, 30.0);
      expect(a.test1.maxPossible, 60);
      expect(a.test1.averagePercentOfMax, closeTo(30 / 60 * 100, 1e-9));
    });
  });

  group('12. Test 2 summary', () {
    test('scores [16, 40, 64] -> avg 40, median 40, %ofMax 50', () {
      final a = _analyse([
        _graded(0, 16, 0),
        _graded(0, 40, 0),
        _graded(0, 64, 0),
      ]);
      expect(a.test2.average, 40.0);
      expect(a.test2.highest, 64);
      expect(a.test2.lowest, 16);
      expect(a.test2.median, 40.0);
      expect(a.test2.maxPossible, 80);
      expect(a.test2.averagePercentOfMax, closeTo(50.0, 1e-9));
    });
  });

  group('13. Test 3 summary', () {
    test('scores [4, 10, 16] -> avg 10, median 10, %ofMax 50', () {
      final a = _analyse([
        _graded(0, 0, 4),
        _graded(0, 0, 10),
        _graded(0, 0, 16),
      ]);
      expect(a.test3.average, 10.0);
      expect(a.test3.highest, 16);
      expect(a.test3.lowest, 4);
      expect(a.test3.median, 10.0);
      expect(a.test3.maxPossible, 20);
      expect(a.test3.averagePercentOfMax, closeTo(50.0, 1e-9));
    });
  });

  group('14. Official percentage', () {
    test('totals [48, 80] -> mean(30.0, 50.0) == 40.0', () {
      final a = _analyse([_gradedForTotal(48), _gradedForTotal(80)]);
      expect(a.averageTatPercentage, closeTo(40.0, 1e-9));
      expect(a.averageTatPercentage, tatPercentage(48)! / 2 + tatPercentage(80)! / 2);
    });
    test('per-scorer percentage comes from tatPercentage', () {
      final a = _analyse([_gradedForTotal(100)]);
      expect(a.rankedScorers.single.percentage, tatPercentage(100)); // 62.5
    });
  });

  group('15. Highest / lowest percentage', () {
    test('totals [16, 96, 160] -> low 10.0, high 100.0', () {
      final a = _analyse([
        _gradedForTotal(16),
        _gradedForTotal(96),
        _gradedForTotal(160),
      ]);
      expect(a.lowestTatPercentage, tatPercentage(16)); // 10.0
      expect(a.highestTatPercentage, tatPercentage(160)); // 100.0
    });
  });

  group('16. Median percentage', () {
    test('odd totals [48, 80, 160] -> median 50.0', () {
      final a = _analyse([
        _gradedForTotal(48),
        _gradedForTotal(80),
        _gradedForTotal(160),
      ]);
      expect(a.medianTatPercentage, tatPercentage(80)); // 50.0
    });
    test('even totals [0, 48, 80, 160] -> (30 + 50) / 2 == 40.0', () {
      final a = _analyse([
        _gradedForTotal(0),
        _gradedForTotal(48),
        _gradedForTotal(80),
        _gradedForTotal(160),
      ]);
      expect(a.medianTatPercentage, closeTo(40.0, 1e-9));
    });
  });

  group('17. Eligibility — total 47 does not meet', () {
    test('47 -> doesNotMeetRequirement', () {
      final a = _analyse([_gradedForTotal(47)]);
      expect(a.doesNotMeetRequirementCount, 1);
      expect(a.meetsRequirementCount, 0);
      expect(a.rankedScorers.single.eligibility,
          TatEligibility.doesNotMeetRequirement);
    });
  });

  group('18. Eligibility — total 48 meets', () {
    test('48 -> meetsRequirement', () {
      final a = _analyse([_gradedForTotal(48)]);
      expect(a.meetsRequirementCount, 1);
      expect(a.doesNotMeetRequirementCount, 0);
      expect(a.rankedScorers.single.eligibility,
          TatEligibility.meetsRequirement);
    });
  });

  group('19. Eligibility — total 0 does not meet', () {
    test('0 -> doesNotMeetRequirement', () {
      final a = _analyse([_gradedForTotal(0)]);
      expect(a.doesNotMeetRequirementCount, 1);
      expect(a.rankedScorers.single.eligibility,
          TatEligibility.doesNotMeetRequirement);
    });
  });

  group('20. Eligibility — total 160 meets', () {
    test('160 -> meetsRequirement', () {
      final a = _analyse([_gradedForTotal(160)]);
      expect(a.meetsRequirementCount, 1);
      expect(a.rankedScorers.single.eligibility,
          TatEligibility.meetsRequirement);
    });
  });

  group('21. Eligibility distribution', () {
    test('totals [0, 40, 47, 48, 100, 160] -> 3 / 3', () {
      final a = _analyse([
        for (final t in [0, 40, 47, 48, 100, 160]) _gradedForTotal(t),
      ]);
      expect(a.eligibilityDistribution, {
        TatEligibility.meetsRequirement: 3,
        TatEligibility.doesNotMeetRequirement: 3,
      });
    });
  });

  group('22. Meets requirement rate', () {
    test('3 of 6 -> 50.0', () {
      final a = _analyse([
        for (final t in [0, 40, 47, 48, 100, 160]) _gradedForTotal(t),
      ]);
      expect(a.meetsRequirementRate, 50.0);
    });
    test('null when no analyzable records', () {
      final a = _analyse([_ungraded(), _legacyScan()]);
      expect(a.meetsRequirementRate, isNull);
    });
  });

  group('23. Total distribution boundaries', () {
    test('one scan at each band edge -> 2 per band', () {
      final edges = [
        0, 19, 20, 39, 40, 59, 60, 79, 80, 99, 100, 119, 120, 139, 140, 160,
      ];
      final a = _analyse([for (final t in edges) _gradedForTotal(t)]);
      expect(a.analyzableExaminees, 16);
      expect(a.totalScoreDistribution, {
        TatTotalBand.band0to19: 2,
        TatTotalBand.band20to39: 2,
        TatTotalBand.band40to59: 2,
        TatTotalBand.band60to79: 2,
        TatTotalBand.band80to99: 2,
        TatTotalBand.band100to119: 2,
        TatTotalBand.band120to139: 2,
        TatTotalBand.band140to160: 2,
      });
    });

    test('TatTotalBand.forScore edges and out-of-range', () {
      expect(TatTotalBand.forScore(0), TatTotalBand.band0to19);
      expect(TatTotalBand.forScore(19), TatTotalBand.band0to19);
      expect(TatTotalBand.forScore(20), TatTotalBand.band20to39);
      expect(TatTotalBand.forScore(139), TatTotalBand.band120to139);
      expect(TatTotalBand.forScore(140), TatTotalBand.band140to160);
      expect(TatTotalBand.forScore(160), TatTotalBand.band140to160);
      expect(TatTotalBand.forScore(-1), isNull);
      expect(TatTotalBand.forScore(161), isNull);
    });
  });

  group('24. Per-test quartile boundaries', () {
    test('TatTestQuartile.forScore — Test 1 (max 60)', () {
      expect(TatTestQuartile.forScore(0, 60), TatTestQuartile.q0to24);
      expect(TatTestQuartile.forScore(14, 60), TatTestQuartile.q0to24); // 23%
      expect(TatTestQuartile.forScore(15, 60), TatTestQuartile.q25to49); // 25%
      expect(TatTestQuartile.forScore(29, 60), TatTestQuartile.q25to49); // 48%
      expect(TatTestQuartile.forScore(30, 60), TatTestQuartile.q50to74); // 50%
      expect(TatTestQuartile.forScore(44, 60), TatTestQuartile.q50to74); // 73%
      expect(TatTestQuartile.forScore(45, 60), TatTestQuartile.q75to100); // 75%
      expect(TatTestQuartile.forScore(60, 60), TatTestQuartile.q75to100); // 100%
    });
    test('TatTestQuartile.forScore — Test 3 (max 20)', () {
      expect(TatTestQuartile.forScore(4, 20), TatTestQuartile.q0to24); // 20%
      expect(TatTestQuartile.forScore(5, 20), TatTestQuartile.q25to49); // 25%
      expect(TatTestQuartile.forScore(9, 20), TatTestQuartile.q25to49); // 45%
      expect(TatTestQuartile.forScore(10, 20), TatTestQuartile.q50to74); // 50%
      expect(TatTestQuartile.forScore(14, 20), TatTestQuartile.q50to74); // 70%
      expect(TatTestQuartile.forScore(15, 20), TatTestQuartile.q75to100); // 75%
      expect(TatTestQuartile.forScore(20, 20), TatTestQuartile.q75to100); // 100%
    });
    test('TatTestQuartile.forScore — out of range', () {
      expect(TatTestQuartile.forScore(-1, 60), isNull);
      expect(TatTestQuartile.forScore(61, 60), isNull);
      expect(TatTestQuartile.forScore(10, 0), isNull);
    });
    test('per-test distribution maps carry all four keys', () {
      final a = _analyse([
        _graded(15, 20, 4), // T1 25%->q2, T2 25%->q2, T3 20%->q1
        _graded(45, 60, 15), // T1 75%->q4, T2 75%->q4, T3 75%->q4
      ]);
      for (final map in [
        a.test1Distribution,
        a.test2Distribution,
        a.test3Distribution,
      ]) {
        expect(map.keys.toSet(), TatTestQuartile.values.toSet());
        expect(map.values.fold<int>(0, (x, y) => x + y), 2);
      }
      expect(a.test1Distribution[TatTestQuartile.q25to49], 1);
      expect(a.test1Distribution[TatTestQuartile.q75to100], 1);
      expect(a.test3Distribution[TatTestQuartile.q0to24], 1);
      expect(a.test3Distribution[TatTestQuartile.q75to100], 1);
    });
  });

  group('25. Ranking', () {
    test('totals [120, 90, 60] -> ranks [1, 2, 3]', () {
      final a = _analyse([
        _gradedForTotal(120, id: 'a'),
        _gradedForTotal(90, id: 'b'),
        _gradedForTotal(60, id: 'c'),
      ]);
      expect(a.rankedScorers.map((s) => s.tatTotal).toList(), [120, 90, 60]);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 2, 3]);
      expect(a.rankedScorers.map((s) => s.scanId).toList(), ['a', 'b', 'c']);
    });
  });

  group('26. Dense ties', () {
    test('totals [120, 120, 90, 60] -> ranks [1, 1, 2, 3]', () {
      final a = _analyse([
        _gradedForTotal(120, id: 'a'),
        _gradedForTotal(120, id: 'b'),
        _gradedForTotal(90, id: 'c'),
        _gradedForTotal(60, id: 'd'),
      ]);
      expect(a.rankedScorers.map((s) => s.tatTotal).toList(),
          [120, 120, 90, 60]);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 1, 2, 3]);
    });
  });

  group('27. Top scorer cutoff with ties', () {
    final a = _analyse([
      _gradedForTotal(140, id: 'a'),
      _gradedForTotal(140, id: 'b'),
      _gradedForTotal(120, id: 'c'),
      _gradedForTotal(100, id: 'd'),
      _gradedForTotal(80, id: 'e'),
      _gradedForTotal(60, id: 'f'),
      _gradedForTotal(60, id: 'g'),
    ]);
    test('dense ranks are [1, 1, 2, 3, 4, 5, 5]', () {
      expect(a.rankedScorers.map((s) => s.rank).toList(),
          [1, 1, 2, 3, 4, 5, 5]);
    });
    test('limit 5 includes both rank-5 scorers', () {
      final top = a.topScorers(limit: 5);
      expect(top.map((s) => s.scanId).toList(),
          ['a', 'b', 'c', 'd', 'e', 'f', 'g']);
      expect(top.map((s) => s.rank).toList(), [1, 1, 2, 3, 4, 5, 5]);
    });
    test('limit 1 -> just the two 140s', () {
      expect(a.topScorers(limit: 1).map((s) => s.scanId).toList(), ['a', 'b']);
    });
    test('limit 0 and negative -> empty', () {
      expect(a.topScorers(limit: 0), isEmpty);
      expect(a.topScorers(limit: -3), isEmpty);
    });
    test('default limit 5 returns all seven here', () {
      expect(a.topScorers(), hasLength(7));
    });
  });

  group('28. Deterministic ordering (same total)', () {
    final complete3 = ExamineeInfo(
        firstName: 'C', lastName: 'C', examineeNumber: 'E-3');
    final complete1 = ExamineeInfo(
        firstName: 'A', lastName: 'A', examineeNumber: 'E-1');
    const blankTag = ExamineeInfo(firstName: '', lastName: '', examineeNumber: '');

    final a = _analyse([
      _graded(50, 40, 10, id: 'a', examinee: complete3), // total 100, E-3
      _graded(50, 40, 10, id: 'b', examinee: complete1), // total 100, E-1
      _graded(50, 40, 10, id: 'c', examinee: blankTag), // total 100, blank
      _graded(50, 40, 10, id: 'd'), // total 100, no examinee
    ]);
    test('number asc, blanks last, then scan id asc', () {
      expect(a.rankedScorers.map((s) => s.scanId).toList(),
          ['b', 'a', 'c', 'd']);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 1, 1, 1]);
    });
  });

  group('29. Missing examinee numbers', () {
    final nameOnly = ExamineeInfo(
        firstName: 'Ben', lastName: 'Diaz', examineeNumber: '  ');
    const blankTag = ExamineeInfo(firstName: '', lastName: '', examineeNumber: '');

    final a = _analyse([
      _graded(50, 40, 10, id: 'nameOnly', examinee: nameOnly),
      _graded(40, 30, 8, id: 'blankTag', examinee: blankTag),
      _graded(30, 20, 6, id: 'noTag'),
    ]);

    TatRankedScorer by(String id) =>
        a.rankedScorers.firstWhere((s) => s.scanId == id);

    test('whitespace-only number becomes null; name preserved', () {
      expect(by('nameOnly').examineeNumber, isNull);
      expect(by('nameOnly').displayName, 'Diaz, Ben');
    });
    test('blank tag: number null, displayName "Unnamed"', () {
      expect(by('blankTag').examineeNumber, isNull);
      expect(by('blankTag').displayName, 'Unnamed');
    });
    test('no examinee object: number null, name null', () {
      expect(by('noTag').examineeNumber, isNull);
      expect(by('noTag').displayName, isNull);
    });
    test('no crash; all three ranked', () {
      expect(a.rankedScorers, hasLength(3));
    });
  });

  group('30. Duplicate examinee numbers', () {
    final dupA = ExamineeInfo(
        firstName: 'A', lastName: 'A', examineeNumber: 'E-9');
    final dupB = ExamineeInfo(
        firstName: 'B', lastName: 'B', examineeNumber: 'E-9');
    final a = _analyse([
      _graded(50, 40, 10, id: 'hi', examinee: dupA), // total 100
      _graded(40, 30, 8, id: 'lo', examinee: dupB), // total 78
    ]);
    test('both kept, no merge, ranked by total desc', () {
      expect(a.analyzableExaminees, 2);
      expect(a.rankedScorers.map((s) => s.scanId).toList(), ['hi', 'lo']);
      expect(a.rankedScorers.map((s) => s.examineeNumber).toList(),
          ['E-9', 'E-9']);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 2]);
    });
  });

  group('31. Legacy scan exclusion', () {
    final a = _analyse([_graded(30, 40, 10), _legacyScan()]);
    test('legacy record excluded from score analytics but counted', () {
      expect(a.totalExaminees, 2);
      expect(a.gradedExaminees, 2);
      expect(a.analyzableExaminees, 1);
      expect(a.excludedGradedCount, 1);
      expect(a.averageTatTotal, 80.0); // only the analyzable one
      expect(a.rankedScorers, hasLength(1));
    });
  });

  group('32. Malformed / out-of-range exclusion', () {
    test('t1 > 60, total > 160, t2 < 0 are each excluded', () {
      final a = _analyse([
        _graded(30, 40, 10), // valid, total 80
        _scan(result: _result(t1Score: 65, t2Score: 10, t3Score: 5, total: 80)),
        _scan(result: _result(t1Score: 60, t2Score: 80, t3Score: 20, total: 200)),
        _scan(result: _result(t1Score: 30, t2Score: -3, t3Score: 5, total: 32)),
      ]);
      expect(a.totalExaminees, 4);
      expect(a.gradedExaminees, 4);
      expect(a.analyzableExaminees, 1);
      expect(a.excludedGradedCount, 3);
      expect(a.averageTatTotal, 80.0);
      expect(a.highestTatTotal, 80);
    });
    test('tatTotal == test1 + test2 + test3 mismatch is NOT rejected', () {
      // Sub-scores sum to 90 but the persisted total is 70 — consumed as-is.
      final a = _analyse([
        _scan(result: _result(t1Score: 40, t2Score: 40, t3Score: 10, total: 70)),
      ]);
      expect(a.analyzableExaminees, 1);
      expect(a.excludedGradedCount, 0);
      expect(a.highestTatTotal, 70);
      expect(a.test1.highest, 40);
    });
  });

  group('33. Null per-test score exclusion', () {
    test('breakdown present (tatTotal set) but a sub-score null -> excluded', () {
      final a = _analyse([
        _graded(30, 40, 10), // valid
        _scan(result: _result(t1Score: 30, t2Score: null, t3Score: 10, total: 40)),
      ]);
      expect(a.gradedExaminees, 2);
      expect(a.analyzableExaminees, 1);
      expect(a.excludedGradedCount, 1);
    });
  });

  group('34. All-zero batch', () {
    final a = _analyse([
      _graded(0, 0, 0),
      _graded(0, 0, 0),
      _graded(0, 0, 0),
    ]);
    test('aggregates are zero, not null', () {
      expect(a.analyzableExaminees, 3);
      expect(a.averageTatTotal, 0.0);
      expect(a.medianTatTotal, 0.0);
      expect(a.highestTatTotal, 0);
      expect(a.lowestTatTotal, 0);
      expect(a.averageTatPercentage, 0.0);
    });
    test('all does-not-meet; lowest bands only', () {
      expect(a.eligibilityDistribution, {
        TatEligibility.meetsRequirement: 0,
        TatEligibility.doesNotMeetRequirement: 3,
      });
      expect(a.meetsRequirementRate, 0.0);
      expect(a.totalScoreDistribution[TatTotalBand.band0to19], 3);
      expect(a.test1Distribution[TatTestQuartile.q0to24], 3);
      expect(a.test2Distribution[TatTestQuartile.q0to24], 3);
      expect(a.test3Distribution[TatTestQuartile.q0to24], 3);
    });
  });

  group('35. Maximum-score batch', () {
    final a = _analyse([_graded(60, 80, 20), _graded(60, 80, 20)]);
    test('all meet; top bands only', () {
      expect(a.averageTatTotal, 160.0);
      expect(a.averageTatPercentage, 100.0);
      expect(a.eligibilityDistribution, {
        TatEligibility.meetsRequirement: 2,
        TatEligibility.doesNotMeetRequirement: 0,
      });
      expect(a.meetsRequirementRate, 100.0);
      expect(a.totalScoreDistribution[TatTotalBand.band140to160], 2);
      expect(a.test1Distribution[TatTestQuartile.q75to100], 2);
      expect(a.test2Distribution[TatTestQuartile.q75to100], 2);
      expect(a.test3Distribution[TatTestQuartile.q75to100], 2);
    });
  });

  group('36. Legacy percentage regression', () {
    test('legacy percentage 999.9 never leaks into averageTatPercentage', () {
      final a = _analyse([
        _graded(30, 40, 10, legacyPercentage: 999.9), // total 80
      ]);
      expect(a.averageTatTotal, 80.0);
      expect(a.averageTatPercentage, tatPercentage(80)); // 50.0
      expect(a.averageTatPercentage, closeTo(50.0, 1e-9));
      expect(a.averageTatPercentage, isNot(closeTo(999.9, 1.0)));
      expect(a.rankedScorers.single.percentage, tatPercentage(80));
      expect(a.rankedScorers.single.percentage, isNot(closeTo(999.9, 1.0)));
    });
  });

  group('37. Non-TAT fromBatch rejection', () {
    test('QTM / AT batches throw ArgumentError', () {
      expect(
        () => TatBatchAnalytics.fromBatch(_batch('QTM', const [])),
        throwsArgumentError,
      );
      expect(
        () => TatBatchAnalytics.fromBatch(_batch('AT', [_graded(30, 40, 10)])),
        throwsArgumentError,
      );
    });
  });

  group('38. fromBatch vs fromScans consistency', () {
    test('same numbers via either entry point', () {
      final scans = [
        _graded(50, 40, 10),
        _graded(20, 20, 5),
        _ungraded(),
        _legacyScan(),
      ];
      final viaBatch = TatBatchAnalytics.fromBatch(_batch('TAT', scans));
      final viaScans = TatBatchAnalytics.fromScans(scans);
      expect(viaBatch.totalExaminees, viaScans.totalExaminees);
      expect(viaBatch.gradedExaminees, viaScans.gradedExaminees);
      expect(viaBatch.analyzableExaminees, viaScans.analyzableExaminees);
      expect(viaBatch.excludedGradedCount, viaScans.excludedGradedCount);
      expect(viaBatch.averageTatTotal, viaScans.averageTatTotal);
      expect(viaBatch.medianTatTotal, viaScans.medianTatTotal);
      expect(viaBatch.averageTatPercentage, viaScans.averageTatPercentage);
      expect(viaBatch.eligibilityDistribution, viaScans.eligibilityDistribution);
      expect(viaBatch.totalScoreDistribution, viaScans.totalScoreDistribution);
      expect(viaBatch.rankedScorers.map((s) => s.scanId).toList(),
          viaScans.rankedScorers.map((s) => s.scanId).toList());
    });
  });

  group('39. Immutable maps / lists', () {
    final a = _analyse([_graded(50, 40, 10), _graded(20, 20, 5)]);
    test('exposed collections cannot be mutated', () {
      expect(a.rankedScorers.clear, throwsUnsupportedError);
      expect(a.topScorers().clear, throwsUnsupportedError);
      expect(
        () => a.eligibilityDistribution[TatEligibility.meetsRequirement] = 9,
        throwsUnsupportedError,
      );
      expect(
        () => a.totalScoreDistribution[TatTotalBand.band0to19] = 9,
        throwsUnsupportedError,
      );
      expect(
        () => a.test1Distribution[TatTestQuartile.q0to24] = 9,
        throwsUnsupportedError,
      );
      expect(
        () => a.test2Distribution[TatTestQuartile.q0to24] = 9,
        throwsUnsupportedError,
      );
      expect(
        () => a.test3Distribution[TatTestQuartile.q0to24] = 9,
        throwsUnsupportedError,
      );
    });
  });

  group('40. Strongest / weakest test', () {
    test('compares averagePercentOfMax, not raw average', () {
      // T1 avg 12/60 = 20%, T2 avg 48/80 = 60%, T3 avg 4/20 = 20%.
      final a = _analyse([
        _graded(6, 40, 2),
        _graded(12, 48, 4),
        _graded(18, 56, 6),
      ]);
      expect(a.test1.average, 12.0);
      expect(a.test2.average, 48.0);
      expect(a.strongestTestByPercent, TatTestKey.test2); // 60%
      // T1 and T3 tie at 20% -> lowest ordinal wins.
      expect(a.weakestTestByPercent, TatTestKey.test1);
    });
  });

  group('41. Strongest / weakest tie behavior', () {
    test('all three equal percent -> both resolve to test1', () {
      // T1 30/60 = 50%, T2 40/80 = 50%, T3 10/20 = 50%.
      final a = _analyse([_graded(30, 40, 10), _graded(30, 40, 10)]);
      expect(a.test1.averagePercentOfMax, 50.0);
      expect(a.test2.averagePercentOfMax, 50.0);
      expect(a.test3.averagePercentOfMax, 50.0);
      expect(a.strongestTestByPercent, TatTestKey.test1);
      expect(a.weakestTestByPercent, TatTestKey.test1);
    });
  });

  group('42. Empty strongest / weakest', () {
    test('null when nothing is analyzable', () {
      expect(_analyse(const []).strongestTestByPercent, isNull);
      expect(_analyse(const []).weakestTestByPercent, isNull);
      final ungradedOnly = _analyse([_ungraded(), _legacyScan()]);
      expect(ungradedOnly.strongestTestByPercent, isNull);
      expect(ungradedOnly.weakestTestByPercent, isNull);
    });
  });

  group('TatTestKey enum', () {
    test('has exactly the three sub-tests in order', () {
      expect(TatTestKey.values, const [
        TatTestKey.test1,
        TatTestKey.test2,
        TatTestKey.test3,
      ]);
    });
  });
}
