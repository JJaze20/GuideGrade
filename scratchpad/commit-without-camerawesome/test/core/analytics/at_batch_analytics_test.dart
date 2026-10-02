import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/analytics/at_batch_analytics.dart';
import 'package:guidegrade/core/omr/admission_category.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

final _at = DateTime.utc(2026, 1, 1);
var _seq = 0;

/// A graded Admission Test result. [totalGraded] / [totalItems] both
/// default to 72 (full-key coverage). [legacyPercentage] is the generic
/// `LocalScanResult.percentage` field — analytics must never read it.
LocalScanResult _atResult(
  int rawScore, {
  int totalGraded = 72,
  int totalItems = 72,
  String status = 'Graded',
  double legacyPercentage = 0,
}) =>
    LocalScanResult(
      rawScore: rawScore,
      totalGraded: totalGraded,
      totalItems: totalItems,
      percentage: legacyPercentage,
      status: status,
      scannedAt: _at,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScanResult _ungradedResult() =>
    _atResult(0, totalGraded: 0, status: 'Ungraded');

LocalScan _scan({
  String? id,
  LocalScanResult? result,
  ExamineeInfo? examinee,
}) =>
    LocalScan(
      id: id ?? 's${_seq++}',
      imageFileName: 'x.jpg',
      capturedAt: _at,
      decoded: const OmrScanResult(examCode: 'AT', items: []),
      result: result,
      examinee: examinee,
    );

/// Full-key graded scan (analyzable).
LocalScan _graded(
  int rawScore, {
  String? id,
  ExamineeInfo? examinee,
  double legacyPercentage = 0,
}) =>
    _scan(
      id: id,
      result: _atResult(rawScore, legacyPercentage: legacyPercentage),
      examinee: examinee,
    );

/// Graded, but the answer key covered only part of the sheet — counted as
/// graded, excluded from analytics.
LocalScan _partial(int rawScore, {String? id, int totalGraded = 50}) =>
    _scan(id: id, result: _atResult(rawScore, totalGraded: totalGraded));

LocalScan _ungraded({String? id}) => _scan(id: id, result: _ungradedResult());

/// A scan whose result is null (never graded at all).
LocalScan _noResult({String? id}) => _scan(id: id);

LocalBatch _batch(String examCode, List<LocalScan> scans) => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: examCode,
      examTitle: 'Admission Test',
      description: '',
      expectedCount: 0,
      status: 'Completed',
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: _at,
      updatedAt: _at,
      scans: scans,
    );

AtBatchAnalytics _analyse(List<LocalScan> scans) =>
    AtBatchAnalytics.fromScans(scans);

double _pctOf(num raw) => raw / 72 * 100;

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
    test('all score metrics are null', () {
      expect(a.averageRawScore, isNull);
      expect(a.highestRawScore, isNull);
      expect(a.lowestRawScore, isNull);
      expect(a.medianRawScore, isNull);
      expect(a.averagePercentage, isNull);
      expect(a.highestPercentage, isNull);
      expect(a.lowestPercentage, isNull);
      expect(a.medianPercentage, isNull);
    });
    test('distributions / scorers / rates are empty / null', () {
      expect(a.categoryDistribution, isEmpty);
      expect(a.scoreDistribution, isEmpty);
      expect(a.unclassifiedCount, 0);
      expect(a.rankedScorers, isEmpty);
      expect(a.topScorers(), isEmpty);
      expect(a.categoryRate(AdmissionCategory.a), isNull);
      expect(a.unclassifiedRate, isNull);
    });
  });

  group('2. All ungraded', () {
    final a = _analyse([_ungraded(), _ungraded(), _noResult()]);
    test('totals split correctly', () {
      expect(a.totalExaminees, 3);
      expect(a.gradedExaminees, 0);
      expect(a.ungradedExaminees, 3);
      expect(a.analyzableExaminees, 0);
      expect(a.excludedGradedCount, 0);
    });
    test('metrics null / empty', () {
      expect(a.averageRawScore, isNull);
      expect(a.medianRawScore, isNull);
      expect(a.averagePercentage, isNull);
      expect(a.categoryDistribution, isEmpty);
      expect(a.scoreDistribution, isEmpty);
      expect(a.rankedScorers, isEmpty);
    });
  });

  group('3. All partial-key / excluded', () {
    final a = _analyse([_partial(40), _partial(52), _partial(60)]);
    test('graded but none analyzable', () {
      expect(a.totalExaminees, 3);
      expect(a.gradedExaminees, 3);
      expect(a.ungradedExaminees, 0);
      expect(a.analyzableExaminees, 0);
      expect(a.excludedGradedCount, 3);
    });
    test('no statistics are produced', () {
      expect(a.averageRawScore, isNull);
      expect(a.averagePercentage, isNull);
      expect(a.categoryDistribution, isEmpty);
      expect(a.scoreDistribution, isEmpty);
      expect(a.rankedScorers, isEmpty);
      expect(a.categoryRate(AdmissionCategory.a), isNull);
      expect(a.unclassifiedRate, isNull);
    });
  });

  group('4. One analyzable scan (raw 50 -> A)', () {
    final a = _analyse([_graded(50, id: 'g50')]);
    test('counts', () {
      expect(a.totalExaminees, 1);
      expect(a.gradedExaminees, 1);
      expect(a.analyzableExaminees, 1);
      expect(a.ungradedExaminees, 0);
      expect(a.excludedGradedCount, 0);
    });
    test('score metrics', () {
      expect(a.averageRawScore, 50.0);
      expect(a.highestRawScore, 50);
      expect(a.lowestRawScore, 50);
      expect(a.medianRawScore, 50.0);
      expect(a.averagePercentage, closeTo(_pctOf(50), 1e-9)); // 69.44
      expect(a.highestPercentage, closeTo(_pctOf(50), 1e-9));
      expect(a.lowestPercentage, closeTo(_pctOf(50), 1e-9));
      expect(a.medianPercentage, closeTo(_pctOf(50), 1e-9));
    });
    test('category analytics', () {
      expect(a.categoryDistribution.keys.toSet(),
          AdmissionCategory.values.toSet());
      expect(a.categoryCount(AdmissionCategory.a), 1);
      expect(a.categoryCount(AdmissionCategory.b), 0);
      expect(a.categoryCount(AdmissionCategory.c), 0);
      expect(a.categoryCount(AdmissionCategory.d), 0);
      expect(a.unclassifiedCount, 0);
      expect(a.categoryRate(AdmissionCategory.a), 100.0);
      expect(a.unclassifiedRate, 0.0);
    });
    test('score distribution', () {
      expect(a.scoreDistribution.keys.toSet(), AtScoreBand.values.toSet());
      expect(a.scoreDistribution[AtScoreBand.a], 1);
      expect(a.scoreDistribution.values.fold<int>(0, (x, y) => x + y), 1);
    });
    test('ranking', () {
      expect(a.rankedScorers, hasLength(1));
      final s = a.rankedScorers.single;
      expect(s.rank, 1);
      expect(s.scanId, 'g50');
      expect(s.rawScore, 50);
      expect(s.percentage, closeTo(_pctOf(50), 1e-9));
      expect(s.category, AdmissionCategory.a);
      expect(a.topScorers(), hasLength(1));
    });
  });

  group('5. Mixed analyzable / ungraded / excluded', () {
    final a = _analyse([
      _graded(60, id: 'a'),
      _graded(40, id: 'b'),
      _ungraded(id: 'c'),
      _partial(70, id: 'd'),
      _noResult(id: 'e'),
    ]);
    test('counts partition the batch', () {
      expect(a.totalExaminees, 5);
      expect(a.gradedExaminees, 3); // two full + one partial (status Graded)
      expect(a.ungradedExaminees, 2); // ungraded + noResult
      expect(a.analyzableExaminees, 2);
      expect(a.excludedGradedCount, 1);
    });
    test('only analyzable scans feed the statistics', () {
      expect(a.averageRawScore, 50.0); // mean(40, 60)
      expect(a.highestRawScore, 60);
      expect(a.lowestRawScore, 40);
      expect(a.medianRawScore, 50.0);
      expect(a.rankedScorers, hasLength(2));
      expect(a.rankedScorers.map((s) => s.rawScore).toList(), [60, 40]);
    });
  });

  group('6. Average raw score', () {
    test('[30, 40, 50, 60] -> 45.0', () {
      final a =
          _analyse([_graded(30), _graded(40), _graded(50), _graded(60)]);
      expect(a.averageRawScore, 45.0);
    });
  });

  group('7. Highest raw score', () {
    test('[12, 65, 33] -> 65', () {
      final a = _analyse([_graded(12), _graded(65), _graded(33)]);
      expect(a.highestRawScore, 65);
    });
  });

  group('8. Lowest raw score', () {
    test('[12, 65, 33] -> 12', () {
      final a = _analyse([_graded(12), _graded(65), _graded(33)]);
      expect(a.lowestRawScore, 12);
    });
  });

  group('9. Median — odd count', () {
    test('[20, 60, 40] -> 40.0', () {
      final a = _analyse([_graded(20), _graded(60), _graded(40)]);
      expect(a.medianRawScore, 40.0);
    });
  });

  group('10. Median — even count', () {
    test('[20, 40, 50, 70] -> (40 + 50) / 2 == 45.0', () {
      final a =
          _analyse([_graded(20), _graded(40), _graded(50), _graded(70)]);
      expect(a.medianRawScore, 45.0);
    });
  });

  group('11. Official percentage calculation (rawScore / 72 * 100)', () {
    test('[36, 72] -> percentages 50.0 / 100.0, average 75.0', () {
      final a = _analyse([_graded(36), _graded(72)]);
      expect(a.averageRawScore, 54.0);
      expect(a.averagePercentage, 75.0);
      expect(a.averagePercentage, a.averageRawScore! / 72 * 100);
      expect(a.highestPercentage, 100.0);
      expect(a.lowestPercentage, 50.0);
      expect(a.medianPercentage, 75.0);
    });
    test('per-scorer percentage is rawScore / 72 * 100', () {
      final a = _analyse([_graded(45)]); // 45 / 72 = 0.625 -> 62.5
      expect(a.rankedScorers.single.percentage, 62.5);
    });
  });

  group('12. Every category boundary', () {
    const cases = <int, AdmissionCategory?>{
      0: AdmissionCategory.a,
      54: AdmissionCategory.a,
      55: null,
      56: null,
      57: null,
      58: AdmissionCategory.b,
      60: AdmissionCategory.b,
      61: AdmissionCategory.c,
      64: AdmissionCategory.c,
      65: AdmissionCategory.d,
      72: AdmissionCategory.d,
    };
    cases.forEach((raw, expectedCategory) {
      test('raw $raw -> ${expectedCategory ?? 'Unclassified'}', () {
        final a = _analyse([_graded(raw)]);
        final scorer = a.rankedScorers.single;
        expect(scorer.category, expectedCategory);
        expect(scorer.percentage, closeTo(_pctOf(raw), 1e-9));
        if (expectedCategory == null) {
          expect(a.unclassifiedCount, 1);
          expect(a.categoryDistribution.values.fold<int>(0, (x, y) => x + y), 0);
          expect(a.scoreDistribution[AtScoreBand.unclassified], 1);
        } else {
          expect(a.unclassifiedCount, 0);
          expect(a.categoryCount(expectedCategory), 1);
        }
      });
    });
  });

  group('13. A / B / C / D counts', () {
    test('known mix', () {
      final a = _analyse([
        for (final raw in [10, 20, 54, 55, 56, 58, 60, 62, 64, 66, 72])
          _graded(raw),
      ]);
      expect(a.analyzableExaminees, 11);
      expect(a.categoryDistribution, {
        AdmissionCategory.a: 3, // 10, 20, 54
        AdmissionCategory.b: 2, // 58, 60
        AdmissionCategory.c: 2, // 62, 64
        AdmissionCategory.d: 2, // 66, 72
      });
      expect(a.unclassifiedCount, 2); // 55, 56
    });
  });

  group('14. 55–57 Unclassified count stays separate from A / B', () {
    test('[55, 56, 57, 40, 70]', () {
      final a = _analyse([
        _graded(55),
        _graded(56),
        _graded(57),
        _graded(40),
        _graded(70),
      ]);
      expect(a.unclassifiedCount, 3);
      expect(a.categoryCount(AdmissionCategory.a), 1); // 40
      expect(a.categoryCount(AdmissionCategory.b), 0);
      expect(a.categoryCount(AdmissionCategory.d), 1); // 70
      expect(a.scoreDistribution[AtScoreBand.unclassified], 3);
      expect(a.scoreDistribution[AtScoreBand.a], 1);
      expect(a.scoreDistribution[AtScoreBand.b], 0);
    });
  });

  group('15. Category rates', () {
    test('rates over analyzable population', () {
      final a = _analyse([
        for (final raw in [10, 20, 54, 55, 56, 58, 60, 62, 64, 66, 72])
          _graded(raw),
      ]);
      expect(a.categoryRate(AdmissionCategory.a), closeTo(3 / 11 * 100, 1e-9));
      expect(a.categoryRate(AdmissionCategory.b), closeTo(2 / 11 * 100, 1e-9));
      expect(a.unclassifiedRate, closeTo(2 / 11 * 100, 1e-9));
    });
    test('null when no analyzable scans', () {
      final a = _analyse([_ungraded(), _partial(50)]);
      expect(a.categoryRate(AdmissionCategory.d), isNull);
      expect(a.unclassifiedRate, isNull);
    });
  });

  group('16. Score distribution — category-aligned bands', () {
    test('one scan at each band edge -> 2 per band', () {
      final edges = [0, 54, 55, 57, 58, 60, 61, 64, 65, 72];
      final a = _analyse([for (final raw in edges) _graded(raw)]);
      expect(a.analyzableExaminees, 10);
      expect(a.scoreDistribution, {
        AtScoreBand.a: 2,
        AtScoreBand.unclassified: 2,
        AtScoreBand.b: 2,
        AtScoreBand.c: 2,
        AtScoreBand.d: 2,
      });
    });
    test('AtScoreBand.forRawScore edges and out-of-range', () {
      expect(AtScoreBand.forRawScore(0), AtScoreBand.a);
      expect(AtScoreBand.forRawScore(54), AtScoreBand.a);
      expect(AtScoreBand.forRawScore(55), AtScoreBand.unclassified);
      expect(AtScoreBand.forRawScore(57), AtScoreBand.unclassified);
      expect(AtScoreBand.forRawScore(58), AtScoreBand.b);
      expect(AtScoreBand.forRawScore(60), AtScoreBand.b);
      expect(AtScoreBand.forRawScore(61), AtScoreBand.c);
      expect(AtScoreBand.forRawScore(64), AtScoreBand.c);
      expect(AtScoreBand.forRawScore(65), AtScoreBand.d);
      expect(AtScoreBand.forRawScore(72), AtScoreBand.d);
      expect(AtScoreBand.forRawScore(-1), isNull);
      expect(AtScoreBand.forRawScore(73), isNull);
    });
    test('AtScoreBand metadata', () {
      expect(AtScoreBand.values, const [
        AtScoreBand.a,
        AtScoreBand.unclassified,
        AtScoreBand.b,
        AtScoreBand.c,
        AtScoreBand.d,
      ]);
      expect(AtScoreBand.a.label, '0–54');
      expect(AtScoreBand.unclassified.label, '55–57');
      expect(AtScoreBand.d.label, '65–72');
      expect(AtScoreBand.unclassified.categoryName, 'Unclassified');
      expect(AtScoreBand.c.categoryName, 'C');
    });
  });

  group('17. All-zero batch', () {
    final a = _analyse([_graded(0), _graded(0), _graded(0)]);
    test('aggregates are zero, not null', () {
      expect(a.analyzableExaminees, 3);
      expect(a.averageRawScore, 0.0);
      expect(a.medianRawScore, 0.0);
      expect(a.highestRawScore, 0);
      expect(a.lowestRawScore, 0);
      expect(a.averagePercentage, 0.0);
      expect(a.highestPercentage, 0.0);
      expect(a.lowestPercentage, 0.0);
      expect(a.medianPercentage, 0.0);
    });
    test('all category A; A band only', () {
      expect(a.categoryDistribution, {
        AdmissionCategory.a: 3,
        AdmissionCategory.b: 0,
        AdmissionCategory.c: 0,
        AdmissionCategory.d: 0,
      });
      expect(a.unclassifiedCount, 0);
      expect(a.categoryRate(AdmissionCategory.a), 100.0);
      expect(a.scoreDistribution[AtScoreBand.a], 3);
      expect(a.rankedScorers.map((s) => s.rank), everyElement(1));
    });
  });

  group('18. All-72 batch', () {
    final a = _analyse([_graded(72), _graded(72)]);
    test('perfect scores', () {
      expect(a.averageRawScore, 72.0);
      expect(a.medianRawScore, 72.0);
      expect(a.averagePercentage, 100.0);
      expect(a.categoryDistribution, {
        AdmissionCategory.a: 0,
        AdmissionCategory.b: 0,
        AdmissionCategory.c: 0,
        AdmissionCategory.d: 2,
      });
      expect(a.categoryRate(AdmissionCategory.d), 100.0);
      expect(a.scoreDistribution[AtScoreBand.d], 2);
      expect(a.rankedScorers.map((s) => s.rank), everyElement(1));
    });
  });

  group('19. Ranking', () {
    test('[30, 60, 45] -> ranks [1, 2, 3], highest first', () {
      final a = _analyse([
        _graded(30, id: 'a'),
        _graded(60, id: 'b'),
        _graded(45, id: 'c'),
      ]);
      expect(a.rankedScorers.map((s) => s.rawScore).toList(), [60, 45, 30]);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 2, 3]);
      expect(a.rankedScorers.map((s) => s.scanId).toList(), ['b', 'c', 'a']);
    });
  });

  group('20. Dense ties', () {
    test('[60, 60, 58, 50] -> ranks [1, 1, 2, 3]', () {
      final a = _analyse(
          [_graded(60), _graded(60), _graded(58), _graded(50)]);
      expect(a.rankedScorers.map((s) => s.rawScore).toList(), [60, 60, 58, 50]);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 1, 2, 3]);
    });
  });

  group('21. topScorers cutoff with ties', () {
    final a = _analyse([
      _graded(72, id: 'a'),
      _graded(65, id: 'b'),
      _graded(65, id: 'c'),
      _graded(60, id: 'd'),
    ]);
    test('dense ranks [1, 2, 2, 3]', () {
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 2, 2, 3]);
    });
    test('limit 2 includes both rank-2 scorers', () {
      final top = a.topScorers(limit: 2);
      expect(top.map((s) => s.scanId).toList(), ['a', 'b', 'c']);
      expect(top.map((s) => s.rank).toList(), [1, 2, 2]);
    });
    test('limit 1 -> just the 72', () {
      expect(a.topScorers(limit: 1).map((s) => s.scanId).toList(), ['a']);
    });
    test('limit 0 and negative -> empty', () {
      expect(a.topScorers(limit: 0), isEmpty);
      expect(a.topScorers(limit: -3), isEmpty);
    });
    test('default limit 5 returns all four here', () {
      expect(a.topScorers(), hasLength(4));
    });
  });

  group('22. Deterministic ordering (same score)', () {
    final e3 = ExamineeInfo(
        firstName: 'X', lastName: 'X', examineeNumber: 'E-3');
    final e1 = ExamineeInfo(
        firstName: 'X', lastName: 'X', examineeNumber: 'E-1');
    const blank =
        ExamineeInfo(firstName: '', lastName: '', examineeNumber: '');

    final a = _analyse([
      _graded(60, id: 'a', examinee: e3),
      _graded(60, id: 'b', examinee: e1),
      _graded(60, id: 'c', examinee: blank),
      _graded(60, id: 'd'),
    ]);
    test('number asc, blanks last, then scan id asc', () {
      expect(a.rankedScorers.map((s) => s.scanId).toList(),
          ['b', 'a', 'c', 'd']);
      expect(a.rankedScorers.map((s) => s.rank).toList(), [1, 1, 1, 1]);
    });
  });

  group('23. Missing examinee identity does not crash', () {
    final nameOnly = ExamineeInfo(
        firstName: 'Ann', lastName: 'Cruz', examineeNumber: '  ');
    const blank =
        ExamineeInfo(firstName: '', lastName: '', examineeNumber: '');

    final a = _analyse([
      _graded(50, id: 'noTag'),
      _graded(40, id: 'nameOnly', examinee: nameOnly),
      _graded(30, id: 'blankTag', examinee: blank),
    ]);

    AtRankedScorer by(String id) =>
        a.rankedScorers.firstWhere((s) => s.scanId == id);

    test('all three ranked, no exception', () {
      expect(a.rankedScorers, hasLength(3));
      expect(a.analyzableExaminees, 3);
    });
    test('no examinee object: number null, name null', () {
      expect(by('noTag').examineeNumber, isNull);
      expect(by('noTag').displayName, isNull);
    });
    test('whitespace-only number -> null; name preserved', () {
      expect(by('nameOnly').examineeNumber, isNull);
      expect(by('nameOnly').displayName, 'Cruz, Ann');
    });
    test('blank tag: number null, displayName "Unnamed"', () {
      expect(by('blankTag').examineeNumber, isNull);
      expect(by('blankTag').displayName, 'Unnamed');
    });
  });

  group('24. Wrong stored percentage regression', () {
    test('legacy percentage 999.9 never reaches analytics', () {
      final a = _analyse([
        _graded(54, legacyPercentage: 999.9),
        _graded(18, legacyPercentage: 999.9),
      ]);
      expect(a.averageRawScore, 36.0);
      expect(a.averagePercentage, 50.0); // 36 / 72 * 100
      expect(a.averagePercentage, isNot(closeTo(999.9, 1.0)));
      expect(a.highestPercentage, 75.0); // 54 / 72 * 100
      expect(a.lowestPercentage, 25.0); // 18 / 72 * 100
      expect(a.medianPercentage, 50.0);
      final top = a.rankedScorers.first;
      expect(top.rawScore, 54);
      expect(top.percentage, 75.0);
      expect(top.percentage, isNot(closeTo(999.9, 1.0)));
    });
  });

  group('25. fromBatch rejects a QTM batch', () {
    test('throws ArgumentError', () {
      expect(
        () => AtBatchAnalytics.fromBatch(_batch('QTM', const [])),
        throwsArgumentError,
      );
    });
  });

  group('26. fromBatch rejects a TAT batch; accepts an AT batch', () {
    test('TAT throws ArgumentError', () {
      expect(
        () => AtBatchAnalytics.fromBatch(_batch('TAT', [_graded(40)])),
        throwsArgumentError,
      );
    });
    test('AT batch delegates to the scan analysis', () {
      final a = AtBatchAnalytics.fromBatch(
        _batch('AT', [_graded(50), _ungraded(), _partial(60)]),
      );
      expect(a.totalExaminees, 3);
      expect(a.gradedExaminees, 2);
      expect(a.analyzableExaminees, 1);
      expect(a.excludedGradedCount, 1);
      expect(a.averageRawScore, 50.0);
    });
  });

  group('27. Immutability of exposed collections', () {
    final a = _analyse([_graded(50), _graded(62)]);
    test('maps and lists are unmodifiable', () {
      expect(a.rankedScorers.clear, throwsUnsupportedError);
      expect(a.topScorers().clear, throwsUnsupportedError);
      expect(() => a.categoryDistribution[AdmissionCategory.a] = 9,
          throwsUnsupportedError);
      expect(() => a.scoreDistribution[AtScoreBand.a] = 9,
          throwsUnsupportedError);
    });
  });

  group('28. Excluded when sheet itemization is not 72', () {
    test('graded result with totalItems != 72 is not analyzable', () {
      final a = _analyse([
        _graded(50, id: 'ok'),
        _scan(
          id: 'weird',
          result: _atResult(50, totalGraded: 72, totalItems: 60),
        ),
      ]);
      expect(a.gradedExaminees, 2);
      expect(a.analyzableExaminees, 1);
      expect(a.excludedGradedCount, 1);
      expect(a.rankedScorers.map((s) => s.scanId).toList(), ['ok']);
    });
  });
}
