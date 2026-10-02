import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/archive/screens/qtm_batch_analytics_screen.dart';
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

LocalScanResult _gradedResult(int rawScore) => LocalScanResult(
      rawScore: rawScore,
      totalGraded: 60,
      totalItems: 60,
      // Legacy/generic value — the screen must never surface this.
      percentage: 99.9,
      status: 'Graded',
      scannedAt: _at,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScanResult _ungradedResult() => LocalScanResult(
      rawScore: 0,
      totalGraded: 0,
      totalItems: 60,
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
      decoded: const OmrScanResult(examCode: 'QTM', items: []),
      result: result,
      examinee: examinee,
    );

LocalScan _graded(int rawScore, {String? id, ExamineeInfo? examinee}) =>
    _scan(id: id, result: _gradedResult(rawScore), examinee: examinee);

LocalScan _ungraded({String? id}) => _scan(id: id, result: _ungradedResult());

LocalBatch _batch({
  String id = 'b1',
  String examCode = 'QTM',
  String description = 'QTM August 2026 — Morning',
  List<LocalScan> scans = const [],
}) =>
    LocalBatch(
      id: id,
      batchCode: 'B-QTM-01',
      examCode: examCode,
      examTitle: 'Quantitative Math Test',
      description: description,
      expectedCount: 0,
      status: 'Completed',
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: _at,
      updatedAt: _at,
      scans: scans,
    );

Future<void> _pump(
  WidgetTester tester, {
  LocalBatch? batch,
  String batchId = 'b1',
}) async {
  // A tall surface so the whole scrolling screen is laid out and every
  // section's widgets exist in the tree for the finders below.
  tester.view.physicalSize = const Size(1200, 4000);
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
        child: QtmBatchAnalyticsScreen(batchId: batchId),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _valueOf(Key sectionKey) =>
    find.descendant(of: find.byKey(sectionKey), matching: find.byType(Text));

void main() {
  group('1. QTM batch — overview + performance render from analytics', () {
    // graded raw scores: 40, 20, 55, 10, 35  (sum 160, mean 32)  + 3 ungraded
    late LocalBatch batch;
    setUp(() {
      batch = _batch(scans: [
        _graded(40),
        _graded(20),
        _graded(55),
        _graded(10),
        _graded(35),
        _ungraded(),
        _ungraded(),
        _ungraded(),
      ]);
    });

    testWidgets('overview counts', (tester) async {
      await _pump(tester, batch: batch);
      expect(find.text('Total Examinees'), findsOneWidget);
      expect(find.text('Graded'), findsOneWidget);
      expect(find.text('Ungraded'), findsOneWidget);
      expect(
        find.descendant(
            of: find.byKey(const Key('qtmAnalytics.totalExaminees')),
            matching: find.text('8')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(const Key('qtmAnalytics.gradedExaminees')),
            matching: find.text('5')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(const Key('qtmAnalytics.ungradedExaminees')),
            matching: find.text('3')),
        findsOneWidget,
      );
    });

    testWidgets('performance metrics come straight from QtmBatchAnalytics',
        (tester) async {
      await _pump(tester, batch: batch);
      expect(find.text('Average Raw Score'), findsOneWidget);
      expect(find.text('Average Official Percentage'), findsOneWidget);
      expect(find.text('Highest Raw Score'), findsOneWidget);
      expect(find.text('Lowest Raw Score'), findsOneWidget);
      expect(find.text('Median Raw Score'), findsOneWidget);

      expect(_valueOf(const Key('qtmAnalytics.averageRawScore')),
          containsText('32.0'));
      // official % = 32 / 60 * 100 = 53.33% (NOT the legacy 99.9)
      expect(_valueOf(const Key('qtmAnalytics.averagePercentage')),
          containsText('53.33%'));
      expect(find.textContaining('99.9'), findsNothing);
      expect(_valueOf(const Key('qtmAnalytics.highestRawScore')),
          containsText('55'));
      expect(_valueOf(const Key('qtmAnalytics.lowestRawScore')),
          containsText('10'));
      // median of sorted [10,20,35,40,55] -> 35.0
      expect(_valueOf(const Key('qtmAnalytics.medianRawScore')),
          containsText('35.0'));
    });

    testWidgets('header shows the QTM exam type', (tester) async {
      await _pump(tester, batch: batch);
      expect(find.text('QTM August 2026 — Morning'), findsOneWidget);
      expect(find.text('Qualifying Test in Mathematics (QTM)'), findsOneWidget);
    });
  });

  group('2. Score distribution renders all six bands', () {
    testWidgets('bands, labels and counts', (tester) async {
      // raws: 10, 15, 35, 40, 55  -> bands: 0-9:0, 10-19:2, 20-29:0,
      // 30-39:1, 40-49:1, 50-60:1
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(10),
          _graded(15),
          _graded(35),
          _graded(40),
          _graded(55),
        ]),
      );
      for (final name in [
        'band0to9',
        'band10to19',
        'band20to29',
        'band30to39',
        'band40to49',
        'band50to60',
      ]) {
        expect(find.byKey(Key('qtmAnalytics.scoreBand.$name')), findsOneWidget);
      }
      expect(find.text('0–9'), findsOneWidget);
      expect(find.text('50–60'), findsOneWidget);
      expect(
        find.descendant(
            of: find.byKey(const Key('qtmAnalytics.scoreBand.band10to19')),
            matching: find.text('2')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(const Key('qtmAnalytics.scoreBand.band0to9')),
            matching: find.text('0')),
        findsOneWidget,
      );
    });
  });

  group('3. Eligibility distribution renders the three official groups', () {
    testWidgets('labels + counts', (tester) async {
      // raws: 10 (notEligible), 16 (exceptBscs), 40 & 55 (incl. BSCS)
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(10),
          _graded(16),
          _graded(40),
          _graded(55),
        ]),
      );
      expect(find.byKey(const Key('qtmAnalytics.eligibility.allCoursesIncludingBscs')),
          findsOneWidget);
      expect(find.byKey(const Key('qtmAnalytics.eligibility.allCoursesExceptBscs')),
          findsOneWidget);
      expect(find.byKey(const Key('qtmAnalytics.eligibility.notEligible')),
          findsOneWidget);

      // Labels scoped to the distribution rows (they also appear per top scorer).
      expect(
        find.descendant(
            of: find.byKey(
                const Key('qtmAnalytics.eligibility.allCoursesIncludingBscs')),
            matching: find.text('All QTM-required courses, incl. BSCS')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(
                const Key('qtmAnalytics.eligibility.allCoursesExceptBscs')),
            matching: find.text('All QTM-required courses, except BSCS')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(const Key('qtmAnalytics.eligibility.notEligible')),
            matching: find.text('Does not meet the QTM requirement')),
        findsOneWidget,
      );

      expect(
        find.descendant(
            of: find.byKey(
                const Key('qtmAnalytics.eligibility.allCoursesIncludingBscs')),
            matching: find.text('2')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(
                const Key('qtmAnalytics.eligibility.allCoursesExceptBscs')),
            matching: find.text('1')),
        findsOneWidget,
      );
    });
  });

  group('4. Top scorers render (rank, score, percentage)', () {
    testWidgets('ranked, highest first', (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(30, id: 'a'),
          _graded(55, id: 'b'),
          _graded(45, id: 'c'),
        ]),
      );
      // rank 1 = raw 55 -> 91.67%
      expect(
        find.descendant(
          of: find.byKey(const Key('qtmAnalytics.topScorer.1.b')),
          matching: find.text('#1'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('55 / 60'), findsOneWidget);
      expect(find.textContaining('91.67%'), findsOneWidget);
      expect(find.textContaining('45 / 60'), findsOneWidget);
      expect(find.textContaining('30 / 60'), findsOneWidget);
    });
  });

  group('5 & 6. Missing examinee identity fallbacks', () {
    testWidgets('missing displayName -> "Unnamed"', (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(50, id: 'top'), // examinee == null
          _graded(20, id: 'other'),
        ]),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('qtmAnalytics.topScorer.1.top')),
          matching: find.text('Unnamed'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('missing examineeNumber -> "—" (fully graded batch)',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(scans: [
          _graded(50,
              id: 'nameOnly',
              examinee: const ExamineeInfo(
                  firstName: 'Ann', lastName: 'Cruz', examineeNumber: '')),
        ]),
      );
      expect(find.text('Cruz, Ann'), findsOneWidget);
      // The only "—" in a fully-graded batch is the missing examinee number.
      expect(find.text('—'), findsOneWidget);
    });
  });

  group('7 & 8. Empty / all-ungraded batch', () {
    late LocalBatch batch;
    setUp(() {
      batch = _batch(scans: [_ungraded(), _ungraded(), _ungraded()]);
    });

    testWidgets('null metrics render as "—"', (tester) async {
      await _pump(tester, batch: batch);
      expect(
        find.descendant(
            of: find.byKey(const Key('qtmAnalytics.gradedExaminees')),
            matching: find.text('0')),
        findsOneWidget,
      );
      for (final key in const [
        Key('qtmAnalytics.averageRawScore'),
        Key('qtmAnalytics.averagePercentage'),
        Key('qtmAnalytics.highestRawScore'),
        Key('qtmAnalytics.lowestRawScore'),
        Key('qtmAnalytics.medianRawScore'),
      ]) {
        expect(_valueOf(key), containsText('—'));
      }
    });

    testWidgets('empty distributions and top scorers show empty-states',
        (tester) async {
      await _pump(tester, batch: batch);
      expect(find.byKey(const Key('qtmAnalytics.scoreDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('qtmAnalytics.eligibilityDistribution.empty')),
          findsOneWidget);
      expect(find.byKey(const Key('qtmAnalytics.topScorers.empty')),
          findsOneWidget);
      // no bands / eligibility rows rendered
      expect(find.byKey(const Key('qtmAnalytics.scoreBand.band0to9')),
          findsNothing);
      expect(find.byKey(const Key('qtmAnalytics.eligibility.notEligible')),
          findsNothing);
    });
  });

  group('9. Batch not found', () {
    testWidgets('shows "Batch could not be found."', (tester) async {
      await _pump(tester, batch: null, batchId: 'missing');
      expect(find.text('Batch could not be found.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('10. Non-QTM batch', () {
    testWidgets('does not crash; shows "This batch is not a QTM batch."',
        (tester) async {
      await _pump(
        tester,
        batch: _batch(examCode: 'AT', scans: [_graded(40)]),
      );
      expect(find.text('This batch is not a QTM batch.'), findsOneWidget);
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
