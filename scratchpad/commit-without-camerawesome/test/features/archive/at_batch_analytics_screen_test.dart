import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/archive/screens/at_batch_analytics_screen.dart';
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

/// A graded Admission Test result. [totalGraded] / [totalItems] default to
/// 72 (full-key coverage — analyzable). [legacyPercentage] is the generic
/// `LocalScanResult.percentage` field — the screen must never surface it.
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

/// Graded, but the answer key covered fewer than 72 items — counted as
/// graded, excluded from the statistics.
LocalScan _partial(int rawScore, {String? id, int totalGraded = 50}) =>
    _scan(id: id, result: _atResult(rawScore, totalGraded: totalGraded));

LocalScan _ungraded({String? id}) => _scan(id: id, result: _ungradedResult());

LocalBatch _batch({
  String id = 'b1',
  String examCode = 'AT',
  String description = 'AT August 2026 — Morning',
  List<LocalScan> scans = const [],
}) =>
    LocalBatch(
      id: id,
      batchCode: 'B-AT-01',
      examCode: examCode,
      examTitle: 'Admission Test',
      description: description,
      expectedCount: 0,
      status: 'Completed',
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: _at,
      updatedAt: _at,
      scans: scans,
    );

/// Five analyzable scans hitting every bucket (A, Unclassified, B, C, D)
/// plus one ungraded. Raws: 20, 56, 59, 62, 70.
LocalBatch _validBatch({double legacyPercentage = 0}) => _batch(scans: [
      _graded(20, id: 'a', legacyPercentage: legacyPercentage), // A
      _graded(56, id: 'u', legacyPercentage: legacyPercentage), // Unclassified
      _graded(59, id: 'b', legacyPercentage: legacyPercentage), // B
      _graded(62, id: 'c', legacyPercentage: legacyPercentage), // C
      _graded(70, id: 'd', legacyPercentage: legacyPercentage), // D
      _ungraded(id: 'x'),
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
        child: AtBatchAnalyticsScreen(batchId: batchId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _valueOf(Key sectionKey) =>
    find.descendant(of: find.byKey(sectionKey), matching: find.byType(Text));

Finder _inKey(Key sectionKey, String text) =>
    find.descendant(of: find.byKey(sectionKey), matching: find.text(text));

double _pctOf(num raw) => raw / 72 * 100;

void main() {
  group('1. AT batch loads', () {
    testWidgets('app-bar title, header description and exam type render',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      expect(find.text('Admission Analytics'), findsOneWidget);
      expect(find.text('AT August 2026 — Morning'), findsOneWidget);
      expect(find.text('Admission Test (AT)'), findsOneWidget);
    });
  });

  group('2. Zero scans', () {
    testWidgets('counts zero; every section shows an empty state',
        (tester) async {
      await _pump(tester, batch: _batch(scans: const []));
      expect(_inKey(const Key('atAnalytics.totalExaminees'), '0'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.gradedExaminees'), '0'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.analyzableExaminees'), '0'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.excludedGradedCount'), '0'),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.excludedWarning')), findsNothing);
      for (final key in const [
        Key('atAnalytics.averageScore'),
        Key('atAnalytics.highestScore'),
        Key('atAnalytics.lowestScore'),
        Key('atAnalytics.medianScore'),
        Key('atAnalytics.averagePercentage'),
        Key('atAnalytics.highestPercentage'),
        Key('atAnalytics.lowestPercentage'),
        Key('atAnalytics.medianPercentage'),
      ]) {
        expect(_valueOf(key), containsText('—'));
      }
      expect(
          find.byKey(const Key('atAnalytics.categoryDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.scoreDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.topScorers.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.category.a')), findsNothing);
      expect(find.byKey(const Key('atAnalytics.scoreBand.a')), findsNothing);
    });
  });

  group('3. All ungraded', () {
    testWidgets('totals split; empty states; no excluded warning',
        (tester) async {
      await _pump(tester, batch: _batch(scans: [_ungraded(), _ungraded()]));
      expect(_inKey(const Key('atAnalytics.totalExaminees'), '2'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.gradedExaminees'), '0'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.ungradedExaminees'), '2'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.analyzableExaminees'), '0'),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.excludedWarning')), findsNothing);
      expect(_valueOf(const Key('atAnalytics.averageScore')),
          containsText('—'));
      expect(
          find.byKey(const Key('atAnalytics.categoryDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.topScorers.empty')),
          findsOneWidget);
    });
  });

  group('4. Valid graded results', () {
    testWidgets('overview + overall score metrics render from analytics',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      // total 6, graded 5, ungraded 1, analyzable 5, excluded 0
      expect(_inKey(const Key('atAnalytics.totalExaminees'), '6'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.gradedExaminees'), '5'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.ungradedExaminees'), '1'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.analyzableExaminees'), '5'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.excludedGradedCount'), '0'),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.excludedWarning')), findsNothing);

      // raws sorted [20,56,59,62,70] -> avg 53.4, median 59.0
      expect(_valueOf(const Key('atAnalytics.averageScore')),
          containsText('53.4 / 72'));
      expect(_valueOf(const Key('atAnalytics.highestScore')),
          containsText('70 / 72'));
      expect(_valueOf(const Key('atAnalytics.lowestScore')),
          containsText('20 / 72'));
      expect(_valueOf(const Key('atAnalytics.medianScore')),
          containsText('59.0 / 72'));
    });
  });

  group('5. Excluded graded result', () {
    testWidgets('partial-key scan counted as graded, excluded, warning shown',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [_graded(50, id: 'ok'), _partial(60, id: 'bad')]),
      );
      expect(_inKey(const Key('atAnalytics.gradedExaminees'), '2'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.analyzableExaminees'), '1'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.excludedGradedCount'), '1'),
          findsOneWidget);
      final warning = find.byKey(const Key('atAnalytics.excludedWarning'));
      expect(warning, findsOneWidget);
      expect(
        find.descendant(
            of: warning,
            matching:
                find.textContaining('excluded from these statistics')),
        findsOneWidget,
      );
      // stats over the single analyzable scan only
      expect(_valueOf(const Key('atAnalytics.averageScore')),
          containsText('50.0 / 72'));
    });
  });

  group('6. Mixed analyzable + excluded + ungraded', () {
    testWidgets('counts partition; averages over analyzable only',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(60, id: 'a'),
          _graded(20, id: 'b'),
          _partial(70, id: 'c'),
          _ungraded(id: 'd'),
        ]),
      );
      expect(_inKey(const Key('atAnalytics.totalExaminees'), '4'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.gradedExaminees'), '3'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.ungradedExaminees'), '1'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.analyzableExaminees'), '2'),
          findsOneWidget);
      expect(_inKey(const Key('atAnalytics.excludedGradedCount'), '1'),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.excludedWarning')),
          findsOneWidget);
      expect(_valueOf(const Key('atAnalytics.averageScore')),
          containsText('40.0 / 72')); // mean(20, 60)
      expect(_valueOf(const Key('atAnalytics.highestScore')),
          containsText('60 / 72'));
      expect(_valueOf(const Key('atAnalytics.lowestScore')),
          containsText('20 / 72'));
    });
  });

  group('7–11. Category distribution rows + rates', () {
    testWidgets('A / Unclassified / B / C / D rows with counts and rates',
        (tester) async {
      await _pump(tester, batch: _validBatch()); // 5 analyzable, 1 in each
      for (final name in ['a', 'unclassified', 'b', 'c', 'd']) {
        expect(find.byKey(Key('atAnalytics.category.$name')), findsOneWidget);
      }
      expect(_inKey(const Key('atAnalytics.category.a'), 'A'), findsOneWidget);
      expect(_inKey(const Key('atAnalytics.category.unclassified'),
          'Unclassified'), findsOneWidget);
      expect(_inKey(const Key('atAnalytics.category.b'), 'B'), findsOneWidget);
      expect(_inKey(const Key('atAnalytics.category.c'), 'C'), findsOneWidget);
      expect(_inKey(const Key('atAnalytics.category.d'), 'D'), findsOneWidget);
      // each bucket holds exactly one of the five analyzable scans
      for (final name in ['a', 'unclassified', 'b', 'c', 'd']) {
        expect(_inKey(Key('atAnalytics.category.$name'), '1'), findsOneWidget);
        expect(_inKey(Key('atAnalytics.category.$name'), '20.0%'),
            findsOneWidget); // 1 / 5 = 20.0%
      }
    });

    testWidgets('empty-state line when nothing is analyzable', (tester) async {
      await _pump(tester, batch: _batch(scans: [_ungraded(), _partial(50)]));
      expect(
          find.byKey(const Key('atAnalytics.categoryDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.category.a')), findsNothing);
    });
  });

  group('12–21. Boundary scores', () {
    const cases = <int, String>{
      0: 'A',
      54: 'A',
      55: 'Unclassified',
      57: 'Unclassified',
      58: 'B',
      60: 'B',
      61: 'C',
      64: 'C',
      65: 'D',
      72: 'D',
    };
    const bandKeyForCategory = <String, String>{
      'A': 'a',
      'Unclassified': 'unclassified',
      'B': 'b',
      'C': 'c',
      'D': 'd',
    };
    cases.forEach((raw, category) {
      testWidgets('raw $raw -> $category', (tester) async {
        await _pump(
          tester,
          batch: _batch(scans: [_graded(raw, id: 'only')]),
        );
        final bandKey = bandKeyForCategory[category]!;
        // category distribution row
        expect(_inKey(Key('atAnalytics.category.$bandKey'), '1'),
            findsOneWidget);
        // score distribution band
        expect(_inKey(Key('atAnalytics.scoreBand.$bandKey'), '1'),
            findsOneWidget);
        // top scorer row: score, percentage, category label
        final row = _valueOf(const Key('atAnalytics.topScorer.only'));
        expect(row, containsText('$raw / 72'));
        expect(row, containsText('${_pctOf(raw).toStringAsFixed(2)}%'));
        expect(row, containsText(category));
      });
    });
  });

  group('22. Percentage display (official rawScore / 72 * 100)', () {
    testWidgets('[36, 54] -> avg 62.50%, high 75.00%, low 50.00%',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [_graded(36), _graded(54)]),
      );
      expect(_valueOf(const Key('atAnalytics.averagePercentage')),
          containsText('62.50%')); // mean(50.0, 75.0)
      expect(_valueOf(const Key('atAnalytics.highestPercentage')),
          containsText('75.00%'));
      expect(_valueOf(const Key('atAnalytics.lowestPercentage')),
          containsText('50.00%'));
      expect(_valueOf(const Key('atAnalytics.medianPercentage')),
          containsText('62.50%'));
    });
  });

  group('23. Top scorers', () {
    testWidgets('ranked highest first with score / 72, percentage, category',
        (tester) async {
      await _pump(tester, batch: _validBatch());
      // #1 = raw 70 (D), #5 = raw 20 (A)
      final first = _valueOf(const Key('atAnalytics.topScorer.d'));
      expect(first, containsText('#1'));
      expect(first, containsText('70 / 72'));
      expect(first, containsText('${_pctOf(70).toStringAsFixed(2)}%'));
      expect(first, containsText('D'));
      final unclassified = _valueOf(const Key('atAnalytics.topScorer.u'));
      expect(unclassified, containsText('#4'));
      expect(unclassified, containsText('Unclassified'));
      final last = _valueOf(const Key('atAnalytics.topScorer.a'));
      expect(last, containsText('#5'));
      expect(last, containsText('20 / 72'));
    });
  });

  group('24. Dense tied ranking (from AtRankedScorer.rank)', () {
    testWidgets('[65, 65, 60] -> #1, #1, #2', (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(65, id: 'a'),
          _graded(65, id: 'b'),
          _graded(60, id: 'c'),
        ]),
      );
      expect(_valueOf(const Key('atAnalytics.topScorer.a')), containsText('#1'));
      expect(_valueOf(const Key('atAnalytics.topScorer.b')), containsText('#1'));
      expect(_valueOf(const Key('atAnalytics.topScorer.c')), containsText('#2'));
    });
  });

  group('25. Missing examinee identity', () {
    testWidgets('missing name -> "Unnamed"; missing number -> "—"',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(50, id: 'noTag'), // examinee == null
          _graded(40,
              id: 'named',
              examinee: const ExamineeInfo(
                  firstName: 'Ann', lastName: 'Cruz', examineeNumber: '')),
        ]),
      );
      final noTag = _valueOf(const Key('atAnalytics.topScorer.noTag'));
      expect(noTag, containsText('Unnamed'));
      expect(noTag, containsText('—'));
      final named = _valueOf(const Key('atAnalytics.topScorer.named'));
      expect(named, containsText('Cruz, Ann'));
      expect(named, containsText('—'));
    });
  });

  group('26. Legacy stored percentage regression', () {
    testWidgets('LocalScanResult.percentage = 999.9 never appears',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(36, legacyPercentage: 999.9),
          _graded(72, legacyPercentage: 999.9),
        ]),
      );
      expect(find.textContaining('999.9'), findsNothing);
      // official values: mean(50.0, 100.0) = 75.0
      expect(_valueOf(const Key('atAnalytics.averagePercentage')),
          containsText('75.00%'));
      expect(_valueOf(const Key('atAnalytics.highestPercentage')),
          containsText('100.00%'));
      expect(_valueOf(const Key('atAnalytics.lowestPercentage')),
          containsText('50.00%'));
      expect(_valueOf(const Key('atAnalytics.averageScore')),
          containsText('54.0 / 72'));
    });
  });

  group('27. Non-AT batch', () {
    testWidgets('does not crash; shows the not-an-AT-batch message',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(examCode: 'QTM', scans: [_graded(50)]),
      );
      expect(find.text('This batch is not an Admission Test batch.'),
          findsOneWidget);
      expect(find.text('Overview'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('28. Missing batch', () {
    testWidgets('shows "Batch could not be found."', (tester) async {
      await _pump(tester, batch: null, batchId: 'missing');
      expect(find.text('Batch could not be found.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Score distribution — five official category-aligned bands', () {
    testWidgets('all five bands render; corrupt-free counts', (tester) async {
      await _pump(tester, batch: _validBatch());
      for (final name in ['a', 'unclassified', 'b', 'c', 'd']) {
        expect(find.byKey(Key('atAnalytics.scoreBand.$name')), findsOneWidget);
        expect(_inKey(Key('atAnalytics.scoreBand.$name'), '1'), findsOneWidget);
      }
    });

    testWidgets('empty-state line when nothing is analyzable', (tester) async {
      await _pump(tester, batch: _batch(scans: [_ungraded()]));
      expect(find.byKey(const Key('atAnalytics.scoreDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('atAnalytics.scoreBand.d')), findsNothing);
    });
  });

  group('Median — even analyzable count', () {
    testWidgets('[20, 40, 60, 72] -> median 50.0 / 72', (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(20),
          _graded(40),
          _graded(60),
          _graded(72),
        ]),
      );
      expect(_valueOf(const Key('atAnalytics.medianScore')),
          containsText('50.0 / 72'));
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
