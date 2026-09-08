import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/archive/screens/tat_batch_analytics_screen.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// Returns whatever batch it was seeded with for a given id; every other
/// [BatchRepository] method is unused by this screen.
class _FakeBatchRepository implements BatchRepository {
  _FakeBatchRepository([this._byId = const {}]);
  final Map<String, LocalBatch> _byId;

  @override
  Future<LocalBatch?> getBatchById(String id) async => _byId[id];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _at = DateTime.utc(2026, 1, 1);
var _seq = 0;

/// A graded TAT result. Any sub-score / total may be left null to model
/// incomplete data; [breakdown] `false` models a legacy graded record with
/// no TAT breakdown at all. [legacyPercentage] is the generic
/// `LocalScanResult.percentage` — the screen must never surface it.
LocalScanResult _tatResult({
  required int t1,
  required int t2,
  required int t3,
  int? total,
  String status = 'Graded',
  double legacyPercentage = 0,
  bool breakdown = true,
}) {
  final resolvedTotal = total ?? (t1 + t2 + t3);
  return LocalScanResult(
    rawScore: resolvedTotal,
    totalGraded: 130,
    totalItems: 130,
    percentage: legacyPercentage,
    status: status,
    scannedAt: _at,
    processedByUid: 'u',
    processedByName: 'n',
    tatTest1Correct: breakdown ? t1 ~/ 2 : null,
    tatTest1Wrong: breakdown ? 0 : null,
    tatTest1Score: breakdown ? t1 : null,
    tatTest2Correct: breakdown ? t2 : null,
    tatTest2Wrong: breakdown ? 0 : null,
    tatTest2Score: breakdown ? t2 : null,
    tatTest3Correct: breakdown ? t3 : null,
    tatTest3Wrong: breakdown ? 0 : null,
    tatTest3Score: breakdown ? t3 : null,
    tatTotal: breakdown ? resolvedTotal : null,
  );
}

LocalScanResult _ungradedResult() => LocalScanResult(
      rawScore: 0,
      totalGraded: 0,
      totalItems: 130,
      percentage: 0,
      status: 'Ungraded',
      scannedAt: _at,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScan _scan({String? id, LocalScanResult? result, ExamineeInfo? examinee}) =>
    LocalScan(
      id: id ?? 's${_seq++}',
      imageFileName: 'x.jpg',
      capturedAt: _at,
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
      result: _tatResult(
          t1: t1,
          t2: t2,
          t3: t3,
          total: total,
          legacyPercentage: legacyPercentage),
      examinee: examinee,
    );

/// Graded, but no TAT breakdown — analytics counts it as graded yet
/// excludes it from the score statistics.
LocalScan _legacyGraded({String? id}) => _scan(
      id: id,
      result: _tatResult(
          t1: 0, t2: 0, t3: 0, total: 74, breakdown: false, legacyPercentage: 49),
    );

LocalScan _ungraded({String? id}) => _scan(id: id, result: _ungradedResult());

LocalBatch _batch({
  String id = 'b1',
  String examCode = 'TAT',
  String description = 'TAT August 2026 — Morning',
  List<LocalScan> scans = const [],
}) =>
    LocalBatch(
      id: id,
      batchCode: 'B-TAT-01',
      examCode: examCode,
      examTitle: 'Teaching Aptitude Test',
      description: description,
      expectedCount: 0,
      status: 'Completed',
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: _at,
      updatedAt: _at,
      scans: scans,
    );

/// Four analyzable scans + one ungraded. Totals: 34, 56, 100, 160.
LocalBatch _validBatch({double legacyPercentage = 0}) => _batch(scans: [
      _graded(50, 40, 10, id: 'a', legacyPercentage: legacyPercentage), // 100
      _graded(30, 20, 6, id: 'b', legacyPercentage: legacyPercentage), // 56
      _graded(20, 10, 4, id: 'c', legacyPercentage: legacyPercentage), // 34
      _graded(60, 80, 20, id: 'd', legacyPercentage: legacyPercentage), // 160
      _ungraded(id: 'e'),
    ]);

Future<void> _pump(
  WidgetTester tester, {
  LocalBatch? batch,
  String batchId = 'b1',
}) async {
  // A tall surface so the whole scrolling screen is laid out and every
  // section's widgets exist in the tree for the finders below.
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repo = _FakeBatchRepository(
    batch == null ? const {} : {batch.id: batch},
  );
  final appState = AppState(batchRepository: repo);
  addTearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused handles */}
  });
  await tester.pumpWidget(
    MaterialApp(
      home: AppStateScope(
        notifier: appState,
        child: TatBatchAnalyticsScreen(batchId: batchId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _valueOf(Key sectionKey) =>
    find.descendant(of: find.byKey(sectionKey), matching: find.byType(Text));

Finder _inKey(Key sectionKey, String text) =>
    find.descendant(of: find.byKey(sectionKey), matching: find.text(text));

void main() {
  group('1. Header', () {
    testWidgets('renders app-bar title, batch description and exam type',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      expect(find.text('TAT Analytics'), findsOneWidget);
      expect(find.text('TAT August 2026 — Morning'), findsOneWidget);
      expect(find.text('Teaching Aptitude Test (TAT)'), findsOneWidget);
    });
  });

  group('2 & 3. Overview counts', () {
    testWidgets('total / graded / ungraded / analyzable / excluded',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      expect(_inKey(const Key('tatAnalytics.totalExaminees'), '5'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.gradedExaminees'), '4'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.ungradedExaminees'), '1'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.analyzableExaminees'), '4'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.excludedGradedCount'), '0'),
          findsOneWidget);
    });
  });

  group('4. Excluded warning', () {
    testWidgets('absent when nothing is excluded', (tester) async {
      await _pump(tester, batch: _validBatch());
      expect(find.byKey(const Key('tatAnalytics.excludedWarning')), findsNothing);
    });

    testWidgets('shown when a graded record has no valid TAT breakdown',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(50, 40, 10, id: 'a'), // 100, analyzable
          _graded(20, 10, 4, id: 'c'), // 34, analyzable
          _legacyGraded(id: 'x'),
          _legacyGraded(id: 'y'),
          _ungraded(id: 'e'),
        ]),
      );
      expect(_inKey(const Key('tatAnalytics.analyzableExaminees'), '2'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.excludedGradedCount'), '2'),
          findsOneWidget);
      final warning = find.byKey(const Key('tatAnalytics.excludedWarning'));
      expect(warning, findsOneWidget);
      expect(
        find.descendant(
            of: warning, matching: find.textContaining('excluded from TAT')),
        findsOneWidget,
      );
    });
  });

  group('5. Overall score metrics', () {
    testWidgets('average / highest / lowest / median over /160', (tester) async {
      await _pump(tester, batch: _validBatch());
      // totals [34,56,100,160] -> avg 87.5, median (56+100)/2 = 78.0
      expect(_valueOf(const Key('tatAnalytics.averageScore')),
          containsText('87.5 / 160'));
      expect(_valueOf(const Key('tatAnalytics.highestScore')),
          containsText('160 / 160'));
      expect(_valueOf(const Key('tatAnalytics.lowestScore')),
          containsText('34 / 160'));
      expect(_valueOf(const Key('tatAnalytics.medianScore')),
          containsText('78.0 / 160'));
    });
  });

  group('6. Official percentage metrics', () {
    testWidgets('derived from tatTotal, never the legacy percentage',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      // percentages [21.25, 35.0, 62.5, 100.0]
      expect(_valueOf(const Key('tatAnalytics.averagePercentage')),
          containsText('54.69%')); // mean of the four
      expect(_valueOf(const Key('tatAnalytics.highestPercentage')),
          containsText('100.00%'));
      expect(_valueOf(const Key('tatAnalytics.lowestPercentage')),
          containsText('21.25%'));
      expect(_valueOf(const Key('tatAnalytics.medianPercentage')),
          containsText('48.75%')); // (35.0 + 62.5) / 2
    });
  });

  group('7. Test 1 metrics', () {
    testWidgets('scores [20,30,50,60] -> avg 40.0, high 60, low 20, med 40.0',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      expect(
        find.descendant(
            of: find.byKey(const Key('tatAnalytics.test1')),
            matching: find.text('Test 1')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(const Key('tatAnalytics.test1')),
            matching: find.text('Score / 60')),
        findsOneWidget,
      );
      expect(_valueOf(const Key('tatAnalytics.test1.average')),
          containsText('40.0'));
      expect(_valueOf(const Key('tatAnalytics.test1.highest')),
          containsText('60'));
      expect(_valueOf(const Key('tatAnalytics.test1.lowest')),
          containsText('20'));
      expect(_valueOf(const Key('tatAnalytics.test1.median')),
          containsText('40.0'));
      expect(_valueOf(const Key('tatAnalytics.test1.percentOfMax')),
          containsText('66.67%'));
    });
  });

  group('8. Test 2 metrics', () {
    testWidgets('scores [10,20,40,80] -> avg 37.5, high 80, low 10, med 30.0',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      expect(
        find.descendant(
            of: find.byKey(const Key('tatAnalytics.test2')),
            matching: find.text('Score / 80')),
        findsOneWidget,
      );
      expect(_valueOf(const Key('tatAnalytics.test2.average')),
          containsText('37.5'));
      expect(_valueOf(const Key('tatAnalytics.test2.highest')),
          containsText('80'));
      expect(_valueOf(const Key('tatAnalytics.test2.lowest')),
          containsText('10'));
      expect(_valueOf(const Key('tatAnalytics.test2.median')),
          containsText('30.0'));
      expect(_valueOf(const Key('tatAnalytics.test2.percentOfMax')),
          containsText('46.88%'));
    });
  });

  group('9. Test 3 metrics', () {
    testWidgets('scores [4,6,10,20] -> avg 10.0, high 20, low 4, med 8.0',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      expect(
        find.descendant(
            of: find.byKey(const Key('tatAnalytics.test3')),
            matching: find.text('Score / 20')),
        findsOneWidget,
      );
      expect(_valueOf(const Key('tatAnalytics.test3.average')),
          containsText('10.0'));
      expect(_valueOf(const Key('tatAnalytics.test3.highest')),
          containsText('20'));
      expect(_valueOf(const Key('tatAnalytics.test3.lowest')),
          containsText('4'));
      expect(_valueOf(const Key('tatAnalytics.test3.median')),
          containsText('8.0'));
      expect(_valueOf(const Key('tatAnalytics.test3.percentOfMax')),
          containsText('50.00%'));
    });
  });

  group('10. Strongest / weakest test', () {
    testWidgets('by average % of maximum (Test 1 strongest, Test 2 weakest)',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      // % of max: T1 66.67, T2 46.88, T3 50.00
      expect(_valueOf(const Key('tatAnalytics.strongestTest')),
          containsText('Test 1'));
      expect(_valueOf(const Key('tatAnalytics.weakestTest')),
          containsText('Test 2'));
    });
  });

  group('11 & 12. Eligibility counts and rate', () {
    testWidgets('meets / does-not-meet counts and rate render', (tester) async {
      await _pump(tester, batch: _validBatch());
      // totals: 34 does not meet; 56, 100, 160 meet.
      expect(
        find.byKey(const Key('tatAnalytics.eligibility.meetsRequirement')),
        findsOneWidget,
      );
      expect(
        find.byKey(
            const Key('tatAnalytics.eligibility.doesNotMeetRequirement')),
        findsOneWidget,
      );
      expect(
        _inKey(
            const Key('tatAnalytics.eligibility.meetsRequirement'),
            'Meets TAT Requirement'),
        findsOneWidget,
      );
      expect(
        _inKey(const Key('tatAnalytics.eligibility.meetsRequirement'), '3'),
        findsOneWidget,
      );
      expect(
        _inKey(
            const Key('tatAnalytics.eligibility.doesNotMeetRequirement'), '1'),
        findsOneWidget,
      );
      expect(_valueOf(const Key('tatAnalytics.meetsRequirementRate')),
          containsText('75.00%'));
      expect(find.textContaining('48 / 160 (30%)'), findsOneWidget);
    });
  });

  group('13. Score distribution — eight bands', () {
    testWidgets('all bands render with labels and counts', (tester) async {
      await _pump(tester, batch: _validBatch());
      for (final name in [
        'band0to19',
        'band20to39',
        'band40to59',
        'band60to79',
        'band80to99',
        'band100to119',
        'band120to139',
        'band140to160',
      ]) {
        expect(find.byKey(Key('tatAnalytics.scoreBand.$name')), findsOneWidget);
      }
      expect(find.text('0–19'), findsOneWidget);
      expect(find.text('140–160'), findsOneWidget);
      // 34 -> 20-39, 56 -> 40-59, 100 -> 100-119, 160 -> 140-160
      expect(_inKey(const Key('tatAnalytics.scoreBand.band20to39'), '1'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.scoreBand.band40to59'), '1'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.scoreBand.band100to119'), '1'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.scoreBand.band140to160'), '1'),
          findsOneWidget);
      // an untouched band still renders, showing zero
      expect(_inKey(const Key('tatAnalytics.scoreBand.band0to19'), '0'),
          findsOneWidget);
    });
  });

  group('14. Top scorers', () {
    testWidgets('ranked highest first, score /160 and official percentage',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      // rank 1 = total 160 -> 100.00%
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')), containsText('#1'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')),
          containsText('160 / 160'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')),
          containsText('100.00%'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')),
          containsText('Meets TAT Requirement'));
      // rank 2 = total 100
      expect(_valueOf(const Key('tatAnalytics.topScorer.1')), containsText('#2'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.1')),
          containsText('100 / 160'));
      // lowest analyzable (34) does not meet
      expect(_valueOf(const Key('tatAnalytics.topScorer.3')),
          containsText('Does Not Meet TAT Requirement'));
    });
  });

  group('15. Dense ranking / ties', () {
    testWidgets('tied totals share a rank; the next distinct total is +1',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(50, 40, 10, id: 'a'), // 100
          _graded(50, 40, 10, id: 'b'), // 100
          _graded(20, 10, 4, id: 'c'), // 34
        ]),
      );
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')), containsText('#1'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.1')), containsText('#1'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.2')), containsText('#2'));
    });
  });

  group('16. Missing examinee identity', () {
    testWidgets('missing name -> "Unnamed", missing number -> "—"',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(60, 80, 20, id: 'top'), // examinee == null
          _graded(20, 10, 4,
              id: 'named',
              examinee: const ExamineeInfo(
                  firstName: 'Ann', lastName: 'Cruz', examineeNumber: '')),
        ]),
      );
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')),
          containsText('Unnamed'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')), containsText('—'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.1')),
          containsText('Cruz, Ann'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.1')), containsText('—'));
    });
  });

  group('17. Zero scans', () {
    testWidgets('counts are zero; every section shows an empty state',
        (tester) async {
      await _pump(tester, batch: _batch(scans: const []));
      expect(_inKey(const Key('tatAnalytics.totalExaminees'), '0'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.analyzableExaminees'), '0'),
          findsOneWidget);
      expect(find.byKey(const Key('tatAnalytics.excludedWarning')), findsNothing);
      for (final key in const [
        Key('tatAnalytics.averageScore'),
        Key('tatAnalytics.medianScore'),
        Key('tatAnalytics.averagePercentage'),
        Key('tatAnalytics.test1.average'),
        Key('tatAnalytics.test2.median'),
        Key('tatAnalytics.strongestTest'),
        Key('tatAnalytics.meetsRequirementRate'),
      ]) {
        expect(_valueOf(key), containsText('—'));
      }
      expect(
          find.byKey(const Key('tatAnalytics.eligibilityDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('tatAnalytics.scoreDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('tatAnalytics.topScorers.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('tatAnalytics.scoreBand.band0to19')),
          findsNothing);
    });
  });

  group('18. Zero analyzable (all graded records are legacy)', () {
    testWidgets('amber warning + empty states; no misleading averages',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [_legacyGraded(id: 'x'), _legacyGraded(id: 'y')]),
      );
      expect(_inKey(const Key('tatAnalytics.gradedExaminees'), '2'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.analyzableExaminees'), '0'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.excludedGradedCount'), '2'),
          findsOneWidget);
      expect(find.byKey(const Key('tatAnalytics.excludedWarning')),
          findsOneWidget);
      expect(_valueOf(const Key('tatAnalytics.averageScore')),
          containsText('—'));
      expect(_valueOf(const Key('tatAnalytics.averagePercentage')),
          containsText('—'));
      expect(find.byKey(const Key('tatAnalytics.scoreDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('tatAnalytics.topScorers.empty')),
          findsOneWidget);
    });
  });

  group('19. Mixed valid + excluded records', () {
    testWidgets('valid analytics computed; excluded count + warning shown',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(60, 80, 20, id: 'a'), // 160 analyzable
          _graded(20, 10, 4, id: 'c'), // 34 analyzable
          _legacyGraded(id: 'x'),
          _ungraded(id: 'e'),
        ]),
      );
      expect(_inKey(const Key('tatAnalytics.analyzableExaminees'), '2'),
          findsOneWidget);
      expect(_inKey(const Key('tatAnalytics.excludedGradedCount'), '1'),
          findsOneWidget);
      expect(find.byKey(const Key('tatAnalytics.excludedWarning')),
          findsOneWidget);
      // averages over the two analyzable totals [34, 160] -> 97.0
      expect(_valueOf(const Key('tatAnalytics.averageScore')),
          containsText('97.0 / 160'));
      expect(_inKey(const Key('tatAnalytics.eligibility.meetsRequirement'), '1'),
          findsOneWidget);
      expect(
          _inKey(const Key('tatAnalytics.eligibility.doesNotMeetRequirement'),
              '1'),
          findsOneWidget);
    });
  });

  group('20. Legacy percentage regression', () {
    testWidgets('bogus LocalScanResult.percentage 999.9 is never displayed',
        (tester) async {
      await _pump(tester, batch: _validBatch(legacyPercentage: 999.9));
      expect(find.textContaining('999.9'), findsNothing);
      // official values still derived from tatTotal
      expect(_valueOf(const Key('tatAnalytics.averagePercentage')),
          containsText('54.69%'));
      expect(_valueOf(const Key('tatAnalytics.highestPercentage')),
          containsText('100.00%'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')),
          containsText('100.00%'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')),
          isNot(containsText('999.9')));
    });
  });

  group('21. All examinees meet / do not meet', () {
    testWidgets('all meet -> rate 100.00%', (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(60, 80, 20, id: 'a'), // 160
          _graded(30, 20, 6, id: 'b'), // 56
        ]),
      );
      expect(_inKey(const Key('tatAnalytics.eligibility.meetsRequirement'), '2'),
          findsOneWidget);
      expect(
          _inKey(const Key('tatAnalytics.eligibility.doesNotMeetRequirement'),
              '0'),
          findsOneWidget);
      expect(_valueOf(const Key('tatAnalytics.meetsRequirementRate')),
          containsText('100.00%'));
    });

    testWidgets('none meet -> rate 0.00%', (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(20, 10, 4, id: 'a'), // 34
          _graded(10, 10, 0, id: 'b'), // 20
        ]),
      );
      expect(_inKey(const Key('tatAnalytics.eligibility.meetsRequirement'), '0'),
          findsOneWidget);
      expect(
          _inKey(const Key('tatAnalytics.eligibility.doesNotMeetRequirement'),
              '2'),
          findsOneWidget);
      expect(_valueOf(const Key('tatAnalytics.meetsRequirementRate')),
          containsText('0.00%'));
    });
  });

  group('22. Exactly one analyzable examinee', () {
    testWidgets('average == highest == lowest == median == that score',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [_graded(50, 40, 10, id: 'a')]), // 100
      );
      expect(_valueOf(const Key('tatAnalytics.averageScore')),
          containsText('100.0 / 160'));
      expect(_valueOf(const Key('tatAnalytics.highestScore')),
          containsText('100 / 160'));
      expect(_valueOf(const Key('tatAnalytics.lowestScore')),
          containsText('100 / 160'));
      expect(_valueOf(const Key('tatAnalytics.medianScore')),
          containsText('100.0 / 160'));
      expect(_valueOf(const Key('tatAnalytics.topScorer.0')), containsText('#1'));
      expect(find.byKey(const Key('tatAnalytics.topScorer.1')), findsNothing);
    });
  });

  group('23. Batch not found', () {
    testWidgets('shows "Batch could not be found."', (tester) async {
      await _pump(tester, batch: null, batchId: 'missing');
      expect(find.text('Batch could not be found.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('24. Non-TAT batch', () {
    testWidgets('does not crash; shows "This batch is not a TAT batch."',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(examCode: 'QTM', scans: [_graded(50, 40, 10)]),
      );
      expect(find.text('This batch is not a TAT batch.'), findsOneWidget);
      expect(find.text('Overview'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Matcher: a [Finder] over `Text` widgets contains at least one whose data
/// contains [substring].
Matcher containsText(String substring) => _ContainsText(substring);

class _ContainsText extends Matcher {
  const _ContainsText(this.substring);
  final String substring;

  @override
  bool matches(dynamic item, Map<dynamic, dynamic> matchState) {
    if (item is! Finder) return false;
    for (final element in item.evaluate()) {
      final widget = element.widget;
      if (widget is Text && (widget.data ?? '').contains(substring)) return true;
    }
    return false;
  }

  @override
  Description describe(Description description) =>
      description.add('has a Text containing "$substring"');
}
