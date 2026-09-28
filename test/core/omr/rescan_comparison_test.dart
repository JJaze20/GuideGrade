import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/exam_score.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/omr/rescan_comparison.dart';
import 'package:guidegrade/core/omr/scan_rescoring.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// A full sheet for [examCode] in which every item is marked with its first
/// choice, plus the answer key that makes each of those right.
({List<OmrItemResult> items, AnswerKey key, List<(String, int)> order}) _fullSheet(String examCode) {
  final tpl = omrTemplates[examCode]!;
  final items = <OmrItemResult>[];
  final key = <String, String>{};
  final order = <(String, int)>[];
  for (final s in tpl.sections) {
    for (final n in (s.items.keys.toList()..sort())) {
      final choice = s.items[n]!.first.choice;
      key[AnswerKey.keyFor(s.name, n)] = choice;
      items.add(OmrItemResult(sectionName: s.name, itemNumber: n, markedChoice: choice));
      order.add((s.name, n));
    }
  }
  return (items: items, key: AnswerKey(examCode: examCode, correctChoices: key), order: order);
}

OmrScanResult _with(
  List<OmrItemResult> base,
  String examCode,
  Map<(String, int), OmrItemResult Function(OmrItemResult)> edits,
) =>
    OmrScanResult(
      examCode: examCode,
      items: [
        for (final i in base)
          edits[(i.sectionName, i.itemNumber)]?.call(i) ?? i,
      ],
    );

OmrItemResult _blank(OmrItemResult i) =>
    OmrItemResult(sectionName: i.sectionName, itemNumber: i.itemNumber, markedChoice: null);
OmrItemResult _multi(OmrItemResult i) =>
    OmrItemResult(sectionName: i.sectionName, itemNumber: i.itemNumber, markedChoice: null, isAmbiguous: true);
OmrItemResult _pick(String c, OmrItemResult i) =>
    OmrItemResult(sectionName: i.sectionName, itemNumber: i.itemNumber, markedChoice: c);

LocalScan _scan(String examCode, OmrScanResult decoded, {List<AnswerCorrection> corrections = const []}) => LocalScan(
      id: 's1',
      imageFileName: 'images/s1.enc',
      capturedAt: DateTime.utc(2026, 9, 1),
      decoded: decoded,
      corrections: corrections,
    );

AnswerCorrection _correction(String section, int item, CorrectedAnswer to, CorrectedAnswer original) =>
    AnswerCorrection(
      id: 'c-$section-$item',
      scanId: 's1',
      sectionName: section,
      itemNumber: item,
      captureRevision: 0,
      action: CorrectionAction.set,
      original: original,
      corrected: to,
      correctedAt: DateTime.utc(2026, 9, 2),
    );

void main() {
  group('AT / QTM', () {
    test('lists exactly the items that differ, including blank and multiple-mark states', () {
      final fx = _fullSheet('AT');
      final s0 = fx.order[0];
      final s1 = fx.order[1];
      final s2 = fx.order[2];
      final original = _scan('AT', OmrScanResult(examCode: 'AT', items: fx.items));
      final candidate = _with(fx.items, 'AT', {
        s0: _blank,
        s1: _multi,
        s2: (i) => _pick(i.markedChoice == 'A' ? 'B' : 'A', i),
      });

      final cmp = RescanComparison.build(original: original, candidate: candidate, answerKey: fx.key);

      expect(cmp.changedCount, 3);
      expect(cmp.comparedItems, fx.items.length);
      final byKey = {for (final c in cmp.changes) '${c.sectionName}|${c.itemNumber}': c};
      expect(byKey['${s0.$1}|${s0.$2}']!.proposed.kind, AnswerStateKind.blank);
      expect(byKey['${s1.$1}|${s1.$2}']!.proposed.kind, AnswerStateKind.multiple);
      expect(byKey['${s1.$1}|${s1.$2}']!.proposed.label, 'Multiple marks');
      expect(byKey['${s2.$1}|${s2.$2}']!.proposed.kind, AnswerStateKind.choice);
      // Reports the key and whether each side is right.
      final c0 = byKey['${s0.$1}|${s0.$2}']!;
      expect(c0.keyChoice, isNotNull);
      expect(c0.originalCorrect, isTrue);
      expect(c0.proposedCorrect, isFalse);
    });

    test('identical answers produce no changes and no score difference', () {
      final fx = _fullSheet('QTM');
      final original = _scan('QTM', OmrScanResult(examCode: 'QTM', items: fx.items));
      final cmp = RescanComparison.build(
        original: original,
        candidate: OmrScanResult(examCode: 'QTM', items: fx.items),
        answerKey: fx.key,
      );
      expect(cmp.changes, isEmpty);
      expect(cmp.scoreDelta, 0);
    });

    test('many changed answers are reported, never rejected: the comparison has no verdict', () {
      final fx = _fullSheet('AT');
      final original = _scan('AT', OmrScanResult(examCode: 'AT', items: fx.items));
      final candidate = OmrScanResult(examCode: 'AT', items: [for (final i in fx.items) _blank(i)]);
      final cmp = RescanComparison.build(original: original, candidate: candidate, answerKey: fx.key);
      expect(cmp.changedCount, fx.items.length);
      expect(cmp.proposedScore!.rawScore, 0);
      expect(cmp.originalScore!.rawScore, fx.items.length);
      expect(cmp.scoreDelta, -fx.items.length);
    });

    test('no answer key: nothing is graded, delta is null, changes are still listed', () {
      final fx = _fullSheet('AT');
      final original = _scan('AT', OmrScanResult(examCode: 'AT', items: fx.items));
      final candidate = _with(fx.items, 'AT', {fx.order[0]: _blank});
      final cmp = RescanComparison.build(original: original, candidate: candidate, answerKey: null);
      expect(cmp.originalScore!.isGraded, isFalse);
      expect(cmp.scoreDelta, isNull);
      expect(cmp.changedCount, 1);
      expect(cmp.changes.single.keyChoice, isNull);
      expect(cmp.changes.single.originalCorrect, isNull);
    });
  });

  group('TAT section numbering', () {
    test('items are matched by section AND number, so Test I Q1 and Test II Q1 never collide', () {
      final fx = _fullSheet('TAT');
      final sections = omrTemplates['TAT']!.sections.map((s) => s.name).toList();
      expect(sections.length, greaterThanOrEqualTo(3));
      final firstNums = [for (final s in omrTemplates['TAT']!.sections) (s.items.keys.toList()..sort()).first];
      // Item numbering restarts in each test.
      expect(firstNums.toSet().length, 1, reason: 'each TAT section restarts numbering');
      final n = firstNums.first;

      final original = _scan('TAT', OmrScanResult(examCode: 'TAT', items: fx.items));
      // Change Q<n> in Test I and Test III only; Test II's Q<n> stays the same.
      final candidate = _with(fx.items, 'TAT', {
        (sections[0], n): _blank,
        (sections[2], n): _multi,
      });

      final cmp = RescanComparison.build(original: original, candidate: candidate, answerKey: fx.key);

      expect(cmp.changedCount, 2);
      expect(cmp.changes.map((c) => c.sectionName).toSet(), {sections[0], sections[2]});
      expect(cmp.changes.every((c) => c.itemNumber == n), isTrue);
      expect(cmp.changes.any((c) => c.sectionName == sections[1]), isFalse);
    });

    test('scores use the TAT rule: Test I x2, Tests II/III max(0, correct - wrong), max 160', () {
      final fx = _fullSheet('TAT');
      final sections = omrTemplates['TAT']!.sections.map((s) => s.name).toList();
      final n = (omrTemplates['TAT']!.sections.first.items.keys.toList()..sort()).first;
      final original = _scan('TAT', OmrScanResult(examCode: 'TAT', items: fx.items));
      // One Test I item blank: -2 points.
      final candidate = _with(fx.items, 'TAT', {(sections[0], n): _blank});

      final cmp = RescanComparison.build(original: original, candidate: candidate, answerKey: fx.key);

      expect(cmp.originalScore!.isTat, isTrue);
      expect(cmp.originalScore!.maxScore, 160);
      expect(cmp.originalScore!.rawScore, 160);
      expect(cmp.proposedScore!.rawScore, 158);
      expect(cmp.proposedScore!.tatTest1Score, cmp.originalScore!.tatTest1Score! - 2);
      expect(cmp.proposedScore!.tatTest2Score, cmp.originalScore!.tatTest2Score);
      expect(cmp.scoreDelta, -2);
    });
  });

  group('manual corrections', () {
    test('the original is scored as it reads today (corrections applied); the replacement is not', () {
      final fx = _fullSheet('AT');
      final target = fx.order[0];
      final rightChoice = fx.key.choiceFor(target.$1, target.$2)!;
      // Scanner read the item wrong; a reviewer corrected it to the key's answer.
      final detected = _with(fx.items, 'AT', {target: (i) => _pick(rightChoice == 'A' ? 'B' : 'A', i)});
      final original = _scan(
        'AT',
        detected,
        corrections: [
          _correction(
            target.$1,
            target.$2,
            CorrectedAnswer.choice(rightChoice),
            CorrectedAnswer.choice(rightChoice == 'A' ? 'B' : 'A'),
          ),
        ],
      );
      // The new photo reads that item as the scanner would (wrong) and nothing else differs.
      final candidate = OmrScanResult(examCode: 'AT', items: detected.items);

      final cmp = RescanComparison.build(original: original, candidate: candidate, answerKey: fx.key);

      expect(cmp.originalScore!.rawScore, fx.items.length, reason: 'original counts the correction');
      expect(cmp.proposedScore!.rawScore, fx.items.length - 1, reason: 'replacement has no corrections');
      expect(cmp.correctionsThatWillStopApplying, 1);
      expect(cmp.changedCount, 1);
      expect(cmp.changes.single.originalWasCorrected, isTrue);
      expect(cmp.changes.single.original.choice, rightChoice, reason: 'compares the CORRECTED value');
    });

    test('a sheet with no corrections reports none', () {
      final fx = _fullSheet('AT');
      final original = _scan('AT', OmrScanResult(examCode: 'AT', items: fx.items));
      final cmp = RescanComparison.build(
        original: original,
        candidate: OmrScanResult(examCode: 'AT', items: fx.items),
        answerKey: fx.key,
      );
      expect(cmp.correctionsThatWillStopApplying, 0);
    });
  });

  group('the proposed score is exactly what will be saved', () {
    for (final code in ['AT', 'QTM', 'TAT']) {
      test('$code: proposed score == the result the save path builds', () {
        final fx = _fullSheet(code);
        final candidate = _with(fx.items, code, {fx.order[0]: _blank, fx.order[3]: _multi});
        final original = _scan(code, OmrScanResult(examCode: code, items: fx.items));

        final cmp = RescanComparison.build(original: original, candidate: candidate, answerKey: fx.key);

        // finishRescan: scoreOmrResult -> computeExamScoreForCode -> buildLocalScanResult.
        final scored = scoreOmrResult(candidate, fx.key);
        final saved = buildLocalScanResult(
          scored,
          computeExamScoreForCode(scored),
          processedByUid: 'u',
          processedByName: 'n',
        );
        expect(cmp.proposedScore!.rawScore, saved.rawScore);
        expect(cmp.proposedScore!.totalItems, saved.totalItems);
      });
    }
  });
}
