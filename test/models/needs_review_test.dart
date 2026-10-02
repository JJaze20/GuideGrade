import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

OmrItemResult _item(int n, String? choice, {bool ambiguous = false}) => OmrItemResult(
      sectionName: 'Section 1',
      itemNumber: n,
      markedChoice: choice,
      isAmbiguous: ambiguous,
    );

LocalScan _scan(String id, List<OmrItemResult> items, {List<AnswerCorrection> corrections = const [], bool meshRescued = false}) =>
    LocalScan(
      id: id,
      imageFileName: 'images/$id.enc',
      capturedAt: DateTime.utc(2026, 9, 1),
      decoded: OmrScanResult(examCode: 'AT', items: items, meshRescued: meshRescued),
      corrections: corrections,
    );

AnswerCorrection _set(String scanId, int item, CorrectedAnswer to, {int revision = 0, String id = 'c'}) =>
    AnswerCorrection(
      id: id,
      scanId: scanId,
      sectionName: 'Section 1',
      itemNumber: item,
      captureRevision: revision,
      action: CorrectionAction.set,
      original: const CorrectedAnswer.multiple(),
      corrected: to,
      correctedAt: DateTime.utc(2026, 9, 2),
    );

LocalBatch _batch(List<LocalScan> scans) => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: '',
      expectedCount: 10,
      status: 'Active',
      createdByUid: 'u',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 1),
      scans: scans,
    );

void main() {
  group('needs-review warning', () {
    test('a scanner-flagged (ambiguous) answer flags the sheet and its batch', () {
      final flagged = _scan('s1', [_item(1, 'A'), _item(2, null, ambiguous: true)]);
      final clean = _scan('s2', [_item(1, 'A'), _item(2, 'B')]);
      final batch = _batch([flagged, clean]);

      expect(flagged.needsReview, isTrue);
      expect(flagged.unresolvedFlaggedItems.map((i) => i.itemNumber), [2]);
      expect(clean.needsReview, isFalse);
      expect(batch.needsReview, isTrue);
      expect(batch.needsReviewCount, 1);
      expect(batch.scansNeedingReview.map((s) => s.id), ['s1']);
    });

    test('incorrect, blank and unmarked answers alone never trigger it', () {
      // Wrong answers are a grading outcome, not scanner uncertainty: the
      // flag reads only the decoder's own "unclear mark" signal.
      final scan = _scan('s1', [_item(1, 'D'), _item(2, null), _item(3, 'C')]);
      final key = AnswerKey(examCode: 'AT', correctChoices: {
        AnswerKey.keyFor('Section 1', 1): 'A',
        AnswerKey.keyFor('Section 1', 2): 'B',
        AnswerKey.keyFor('Section 1', 3): 'A',
      });
      final scored = scoreOmrResult(scan.effectiveDecoded, key);

      expect(scored.items.where((i) => i.isCorrect == false), isNotEmpty);
      expect(scan.needsReview, isFalse);
      expect(_batch([scan]).needsReview, isFalse);
      expect(_batch([scan]).needsReviewCount, 0);
    });

    test('a mesh-rescued sheet flags the sheet and its batch with nothing '
        'flagged per-item', () {
      // The rescue admits a capture the pipeline would previously have
      // discarded, so it warrants a look even though every answer read
      // cleanly — there is no ambiguous item to count.
      final rescued = _scan('s1', [_item(1, 'A'), _item(2, 'B')], meshRescued: true);
      expect(rescued.unresolvedFlaggedItems, isEmpty);
      expect(rescued.needsReview, isTrue);
      expect(_batch([rescued]).needsReview, isTrue);
      expect(_batch([rescued]).needsReviewCount, 1);

      // And correcting an item cannot clear it: the rescue is a property of
      // the capture, not of any one answer.
      final corrected = _scan(
        's1',
        rescued.decoded.items,
        meshRescued: true,
        corrections: [_set('s1', 2, const CorrectedAnswer.choice('C'))],
      );
      expect(corrected.needsReview, isTrue);

      // An ordinary clean sheet still does not.
      expect(_scan('s2', [_item(1, 'A')]).needsReview, isFalse);
    });

    test('the rescue flag survives a scan persistence round-trip', () {
      final rescued = _scan('s1', [_item(1, 'A')], meshRescued: true);
      final restored = LocalScan.fromJson(
        jsonDecode(jsonEncode(rescued.toJson())) as Map<String, dynamic>,
      );
      expect(restored.decoded.meshRescued, isTrue);
      expect(restored.needsReview, isTrue);
    });

    test('reviewing the flagged answer resolves it, and the batch warning clears', () {
      final flagged = _scan('s1', [_item(1, 'A'), _item(2, null, ambiguous: true)]);
      expect(_batch([flagged]).needsReview, isTrue);

      final reviewed = _scan(
        's1',
        flagged.decoded.items,
        corrections: [_set('s1', 2, const CorrectedAnswer.choice('B'))],
      );
      expect(reviewed.needsReview, isFalse);
      expect(_batch([reviewed]).needsReview, isFalse);

      // Choosing "no answer" is a decision too.
      final blanked = _scan(
        's1',
        flagged.decoded.items,
        corrections: [_set('s1', 2, const CorrectedAnswer.blank())],
      );
      expect(blanked.needsReview, isFalse);
    });

    test('the count is per affected sheet and drops one sheet at a time', () {
      final a = _scan('a', [_item(1, null, ambiguous: true), _item(2, null, ambiguous: true)]);
      final b = _scan('b', [_item(1, null, ambiguous: true)]);
      final c = _scan('c', [_item(1, 'A')]);
      expect(_batch([a, b, c]).needsReviewCount, 2);
      expect(a.unresolvedFlaggedItems, hasLength(2));

      final aFixed = _scan('a', a.decoded.items, corrections: [
        _set('a', 1, const CorrectedAnswer.choice('A'), id: 'c1'),
        _set('a', 2, const CorrectedAnswer.choice('A'), id: 'c2'),
      ]);
      expect(_batch([aFixed, b, c]).needsReviewCount, 1);
    });

    test('deleting the only flagged sheet clears the batch warning', () {
      final flagged = _scan('s1', [_item(1, null, ambiguous: true)]);
      final clean = _scan('s2', [_item(1, 'A')]);
      final before = _batch([flagged, clean]);
      expect(before.needsReview, isTrue);

      final after = before.copyWith(scans: [clean]);
      expect(after.needsReview, isFalse);
      expect(after.needsReviewCount, 0);
    });

    test('a correction made on an earlier capture does not resolve a rescan\'s flag', () {
      // Rescan bumps captureRevision; the old correction stops applying, so the
      // new capture's flagged answer is unresolved again.
      final rescanned = LocalScan(
        id: 's1',
        imageFileName: 'images/s1.enc',
        capturedAt: DateTime.utc(2026, 9, 3),
        decoded: OmrScanResult(examCode: 'AT', items: [_item(1, null, ambiguous: true)]),
        captureRevision: 1,
        corrections: [_set('s1', 1, const CorrectedAnswer.choice('A'), revision: 0)],
      );
      expect(rescanned.needsReview, isTrue);
    });
  });
}
