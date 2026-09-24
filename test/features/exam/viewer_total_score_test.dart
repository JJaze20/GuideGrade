import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/exam_score.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/omr/scan_rescoring.dart';
import 'package:guidegrade/features/exam/screens/scanned_image_viewer_screen.dart';
import 'package:guidegrade/features/exam/widgets/answer_correction_sheet.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

// 1x1 transparent PNG, so Image.memory has something valid to decode.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// A full AT sheet where every item is marked with the key's answer, except
/// item 1 (double mark) and item 2 (a plain wrong answer).
({LocalScan scan, AnswerKey key}) _fixture() {
  final tpl = omrTemplates['AT']!;
  final firstN = (tpl.sections.first.items.keys.toList()..sort()).first;
  final keyMap = <String, String>{};
  final items = <OmrItemResult>[];
  for (final s in tpl.sections) {
    for (final n in (s.items.keys.toList()..sort())) {
      final choices = [for (final b in s.items[n]!) b.choice];
      final right = choices.first;
      final wrong = choices.last;
      keyMap[AnswerKey.keyFor(s.name, n)] = right;
      final isFirst = identical(s, tpl.sections.first);
      if (isFirst && n == firstN) {
        items.add(OmrItemResult(sectionName: s.name, itemNumber: n, markedChoice: null, isAmbiguous: true));
      } else if (isFirst && n == firstN + 1) {
        items.add(OmrItemResult(sectionName: s.name, itemNumber: n, markedChoice: wrong));
      } else {
        items.add(OmrItemResult(sectionName: s.name, itemNumber: n, markedChoice: right));
      }
    }
  }
  final scan = LocalScan(
    id: 's1',
    imageFileName: 'images/s1.enc',
    capturedAt: DateTime.utc(2026, 9, 1),
    decoded: OmrScanResult(examCode: 'AT', items: items, templateVersion: tpl.templateVersion),
  );
  return (scan: scan, key: AnswerKey(examCode: 'AT', correctChoices: keyMap));
}

void main() {
  final fx = _fixture();
  final firstSection = omrTemplates['AT']!.sections.first.name;
  final rightForItem1 = fx.key.choiceFor(firstSection, (omrTemplates['AT']!.sections.first.items.keys.toList()..sort()).first)!;

  test('baseline: item 1 (flagged) and item 2 (wrong) both score 0 -> 70 / 72', () {
    final scored = scoreOmrResult(fx.scan.effectiveDecoded, fx.key);
    expect(computeExamScoreForCode(scored)!.rawScore, 70);
    expect(fx.scan.needsReview, isTrue);
  });

  testWidgets('total score shows on open and updates the moment a correction is saved; '
      'persisted result, banner and batch summary all agree', (tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var stored = fx.scan; // stands in for what the repository holds
    var saves = 0;

    final editing = ScanEditing(
      scan: fx.scan,
      answerKey: fx.key,
      onCorrect: (section, item, value, reason, requestId) async {
        final history = CorrectionRules.withCorrection(
          stored.corrections,
          id: requestId,
          scanId: stored.id,
          captureRevision: stored.captureRevision,
          detected: stored.decoded.items.firstWhere((i) => i.sectionName == section && i.itemNumber == item),
          value: value,
          at: DateTime.utc(2026, 9, 2),
        );
        var next = stored.copyWith(corrections: history);
        // Same call AppState makes on every correction: one write carries
        // both the history and the recalculated score.
        next = next.copyWith(result: rescoreScan(scan: next, answerKey: fx.key));
        stored = next;
        saves++;
        return stored;
      },
      onReset: (section, item, requestId) async => stored,
    );

    final tpl = omrTemplates['AT']!;
    await tester.pumpWidget(
      MaterialApp(
        home: ScannedImageViewerScreen(
          imageBytes: _png,
          title: 'Sheet 1',
          scoredItems: scoreOmrResult(fx.scan.effectiveDecoded, fx.key).items,
          template: tpl,
          scanTemplateVersion: tpl.templateVersion,
          editing: editing,
        ),
      ),
    );
    await tester.pumpAndSettle();

    Text banner() => tester.widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('viewer-total-score')),
            matching: find.textContaining(' / '),
          ),
        );
    expect(banner().data, '70 / 72');

    // Open the answer-key drawer, tap item 1 (the flagged one), pick the right answer.
    await tester.tap(find.byIcon(Icons.fact_check_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('read multiple').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('answerCorrection.choice.$rightForItem1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('answerCorrection.save')));
    await tester.pumpAndSettle();

    expect(saves, 1);
    expect(banner().data, '71 / 72', reason: 'recalculated immediately, no reopen needed');

    // What was persisted says the same thing as the screen…
    expect(stored.result!.rawScore, 71);
    // …and a batch built from it summarises the same number.
    final batch = LocalBatch(
      id: 'b',
      batchCode: 'B',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: '',
      expectedCount: 5,
      status: 'Active',
      createdByUid: 'u',
      createdByName: 'o',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      scans: [stored],
    );
    expect(batch.averagePercentage, closeTo(71 / 72 * 100, 1e-9));
    expect(batch.needsReview, isFalse, reason: 'the flagged answer was reviewed');

    // Reopening (a fresh viewer from the saved scan) shows the same total.
    final reopened = scoreOmrResult(stored.effectiveDecoded, fx.key);
    expect(computeExamScoreForCode(reopened)!.rawScore, stored.result!.rawScore);
  });

  test('TAT totals follow the exam rule (Test I x2, II/III correct-wrong) and max is 160', () {
    final tpl = omrTemplates['TAT']!;
    final items = <OmrItemResult>[];
    final key = <String, String>{};
    for (final s in tpl.sections) {
      for (final n in (s.items.keys.toList()..sort())) {
        final c = [for (final b in s.items[n]!) b.choice];
        key[AnswerKey.keyFor(s.name, n)] = c.first;
        items.add(OmrItemResult(sectionName: s.name, itemNumber: n, markedChoice: c.first));
      }
    }
    final scored = scoreOmrResult(
      OmrScanResult(examCode: 'TAT', items: items),
      AnswerKey(examCode: 'TAT', correctChoices: key),
    );
    final score = computeExamScoreForCode(scored)!;
    expect(score.maxScore, 160);
    expect(score.rawScore, 160);
  });
}
