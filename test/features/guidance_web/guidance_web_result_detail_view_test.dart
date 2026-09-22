import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_result_detail_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/examinee_record.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// Phase 3 — Detailed Result view.
///
/// Covers the pure helpers ([answerOutcomeFor], [groupScoredItemsBySection])
/// directly (no widget harness needed, matching the project's established
/// pattern of testing shared pure logic on its own), plus a handful of
/// widget-level tests for the behaviors that only exist once everything is
/// wired together: the stored headline result never drifts, a missing
/// answer key or a null examinee never crashes the page, and TAT's multiple
/// sections render grouped.
class _FakeSyncClient implements SyncClient {
  CloudAnswerKeyRead answerKeyToReturn = const CloudAnswerKeyRead.absent();
  CloudImageRead rectifiedImageToReturn = const CloudImageRead.absent();
  CloudImageRead originalImageToReturn = const CloudImageRead.absent();
  final List<String> imageCalls = [];

  Never _no(String label) => throw StateError('must never call $label');

  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async => answerKeyToReturn;

  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) async {
    imageCalls.add(rectified ? 'rectified' : 'original');
    return rectified ? rectifiedImageToReturn : originalImageToReturn;
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() => _no('readCloudBatches');
  @override
  Future<CloudScansRead> readCloudScans(String batchId) => _no('readCloudScans');
  @override
  Future<SyncOutcome> pushBatch(String batchId) => _no('pushBatch');
  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId, {Map<String, String> meta = const {}}) =>
      _no('pushScan');
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _no('uploadImage');
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) => _no('patchImageStatus');
  @override
  Future<SyncOutcome> pushAnswerKey(String examCode, {Map<String, String> meta = const {}}) =>
      _no('pushAnswerKey');
  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
  @override
  Future<CloudExamineesRead> readCloudExaminees() => _no('readCloudExaminees');
  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no('createExamineeFromScan');
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no('updateCloudExaminee');
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) => _no('setExamineeArchived');
  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) =>
      _no('linkScanToExaminee');
  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) =>
      _no('unlinkScanFromExaminee');

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async =>
      CloudBatchArchivesRead.found(const []);

  @override
  Future<SyncOutcome> archiveBatch({
    required String batchId,
    String? reason,
  }) =>
      _no('archiveBatch');

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) =>
      _no('readScanCounts');

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) =>
      _no('readCloudScansForExaminee');
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no('readUnlinkedScans');
}

LocalBatch _batch({String examCode = 'AT', String examTitle = 'Admission Test'}) => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: examCode,
      examTitle: examTitle,
      description: '',
      expectedCount: 1,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

LocalScan _scan({
  String examCode = 'AT',
  ExamineeInfo? examinee,
  LocalScanResult? result,
  List<OmrItemResult> items = const [],
  String? rectifiedImageFileName,
  Map<String, (double, double)>? meshInteriorMeasuredFrac,
}) =>
    LocalScan(
      id: 's1',
      imageFileName: 'images/s1.enc',
      rectifiedImageFileName: rectifiedImageFileName,
      capturedAt: DateTime.utc(2026, 1, 1, 15, 30),
      decoded: OmrScanResult(
        examCode: examCode,
        items: items,
        meshInteriorMeasuredFrac: meshInteriorMeasuredFrac,
      ),
      result: result,
      examinee: examinee,
    );

/// A canonical examinees row as the Examinee Records page holds it.
ExamineeRecord _canonical({
  String temporaryId = 'EX-000004',
  String firstName = 'Merch',
  String? middleName = 'Valdez',
  String lastName = 'Andulana',
}) =>
    ExamineeRecord(
      id: 'fa445fcc-a59e-4b58-86ae-0ddac56138ac',
      temporaryExamineeId: temporaryId,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      status: 'active',
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid',
    );

void main() {
  group('answerOutcomeFor (pure)', () {
    test('9. a blank marked answer on a graded item is incorrect, never invented as correct', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: null, isAmbiguous: false, correctChoice: 'A');
      expect(answerOutcomeFor(item), AnswerOutcome.incorrect);
    });

    test('10. an ambiguous mark is its own outcome, never mislabeled as a normal incorrect answer', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: true, correctChoice: 'A');
      expect(answerOutcomeFor(item), AnswerOutcome.ambiguous);
    });

    test('a matching, unambiguous mark is correct', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: false, correctChoice: 'A');
      expect(answerOutcomeFor(item), AnswerOutcome.correct);
    });

    test('a non-matching, unambiguous mark is incorrect', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'B', isAmbiguous: false, correctChoice: 'A');
      expect(answerOutcomeFor(item), AnswerOutcome.incorrect);
    });

    test('no correct choice at all (missing/non-covering answer key) is "not graded", never "incorrect"', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: false, correctChoice: null);
      expect(answerOutcomeFor(item), AnswerOutcome.notGraded);
    });
  });

  group('groupScoredItemsBySection (pure)', () {
    test('4/5. AT/QTM-style single-section items stay in one group', () {
      const items = [
        ScoredItem(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A', isAmbiguous: false, correctChoice: 'A'),
        ScoredItem(sectionName: 'Answer Document', itemNumber: 2, markedChoice: 'B', isAmbiguous: false, correctChoice: 'C'),
      ];
      final grouped = groupScoredItemsBySection(items);
      expect(grouped.keys.toList(), ['Answer Document']);
      expect(grouped['Answer Document'], hasLength(2));
    });

    test('6. TAT-style multi-section items are grouped and ordered Test I, Test II, Test III', () {
      const items = [
        ScoredItem(sectionName: 'Test I', itemNumber: 1, markedChoice: 'A', isAmbiguous: false, correctChoice: 'A'),
        ScoredItem(sectionName: 'Test II', itemNumber: 1, markedChoice: 'T', isAmbiguous: false, correctChoice: 'F'),
        ScoredItem(sectionName: 'Test III', itemNumber: 1, markedChoice: null, isAmbiguous: false, correctChoice: 'T'),
        ScoredItem(sectionName: 'Test I', itemNumber: 2, markedChoice: 'B', isAmbiguous: false, correctChoice: 'B'),
      ];
      final grouped = groupScoredItemsBySection(items);
      expect(grouped.keys.toList(), ['Test I', 'Test II', 'Test III']);
      expect(grouped['Test I'], hasLength(2));
      expect(grouped['Test II'], hasLength(1));
      expect(grouped['Test III'], hasLength(1));
    });
  });

  group('planOverlayForItem (pure — mirrors mobile _GradedOverlayPainter)', () {
    const bubbles = [
      BubblePos('A', 0.10, 0.20),
      BubblePos('B', 0.20, 0.20),
    ];

    test('4. no correct choice at all (missing answer key) -> no plan, no overlay', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: false, correctChoice: null);
      expect(planOverlayForItem(item, bubbles), isNull);
    });

    test('an item whose choices are not in the template -> no plan (null/empty bubbles)', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: false, correctChoice: 'A');
      expect(planOverlayForItem(item, null), isNull);
      expect(planOverlayForItem(item, const []), isNull);
    });

    test('6. a correct mark gets a green marked-answer ring and a green badge', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: false, correctChoice: 'A');
      final plan = planOverlayForItem(item, bubbles)!;
      expect(plan.markedBubble?.choice, 'A');
      expect(plan.markedColor, WebOverlayColors.correct);
      expect(plan.keyBubble, isNull); // already correct -- no key ring needed
      expect(plan.badgeColor, WebOverlayColors.correct);
      expect(plan.badgeIsCorrect, isTrue);
    });

    test('7. a wrong mark gets a red marked-answer ring', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'B', isAmbiguous: false, correctChoice: 'A');
      final plan = planOverlayForItem(item, bubbles)!;
      expect(plan.markedBubble?.choice, 'B');
      expect(plan.markedColor, WebOverlayColors.wrong);
    });

    test('8. that same wrong mark ALSO gets a yellow key ring on the correct bubble', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'B', isAmbiguous: false, correctChoice: 'A');
      final plan = planOverlayForItem(item, bubbles)!;
      expect(plan.keyBubble?.choice, 'A');
    });

    test('9. an ambiguous mark gets a yellow badge', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: true, correctChoice: 'A');
      final plan = planOverlayForItem(item, bubbles)!;
      expect(plan.badgeColor, WebOverlayColors.ambiguous);
      expect(plan.badgeIsCorrect, isFalse); // isAmbiguous forces isCorrect false
    });

    test('10. that ambiguous mark is NOT drawn as a yellow ring merely for being ambiguous -- '
        'its ring is red like any other wrong mark, and since the marked/correct bubble '
        'coincide, no separate key ring is drawn either', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: 'A', isAmbiguous: true, correctChoice: 'A');
      final plan = planOverlayForItem(item, bubbles)!;
      expect(plan.markedColor, WebOverlayColors.wrong);
      expect(plan.markedColor, isNot(WebOverlayColors.ambiguous));
      expect(plan.keyBubble, isNull);
    });

    test('11. a blank answer with a known correct choice gets only a yellow key ring, no marked ring', () {
      const item = ScoredItem(sectionName: 'S', itemNumber: 1, markedChoice: null, isAmbiguous: false, correctChoice: 'A');
      final plan = planOverlayForItem(item, bubbles)!;
      expect(plan.markedBubble, isNull);
      expect(plan.markedColor, isNull);
      expect(plan.keyBubble?.choice, 'A');
      expect(plan.badgeColor, WebOverlayColors.wrong); // blank, not ambiguous
    });
  });

  group('correctedBubbleCenter (pure — mirrors mobile mesh-corrected centerOf)', () {
    test('with no mesh data at all, the corrected center equals the plain pre-mesh fraction mapping', () {
      final template = omrTemplates['AT']!;
      const bubble = BubblePos('A', 0.10751, 0.20668); // AT item 1, choice A
      const size = Size(800, 1000);

      final corrected = correctedBubbleCenter(
        bubble: bubble,
        template: template,
        meshInteriorMeasuredFrac: null,
        size: size,
      );

      expect(corrected.dx, closeTo(bubble.xFrac * size.width, 0.001));
      expect(corrected.dy, closeTo(bubble.yFrac * size.height, 0.001));
    });

    test('a template with no interior fiducials at all (TAT) is never mesh-corrected, '
        'even if measured fractions are (incorrectly) supplied', () {
      final template = omrTemplates['TAT']!;
      const bubble = BubblePos('A', 0.06838, 0.30392); // TAT Test I item 1, choice A
      const size = Size(936, 612);

      final corrected = correctedBubbleCenter(
        bubble: bubble,
        template: template,
        meshInteriorMeasuredFrac: const {'centerAboveAnswers': (0.9, 0.9)}, // nonsense, must be ignored
        size: size,
      );

      expect(corrected.dx, closeTo(bubble.xFrac * size.width, 0.001));
      expect(corrected.dy, closeTo(bubble.yFrac * size.height, 0.001));
    });

    test('a genuine, non-coherent measured deviation at the interior fiducials shifts the '
        'corrected center away from the plain fraction mapping -- confirming the mesh is '
        'actually wired in, not silently ignored', () {
      final template = omrTemplates['AT']!;
      const bubble = BubblePos('A', 0.10751, 0.20668); // AT item 1 -- inside a top-pentagon
      // triangle that always includes centerAboveAnswers as a vertex.
      const size = Size(595, 842); // ~1 logical px per PDF point, easy to reason about.

      // Displace the 3 vertical-centerline interior fiducials by different,
      // non-coherent amounts/directions -- comfortably inside the trusted
      // residual range, but nowhere near "planar" (would no-op) or a
      // uniform "likely mismatched corner" shift (would also not apply).
      final meshFrac = {
        'centerAboveAnswers': (0.45357 + 10 / template.pageWidthPt, 0.22568),
        'centerAtDivider': (0.45357, 0.59034 - 10 / template.pageHeightPt),
        'centerBelowAnswers': (0.45357 + 8 / template.pageWidthPt, 0.94312 + 8 / template.pageHeightPt),
      };

      final plain = Offset(bubble.xFrac * size.width, bubble.yFrac * size.height);
      final corrected = correctedBubbleCenter(
        bubble: bubble,
        template: template,
        meshInteriorMeasuredFrac: meshFrac,
        size: size,
      );

      expect((corrected - plain).distance, greaterThan(0.5));
    });
  });

  group('resolveWebExamineeIdentity (pure)', () {
    // The scan as the mobile app pushed it: generated number, blank names.
    final autoTaggedScan = _scan(
      examinee: const ExamineeInfo(firstName: '', lastName: '', examineeNumber: 'EX-1790006562335-3'),
    );

    test('1. linked scan + canonical names -> the canonical Examinee ID and names', () {
      final id = resolveWebExamineeIdentity(scan: autoTaggedScan, linkedExaminee: _canonical());
      expect(id.fromCanonicalExaminee, isTrue);
      expect(id.examineeId, 'EX-000004');
      expect(id.firstName, 'Merch');
      expect(id.middleName, 'Valdez');
      expect(id.lastName, 'Andulana');
    });

    test("2. linked scan + blank canonical names -> falls back to the scan's own tag", () {
      final scan = _scan(
        examinee: const ExamineeInfo(firstName: 'Juan', lastName: 'Cruz', examineeNumber: 'EX-9'),
      );
      final id = resolveWebExamineeIdentity(
        scan: scan,
        linkedExaminee: _canonical(firstName: '', middleName: null, lastName: ''),
      );
      expect(id.fromCanonicalExaminee, isFalse);
      expect(id.examineeId, 'EX-9');
      expect(id.firstName, 'Juan');
      expect(id.lastName, 'Cruz');
      expect(id.scanId, isNull, reason: 'nothing to keep separate when the scan is the only source');
    });

    test('3. unlinked / legacy scan (no linked examinee) -> the scan tag, unchanged', () {
      final scan = _scan(
        examinee: const ExamineeInfo(firstName: 'Ana', middleName: 'Reyes', lastName: 'Lim', examineeNumber: 'OLD-7'),
      );
      final id = resolveWebExamineeIdentity(scan: scan);
      expect(id.fromCanonicalExaminee, isFalse);
      expect(id.examineeId, 'OLD-7');
      expect(id.firstName, 'Ana');
      expect(id.middleName, 'Reyes');
      expect(id.lastName, 'Lim');
    });

    test('4. no usable canonical or scan identity -> every field null (the card shows its dash)', () {
      final id = resolveWebExamineeIdentity(
        scan: _scan(examinee: null),
        linkedExaminee: _canonical(firstName: '  ', middleName: null, lastName: ''),
      );
      expect(id.fromCanonicalExaminee, isFalse);
      expect(id.examineeId, isNull);
      expect(id.firstName, isNull);
      expect(id.middleName, isNull);
      expect(id.lastName, isNull);
    });

    test("5. the scan's own number stays separate from the canonical Examinee ID", () {
      final id = resolveWebExamineeIdentity(scan: autoTaggedScan, linkedExaminee: _canonical());
      expect(id.examineeId, 'EX-000004');
      expect(id.scanId, 'EX-1790006562335-3');
      expect(id.examineeId, isNot(id.scanId));
      // ...and the scan itself was not modified.
      expect(autoTaggedScan.examinee!.examineeNumber, 'EX-1790006562335-3');
      expect(autoTaggedScan.examinee!.firstName, '');
    });

    test('6. never mixes two sources: a canonical record with only a last name does not borrow the scan first name', () {
      final scan = _scan(
        examinee: const ExamineeInfo(firstName: 'Juan', lastName: 'Cruz', examineeNumber: 'EX-9'),
      );
      final id = resolveWebExamineeIdentity(
        scan: scan,
        linkedExaminee: _canonical(firstName: '', middleName: null, lastName: 'Andulana'),
      );
      expect(id.fromCanonicalExaminee, isTrue);
      expect(id.lastName, 'Andulana');
      expect(id.firstName, '', reason: "not the scan's 'Juan'");
    });
  });

  group('GuidanceWebResultDetailView (widget)', () {
    late _FakeSyncClient client;
    late GuidanceWebResultsService service;

    setUp(() {
      client = _FakeSyncClient();
      service = GuidanceWebResultsService(client: client);
    });

    Future<void> pump(
      WidgetTester tester, {
      required LocalScan scan,
      required LocalBatch batch,
      ExamineeRecord? linkedExaminee,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceWebResultDetailView(
              scan: scan,
              batch: batch,
              service: service,
              onBack: () {},
              linkedExaminee: linkedExaminee,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('3. the stored headline score/percentage/status are shown verbatim, '
        'never recalculated from the freshly-fetched (and here, disagreeing) answer key',
        (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 2,
        answers: {'Answer Document|1': 'Z', 'Answer Document|2': 'Z'}, // disagrees with every marked answer
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      final scan = _scan(
        examinee: const ExamineeInfo(firstName: 'Juan', lastName: 'Cruz', examineeNumber: 'EX-1'),
        result: LocalScanResult(
          rawScore: 60,
          totalGraded: 72,
          totalItems: 72,
          percentage: 83.33,
          status: 'Graded',
          scannedAt: DateTime.utc(2026, 1, 1),
          processedByUid: 'uid',
          processedByName: 'Officer',
        ),
        items: const [
          OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A'),
          OmrItemResult(sectionName: 'Answer Document', itemNumber: 2, markedChoice: 'B'),
        ],
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(find.text('60 / 72'), findsOneWidget);
      expect(find.text('83.33%'), findsOneWidget);
      expect(find.text('Graded'), findsOneWidget);
      // The recomputed-against-current-key result (0 correct) is never shown.
      expect(find.text('0 / 72'), findsNothing);
    });

    testWidgets('7. missing OCR name fields show a dash, never a fake placeholder', (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      final scan = _scan(
        examinee: const ExamineeInfo(firstName: '', middleName: '', lastName: 'Santos', examineeNumber: 'EX-2'),
        result: LocalScanResult(
          rawScore: 1,
          totalGraded: 1,
          totalItems: 1,
          percentage: 100,
          status: 'Graded',
          scannedAt: DateTime.utc(2026, 1, 1),
          processedByUid: 'uid',
          processedByName: 'Officer',
        ),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(find.text('EX-2'), findsOneWidget);
      expect(find.text('Santos'), findsOneWidget);
      expect(find.text('UNKNOWN'), findsNothing);
      expect(find.text('N/A'), findsNothing);
      // First Name and Middle Name both blank -> two dashes from this card.
      expect(find.text('—'), findsNWidgets(2));
    });

    testWidgets('8. scan.examinee == null does not crash and shows the result/answer data anyway',
        (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      final scan = _scan(
        examinee: null,
        result: LocalScanResult(
          rawScore: 1,
          totalGraded: 1,
          totalItems: 1,
          percentage: 100,
          status: 'Graded',
          scannedAt: DateTime.utc(2026, 1, 1),
          processedByUid: 'uid',
          processedByName: 'Officer',
        ),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(tester.takeException(), isNull);
      expect(find.text('Detailed Result'), findsOneWidget);
      expect(find.text('100.00%'), findsOneWidget);
      // Examinee ID / First / Middle / Last Name all blank -> four dashes.
      expect(find.text('—'), findsNWidgets(4));
    });

    Future<void> pumpIdentity(
      WidgetTester tester, {
      ExamineeInfo? scanTag,
      ExamineeRecord? linkedExaminee,
    }) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      final scan = _scan(
        examinee: scanTag,
        result: LocalScanResult(
          rawScore: 1,
          totalGraded: 1,
          totalItems: 1,
          percentage: 100,
          status: 'Graded',
          scannedAt: DateTime.utc(2026, 1, 1),
          processedByUid: 'uid',
          processedByName: 'Officer',
        ),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
      );
      await pump(tester, scan: scan, batch: _batch(), linkedExaminee: linkedExaminee);
    }

    testWidgets('a linked scan shows the canonical applicant, with the scan number as a separate Scan ID '
        '(the verified Merch / Valdez / Andulana example)', (tester) async {
      await pumpIdentity(
        tester,
        // What the database holds for that scan: blank names, generated number.
        scanTag: const ExamineeInfo(firstName: '', lastName: '', examineeNumber: 'EX-1790006562335-3'),
        linkedExaminee: _canonical(),
      );

      expect(find.text('Examinee ID'), findsOneWidget);
      expect(find.text('EX-000004'), findsOneWidget);
      expect(find.text('Merch'), findsOneWidget);
      expect(find.text('Valdez'), findsOneWidget);
      expect(find.text('Andulana'), findsOneWidget);
      expect(find.text('Scan ID'), findsOneWidget);
      expect(find.text('EX-1790006562335-3'), findsOneWidget);
      // Pure display: the fake client throws on any link/unlink/create/push, so an
      // exception here would mean this view tried to write something.
      expect(tester.takeException(), isNull);
    });

    testWidgets("a linked scan whose canonical record has no usable name falls back to the scan's own tag",
        (tester) async {
      await pumpIdentity(
        tester,
        scanTag: const ExamineeInfo(firstName: 'Juan', lastName: 'Cruz', examineeNumber: 'EX-9'),
        linkedExaminee: _canonical(firstName: '', middleName: null, lastName: ''),
      );

      expect(find.text('EX-9'), findsOneWidget);
      expect(find.text('Juan'), findsOneWidget);
      expect(find.text('Cruz'), findsOneWidget);
      expect(find.text('EX-000004'), findsNothing);
      expect(find.text('Scan ID'), findsNothing);
    });

    testWidgets('an unlinked/legacy scan keeps showing its own tag, with no Scan ID row', (tester) async {
      await pumpIdentity(
        tester,
        scanTag: const ExamineeInfo(firstName: 'Ana', middleName: 'Reyes', lastName: 'Lim', examineeNumber: 'OLD-7'),
      );

      expect(find.text('OLD-7'), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('Reyes'), findsOneWidget);
      expect(find.text('Lim'), findsOneWidget);
      expect(find.text('Scan ID'), findsNothing);
    });

    testWidgets('no usable canonical or scan identity keeps the existing dashes', (tester) async {
      await pumpIdentity(
        tester,
        scanTag: null,
        linkedExaminee: _canonical(firstName: '', middleName: null, lastName: ''),
      );

      expect(tester.takeException(), isNull);
      // Examinee ID / First / Middle / Last Name -> four dashes, no Scan ID row.
      expect(find.text('—'), findsNWidgets(4));
      expect(find.text('Scan ID'), findsNothing);
    });

    testWidgets('2. a missing answer key does not crash; marked answers are still shown, '
        'correctness is "Not graded"', (tester) async {
      client.answerKeyToReturn = const CloudAnswerKeyRead.absent();
      final scan = _scan(
        examinee: const ExamineeInfo(firstName: 'Juan', lastName: 'Cruz', examineeNumber: 'EX-3'),
        result: LocalScanResult(
          rawScore: 0,
          totalGraded: 0,
          totalItems: 2,
          percentage: 0,
          status: 'Ungraded',
          scannedAt: DateTime.utc(2026, 1, 1),
          processedByUid: 'uid',
          processedByName: 'Officer',
        ),
        items: const [
          OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A'),
          OmrItemResult(sectionName: 'Answer Document', itemNumber: 2, markedChoice: null),
        ],
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('No answer key is currently available'),
        findsOneWidget,
      );
      expect(find.text('Not graded'), findsNWidgets(2));
    });

    testWidgets('6b. a TAT result groups Answer Details by section (Test I / II / III)', (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Test I|1': 'A', 'Test II|1': 'T', 'Test III|1': 'T'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      final scan = _scan(
        examCode: 'TAT',
        examinee: const ExamineeInfo(firstName: 'Juan', lastName: 'Cruz', examineeNumber: 'EX-4'),
        result: LocalScanResult(
          rawScore: 3,
          totalGraded: 3,
          totalItems: 130,
          percentage: 0,
          status: 'Graded',
          scannedAt: DateTime.utc(2026, 1, 1),
          processedByUid: 'uid',
          processedByName: 'Officer',
        ),
        items: const [
          OmrItemResult(sectionName: 'Test I', itemNumber: 1, markedChoice: 'A'),
          OmrItemResult(sectionName: 'Test II', itemNumber: 1, markedChoice: 'T'),
          OmrItemResult(sectionName: 'Test III', itemNumber: 1, markedChoice: 'T'),
        ],
      );

      await pump(tester, scan: scan, batch: _batch(examCode: 'TAT', examTitle: 'Teaching Aptitude Test'));

      expect(find.text('Test I'), findsOneWidget);
      expect(find.text('Test II'), findsOneWidget);
      expect(find.text('Test III'), findsOneWidget);
      // Headline stays the stored 3 / 160 (TAT denominator), not recomputed.
      expect(find.text('3 / 160'), findsOneWidget);
    });

    LocalScanResult gradedResult() => LocalScanResult(
          rawScore: 1,
          totalGraded: 1,
          totalItems: 1,
          percentage: 100,
          status: 'Graded',
          scannedAt: DateTime.utc(2026, 1, 1),
          processedByUid: 'uid',
          processedByName: 'Officer',
        );

    testWidgets('5. the rectified image is preferred when available; original is never even requested',
        (tester) async {
      client.rectifiedImageToReturn = CloudImageRead.found(_pngBytes);
      final scan = _scan(rectifiedImageFileName: 'images/s1_rectified.enc', result: gradedResult());

      await pump(tester, scan: scan, batch: _batch());

      expect(client.imageCalls, ['rectified']);
      expect(find.text('No scanned image available for this sheet.'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('6c. the original image is used when the rectified copy is absent', (tester) async {
      client.rectifiedImageToReturn = const CloudImageRead.absent();
      client.originalImageToReturn = CloudImageRead.found(_pngBytes);
      final scan = _scan(rectifiedImageFileName: 'images/s1_rectified.enc', result: gradedResult());

      await pump(tester, scan: scan, batch: _batch());

      expect(client.imageCalls, ['rectified', 'original']);
      expect(find.text('No scanned image available for this sheet.'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('7b. neither image exists -> a friendly empty state, never an exception', (tester) async {
      client.rectifiedImageToReturn = const CloudImageRead.absent();
      client.originalImageToReturn = const CloudImageRead.absent();
      final scan = _scan(rectifiedImageFileName: 'images/s1_rectified.enc', result: gradedResult());

      await pump(tester, scan: scan, batch: _batch());

      expect(tester.takeException(), isNull);
      expect(find.text('No scanned image available for this sheet.'), findsOneWidget);
    });

    testWidgets('8b. a missing image never prevents the rest of Detailed Result from rendering',
        (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      client.rectifiedImageToReturn = const CloudImageRead.absent();
      client.originalImageToReturn = const CloudImageRead.absent();
      final scan = _scan(
        examinee: const ExamineeInfo(firstName: 'Juan', lastName: 'Cruz', examineeNumber: 'EX-5'),
        result: gradedResult(),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(find.text('No scanned image available for this sheet.'), findsOneWidget);
      // Result Summary and Answer Details still rendered normally.
      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.text('100.00%'), findsOneWidget);
      expect(find.text('Correct'), findsOneWidget);
    });

    testWidgets('9. corrupted image bytes never crash the widget -- errorBuilder shows a friendly message',
        (tester) async {
      // Not a real image -- decoding must fail, but the errorBuilder must
      // catch it rather than letting it surface as an unhandled exception.
      client.originalImageToReturn = CloudImageRead.found([1, 2, 3, 4, 5]);
      final scan = _scan(result: gradedResult());

      await pump(tester, scan: scan, batch: _batch());

      expect(tester.takeException(), isNull);
      expect(find.text('Unable to display this scanned sheet.'), findsOneWidget);
    });

    testWidgets('10. the full image viewer opens on tap and closes via its close button',
        (tester) async {
      client.originalImageToReturn = CloudImageRead.found(_pngBytes);
      final scan = _scan(result: gradedResult());

      await pump(tester, scan: scan, batch: _batch());

      expect(find.byKey(const Key('scannedSheetPreview')), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('scannedSheetPreview')));
      await tester.tap(find.byKey(const Key('scannedSheetPreview')));
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.text('Detailed Result'), findsOneWidget);
    });

    testWidgets('1. a rectified image with a registered template gets the graded overlay',
        (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      client.rectifiedImageToReturn = CloudImageRead.found(_pngBytes);
      final scan = _scan(
        rectifiedImageFileName: 'images/s1_rectified.enc',
        result: gradedResult(),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(find.byKey(const Key('gradedOverlayPaint')), findsOneWidget);
    });

    testWidgets('1b. mesh-correction metadata on the scan flows through to the overlay '
        'without crashing (AT/QTM redesigned-sheet case)', (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      client.rectifiedImageToReturn = CloudImageRead.found(_pngBytes);
      final template = omrTemplates['AT']!;
      final scan = _scan(
        rectifiedImageFileName: 'images/s1_rectified.enc',
        result: gradedResult(),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
        meshInteriorMeasuredFrac: {
          'centerAboveAnswers': (0.45357 + 10 / template.pageWidthPt, 0.22568),
          'centerAtDivider': (0.45357, 0.59034 - 10 / template.pageHeightPt),
          'centerBelowAnswers': (0.45357 + 8 / template.pageWidthPt, 0.94312 + 8 / template.pageHeightPt),
        },
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('gradedOverlayPaint')), findsOneWidget);
    });

    testWidgets('2b. the original fallback (no rectified copy) never gets the overlay',
        (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      client.originalImageToReturn = CloudImageRead.found(_pngBytes);
      final scan = _scan(
        result: gradedResult(),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
      );

      await pump(tester, scan: scan, batch: _batch());

      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('gradedOverlayPaint')), findsNothing);
    });

    testWidgets('5b. a rectified image for an exam code with no registered template gets no overlay, no crash',
        (tester) async {
      client.rectifiedImageToReturn = CloudImageRead.found(_pngBytes);
      final scan = _scan(
        examCode: 'ZZZ',
        rectifiedImageFileName: 'images/s1_rectified.enc',
        result: gradedResult(),
      );

      await pump(tester, scan: scan, batch: _batch(examCode: 'ZZZ', examTitle: 'Unregistered Exam'));

      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const Key('gradedOverlayPaint')), findsNothing);
    });

    testWidgets('12. the full-screen viewer keeps the image and overlay inside the SAME InteractiveViewer',
        (tester) async {
      client.answerKeyToReturn = CloudAnswerKeyRead.found(
        version: 1,
        answers: {'Answer Document|1': 'A'},
        updatedByName: 'Officer',
        updatedAt: '2026-01-01T00:00:00Z',
      );
      client.rectifiedImageToReturn = CloudImageRead.found(_pngBytes);
      final scan = _scan(
        rectifiedImageFileName: 'images/s1_rectified.enc',
        result: gradedResult(),
        items: const [OmrItemResult(sectionName: 'Answer Document', itemNumber: 1, markedChoice: 'A')],
      );

      await pump(tester, scan: scan, batch: _batch());
      await tester.ensureVisible(find.byKey(const Key('scannedSheetPreview')));
      await tester.tap(find.byKey(const Key('scannedSheetPreview')));
      await tester.pumpAndSettle();

      final viewer = find.byType(InteractiveViewer);
      expect(viewer, findsOneWidget);
      expect(find.descendant(of: viewer, matching: find.byType(Image)), findsOneWidget);
      expect(
        find.descendant(of: viewer, matching: find.byKey(const Key('gradedOverlayPaint'))),
        findsOneWidget,
      );
    });
  });
}

/// A minimal, valid 1x1 transparent PNG -- small enough to inline, but a
/// real decodable image so `Image.memory` never hits its errorBuilder in
/// tests that aren't specifically about corrupted bytes.
final List<int> _pngBytes = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x64, 0x60, 0x60, 0x60,
  0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0x5E, 0xF8, 0x27, 0x93, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
  0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];
