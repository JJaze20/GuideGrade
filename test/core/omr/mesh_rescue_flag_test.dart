import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/core/omr/scan_quality_gate.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// The decode path itself can't be unit-tested here (it needs OpenCV), so the
/// mesh-rescue flag is exercised at the model layer instead: the decoder sets
/// `OmrScanResult.meshRescued`, and everything downstream — persistence,
/// corrections, scoring — must carry it without silently dropping it. That
/// drop is exactly the failure mode these tests exist to catch: a rescued
/// sheet that stops being flagged looks identical to one that needed no
/// rescue at all.
///
/// The review surfaces built on it (LocalScan.needsReview, the batch chips
/// and banner) are covered in test/models/needs_review_test.dart.
OmrItemResult _item(int n, {String? marked, bool ambiguous = false}) =>
    OmrItemResult(
      sectionName: 'Test I',
      itemNumber: n,
      markedChoice: marked,
      isAmbiguous: ambiguous,
    );

OmrScanResult _sheet(
  List<OmrItemResult> items, {
  bool meshRescued = false,
  String? meshVerdict,
}) =>
    OmrScanResult(
      examCode: 'TAT',
      items: items,
      meshVerdict: meshVerdict,
      meshRescued: meshRescued,
    );

/// A clean sheet: every item answered, geometry fine.
OmrScanResult _goodSheet({
  int n = 20,
  bool meshRescued = false,
  String? meshVerdict = 'meshApplied',
}) =>
    _sheet(
      [for (var i = 1; i <= n; i++) _item(i, marked: 'A')],
      meshRescued: meshRescued,
      meshVerdict: meshVerdict,
    );

AnswerCorrection _set(int item, CorrectedAnswer to) => AnswerCorrection(
      id: 'c$item',
      scanId: 's1',
      sectionName: 'Test I',
      itemNumber: item,
      captureRevision: 0,
      action: CorrectionAction.set,
      original: const CorrectedAnswer.blank(),
      corrected: to,
      correctedAt: DateTime.utc(2026, 1, 2),
    );

void main() {
  group('OmrScanResult.meshRescued', () {
    test('defaults to false and is omitted from JSON when false', () {
      final sheet = _goodSheet();
      expect(sheet.meshRescued, isFalse);
      // Additive: a sheet that needed no rescue serializes exactly as it did
      // before this field existed.
      expect(sheet.toJson().containsKey('meshRescued'), isFalse);
    });

    test('is written when true and survives a JSON round-trip', () {
      final original = _goodSheet(meshRescued: true);
      expect(original.toJson()['meshRescued'], isTrue);
      final restored = OmrScanResult.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      expect(restored.meshRescued, isTrue);
      // The rest of the record is unchanged by the added field.
      expect(restored.examCode, original.examCode);
      expect(restored.meshVerdict, original.meshVerdict);
      expect(restored.items.length, original.items.length);
    });

    test('an older record with no such key reads as false', () {
      final json = _goodSheet().toJson()..remove('meshRescued');
      expect(OmrScanResult.fromJson(json).meshRescued, isFalse);
    });
  });

  group('CorrectionRules.effective', () {
    test('carries meshRescued through — a correction never un-flags the sheet',
        () {
      final decoded = _goodSheet(meshRescued: true);
      final effective =
          CorrectionRules.effective(decoded, [_set(1, const CorrectedAnswer.choice('B'))], 0);
      expect(effective, isNot(same(decoded)));
      expect(effective.items.first.markedChoice, 'B');
      expect(effective.meshRescued, isTrue);
    });

    test('does not invent the flag on a sheet that was never rescued', () {
      final effective = CorrectionRules.effective(
        _goodSheet(),
        [_set(1, const CorrectedAnswer.choice('B'))],
        0,
      );
      expect(effective.meshRescued, isFalse);
    });
  });

  group('downstream carriers', () {
    test('scoreOmrResult carries meshRescued onto ScoredResult', () {
      expect(
          scoreOmrResult(_goodSheet(meshRescued: true), null).meshRescued, isTrue);
      expect(scoreOmrResult(_goodSheet(), null).meshRescued, isFalse);
    });

    test('ScanQualityGate is unaffected by the flag', () {
      // A rescued sheet whose corrected decode is clean passes the advisory
      // gate exactly as the same sheet would without the flag — the rescue
      // check belongs to the decoder, not the gate.
      expect(ScanQualityGate.inspect(_goodSheet(meshRescued: true), 1).passed,
          isTrue);
      expect(ScanQualityGate.inspect(_goodSheet(), 1).passed, isTrue);
    });
  });
}
