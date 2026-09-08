import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/features/exam/widgets/scan_result_summary.dart';
import 'package:guidegrade/models/local_batch.dart';

final _fixedAt = DateTime.utc(2026, 1, 1);

LocalScanResult _atResult({
  required int rawScore,
  required double percentage,
  String status = 'Graded',
}) =>
    LocalScanResult(
      rawScore: rawScore,
      totalGraded: 72,
      totalItems: 72,
      percentage: percentage,
      status: status,
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScanResult _qtmResult({
  required int rawScore,
  String status = 'Graded',
}) =>
    LocalScanResult(
      rawScore: rawScore,
      totalGraded: 60,
      totalItems: 60,
      // Legacy compatibility value, deliberately unrelated to any tested
      // raw score's official `raw / 60 * 100`: the widget must surface
      // qtmPercentage(rawScore), never this field.
      percentage: 99.9,
      status: status,
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
    );

LocalScanResult _tatResult({
  required int t1c,
  required int t1w,
  required int t1s,
  required int t2c,
  required int t2w,
  required int t2s,
  required int t3c,
  required int t3w,
  required int t3s,
  required int total,
}) =>
    LocalScanResult(
      rawScore: total,
      totalGraded: 130,
      totalItems: 130,
      // Legacy generic percentage — must not be rendered for TAT.
      percentage: 49.23,
      status: 'Graded',
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
      tatTest1Correct: t1c,
      tatTest1Wrong: t1w,
      tatTest1Score: t1s,
      tatTest2Correct: t2c,
      tatTest2Wrong: t2w,
      tatTest2Score: t2s,
      tatTest3Correct: t3c,
      tatTest3Wrong: t3w,
      tatTest3Score: t3s,
      tatTotal: total,
    );

/// A pre-breakdown TAT record: status graded, but none of the tat* fields
/// were persisted -> hasTatBreakdown == false.
LocalScanResult _legacyTat() => LocalScanResult(
      rawScore: 64,
      totalGraded: 130,
      totalItems: 130,
      percentage: 49.2,
      status: 'Graded',
      scannedAt: _fixedAt,
      processedByUid: 'u',
      processedByName: 'n',
    );

ScoredResult _liveScored(String examCode, String section,
    {required int correct, required int wrong}) {
  final items = <ScoredItem>[];
  var n = 1;
  for (var i = 0; i < correct; i++) {
    items.add(ScoredItem(
      sectionName: section,
      itemNumber: n++,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: 'A',
    ));
  }
  for (var i = 0; i < wrong; i++) {
    items.add(ScoredItem(
      sectionName: section,
      itemNumber: n++,
      markedChoice: 'A',
      isAmbiguous: false,
      correctChoice: 'B',
    ));
  }
  return ScoredResult(examCode: examCode, items: items);
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('1. Admission Test — normal score', () {
    testWidgets('rawScore 60 -> "60 / 72", "83%", category "B"', (tester) async {
      // NOTE: the task brief's illustrative test #1 shows category "D" for a
      // raw score of 60, but that contradicts the authoritative band table
      // (58–60 -> B) and the task's own boundary list (test #2: "60 -> B").
      // Stage 1 is authoritative: admissionCategory(60) == B, so the widget
      // shows "B". A "D" case is exercised separately below.
      await _pump(
        tester,
        ScanResultSummary(examCode: 'AT', result: _atResult(rawScore: 60, percentage: 83.33)),
      );
      expect(find.text('60 / 72'), findsOneWidget);
      expect(find.text('83%'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('D'), findsNothing);
    });

    testWidgets('rawScore 68 -> "68 / 72", "94%", category "D"', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'AT', result: _atResult(rawScore: 68, percentage: 68 / 72 * 100)),
      );
      expect(find.text('68 / 72'), findsOneWidget);
      expect(find.text('94%'), findsOneWidget);
      expect(find.text('D'), findsOneWidget);
    });
  });

  group('2. Admission Test — category boundaries', () {
    const cases = <int, String>{
      54: 'A',
      55: 'Not classified',
      56: 'Not classified',
      57: 'Not classified',
      58: 'B',
      60: 'B',
      61: 'C',
      64: 'C',
      65: 'D',
      72: 'D',
    };
    cases.forEach((score, label) {
      testWidgets('rawScore $score -> "$label"', (tester) async {
        await _pump(
          tester,
          ScanResultSummary(
            examCode: 'AT',
            result: _atResult(rawScore: score, percentage: score / 72 * 100),
          ),
        );
        expect(find.text('Category'), findsOneWidget);
        expect(find.text(label), findsOneWidget);
        if (label == 'Not classified') {
          expect(find.text('A'), findsNothing);
          expect(find.text('B'), findsNothing);
          expect(find.text('C'), findsNothing);
          expect(find.text('D'), findsNothing);
        }
      });
    });
  });

  group('3. Admission Test — ungraded', () {
    testWidgets('shows only "Ungraded"', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(
          examCode: 'AT',
          result: _atResult(rawScore: 0, percentage: 0, status: 'Ungraded'),
        ),
      );
      expect(find.text('Ungraded'), findsOneWidget);
      expect(find.text('Category'), findsNothing);
      expect(find.textContaining('/ 72'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });
  });

  group('4. QTM — graded: score / official percentage / eligibility', () {
    testWidgets('1. rawScore 26 -> 26/60, 43.33%, incl. BSCS', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 26)),
      );
      expect(find.text('Score'), findsOneWidget);
      expect(find.text('26 / 60'), findsOneWidget);
      expect(find.text('Percentage'), findsOneWidget);
      expect(find.text('43.33%'), findsOneWidget);
      expect(find.text('Eligibility'), findsOneWidget);
      expect(find.textContaining('incl. BSCS'), findsOneWidget);
      expect(find.textContaining('except BSCS'), findsNothing);
    });

    testWidgets('2. rawScore 0 -> 0/60, 0.00%, does not meet requirement',
        (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 0)),
      );
      expect(find.text('0 / 60'), findsOneWidget);
      expect(find.text('0.00%'), findsOneWidget);
      expect(
          find.textContaining('Does not meet the QTM requirement'), findsOneWidget);
      expect(find.textContaining('BSCS'), findsNothing);
    });

    testWidgets('3. rawScore 14 -> 14/60, 23.33%, does not meet requirement',
        (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 14)),
      );
      expect(find.text('14 / 60'), findsOneWidget);
      expect(find.text('23.33%'), findsOneWidget);
      expect(
          find.textContaining('Does not meet the QTM requirement'), findsOneWidget);
    });

    testWidgets('4. rawScore 15 -> 15/60, 25.00%, except BSCS (inclusive 25%)',
        (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 15)),
      );
      expect(find.text('15 / 60'), findsOneWidget);
      expect(find.text('25.00%'), findsOneWidget);
      expect(find.textContaining('except BSCS'), findsOneWidget);
      expect(find.textContaining('incl. BSCS'), findsNothing);
    });

    testWidgets('5. rawScore 17 -> 17/60, 28.33%, except BSCS', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 17)),
      );
      expect(find.text('17 / 60'), findsOneWidget);
      expect(find.text('28.33%'), findsOneWidget);
      expect(find.textContaining('except BSCS'), findsOneWidget);
    });

    testWidgets('6. rawScore 18 -> 18/60, 30.00%, incl. BSCS (inclusive 30%)',
        (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 18)),
      );
      expect(find.text('18 / 60'), findsOneWidget);
      expect(find.text('30.00%'), findsOneWidget);
      expect(find.textContaining('incl. BSCS'), findsOneWidget);
      expect(find.textContaining('except BSCS'), findsNothing);
    });

    testWidgets('7. rawScore 60 -> 60/60, 100.00%, incl. BSCS', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 60)),
      );
      expect(find.text('60 / 60'), findsOneWidget);
      expect(find.text('100.00%'), findsOneWidget);
      expect(find.textContaining('incl. BSCS'), findsOneWidget);
    });

    testWidgets('9. live-only QTM (result: null): raw 18 -> 30.00%, incl. BSCS',
        (tester) async {
      // 18 correct + 12 wrong out of a graded QTM sheet -> live raw 18.
      final live = _liveScored('QTM', 'Qualifying Test in Mathematics',
          correct: 18, wrong: 12);
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: null, live: live),
      );
      expect(find.text('18 / 60'), findsOneWidget);
      expect(find.text('30.00%'), findsOneWidget);
      expect(find.textContaining('incl. BSCS'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('10. legacy persisted percentage (99.9) is never rendered; '
        'the shown percentage is qtmPercentage(rawScore)', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'QTM', result: _qtmResult(rawScore: 26)),
      );
      expect(find.text('43.33%'), findsOneWidget); // 26 / 60 * 100
      expect(find.textContaining('99.9'), findsNothing);
      expect(find.textContaining('99'), findsNothing);
    });
  });

  group('5. QTM — ungraded', () {
    testWidgets('shows only "Ungraded" — no score, percentage or eligibility',
        (tester) async {
      await _pump(
        tester,
        ScanResultSummary(
          examCode: 'QTM',
          result: _qtmResult(rawScore: 0, status: 'Ungraded'),
        ),
      );
      expect(find.text('Ungraded'), findsOneWidget);
      expect(find.text('Score'), findsNothing);
      expect(find.text('Percentage'), findsNothing);
      expect(find.text('Eligibility'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('/ 60'), findsNothing);
      expect(find.textContaining('BSCS'), findsNothing);
    });
  });

  group('6. TAT — full breakdown', () {
    testWidgets('renders per-test lines and TAT total, never the old mixed '
        'presentation', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(
          examCode: 'TAT',
          result: _tatResult(
            t1c: 18, t1w: 0, t1s: 36,
            t2c: 40, t2w: 10, t2s: 30,
            t3c: 12, t3w: 4, t3s: 8,
            total: 74,
          ),
        ),
      );
      expect(find.text('Test 1'), findsOneWidget);
      expect(find.text('Test 2'), findsOneWidget);
      expect(find.text('Test 3'), findsOneWidget);
      expect(find.text('TAT Total'), findsOneWidget);
      expect(find.textContaining('18 correct'), findsOneWidget);
      expect(find.textContaining('36 / 60'), findsOneWidget);
      expect(find.textContaining('30 / 80'), findsOneWidget);
      expect(find.textContaining('8 / 20'), findsOneWidget);
      expect(find.textContaining('74 / 160'), findsOneWidget);

      // The old generic presentation must not be reproduced.
      expect(find.textContaining('74/130'), findsNothing);
      expect(find.textContaining('49%'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
    });
  });

  group('7. TAT — zero-score clamp', () {
    testWidgets('a clamped Test 2/Test 3 shows "0 / 80" / "0 / 20", never '
        'a negative', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(
          examCode: 'TAT',
          result: _tatResult(
            t1c: 0, t1w: 0, t1s: 0,
            t2c: 5, t2w: 15, t2s: 0,
            t3c: 5, t3w: 15, t3s: 0,
            total: 0,
          ),
        ),
      );
      expect(find.textContaining('5 correct − 15 wrong = 0 / 80'), findsOneWidget);
      expect(find.textContaining('5 correct − 15 wrong = 0 / 20'), findsOneWidget);
      expect(find.textContaining('0 / 160'), findsOneWidget);
      expect(find.textContaining('-10'), findsNothing);
      expect(find.textContaining('= -'), findsNothing);
    });
  });

  group('8. Legacy TAT record (hasTatBreakdown == false)', () {
    testWidgets('shows the safe fallback, no fabricated Test 1/2/3 scores, '
        'no exception', (tester) async {
      await _pump(
        tester,
        ScanResultSummary(examCode: 'TAT', result: _legacyTat()),
      );
      expect(find.text('TAT breakdown unavailable'), findsOneWidget);
      expect(find.text('Test 1'), findsNothing);
      expect(find.text('Test 2'), findsNothing);
      expect(find.text('Test 3'), findsNothing);
      expect(find.textContaining('/ 60'), findsNothing);
      expect(find.textContaining('/ 160'), findsNothing);
      expect(find.textContaining('%'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('9. Null result / live-only', () {
    testWidgets('AT live-only: uses live raw + official /72 percentage, '
        'no crash', (tester) async {
      // 60 correct + 12 wrong out of 72 -> raw 60, official 60/72 = 83.33%.
      final live = _liveScored('AT', 'Answer Document', correct: 60, wrong: 12);
      await _pump(
        tester,
        ScanResultSummary(examCode: 'AT', result: null, live: live),
      );
      expect(find.text('60 / 72'), findsOneWidget);
      expect(find.text('83%'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TAT live-only: safe fallback, no crash', (tester) async {
      final live = _liveScored('TAT', 'Test I', correct: 3, wrong: 1);
      await _pump(
        tester,
        ScanResultSummary(examCode: 'TAT', result: null, live: live),
      );
      expect(find.text('TAT breakdown unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('everything null -> "Ungraded", no crash', (tester) async {
      await _pump(
        tester,
        const ScanResultSummary(examCode: 'AT', result: null, live: null),
      );
      expect(find.text('Ungraded'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('10. Unknown exam code', () {
    testWidgets('conservative fallback, never the AT/QTM/TAT layout',
        (tester) async {
      final unknown = LocalScanResult(
        rawScore: 10,
        totalGraded: 20,
        totalItems: 20,
        percentage: 50,
        status: 'Graded',
        scannedAt: _fixedAt,
        processedByUid: 'u',
        processedByName: 'n',
      );
      await _pump(
        tester,
        ScanResultSummary(examCode: 'ZZZ', result: unknown),
      );
      expect(find.textContaining('10 / 20'), findsOneWidget);
      expect(find.textContaining('/ 72'), findsNothing);
      expect(find.textContaining('/ 60'), findsNothing);
      expect(find.text('Category'), findsNothing);
      expect(find.text('Test 1'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('unknown + ungraded -> "Ungraded"', (tester) async {
      final unknown = LocalScanResult(
        rawScore: 0,
        totalGraded: 0,
        totalItems: 20,
        percentage: 0,
        status: 'Ungraded',
        scannedAt: _fixedAt,
        processedByUid: 'u',
        processedByName: 'n',
      );
      await _pump(
        tester,
        ScanResultSummary(examCode: 'ZZZ', result: unknown),
      );
      expect(find.text('Ungraded'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
