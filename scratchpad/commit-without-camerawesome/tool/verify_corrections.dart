// Pure-Dart verification of manual answer corrections, student details, the
// derived batch lifecycle, the archive coordinator and the cloud `manual`
// block. Runs with plain `dart tool/verify_corrections.dart` (no Flutter, no
// OpenCV) and exits non-zero on the first failed group.
//
// Everything here goes through the app's REAL code: the exam templates, the
// unchanged scorer (`scoreOmrResult` / `computeExamScoreForCode`), the
// correction rules, the model JSON, the lifecycle rules and the coordinator.

import 'dart:convert';

import '../lib/core/batch/batch_lifecycle.dart';
import '../lib/core/omr/exam_score.dart';
import '../lib/core/omr/omr_scorer.dart';
import '../lib/core/omr/omr_templates.dart';
import '../lib/core/omr/scan_rescoring.dart';
import '../lib/core/sync/batch_archive_coordinator.dart';
import '../lib/core/sync/scan_cloud_extensions.dart';
import '../lib/models/answer_correction.dart';
import '../lib/models/answer_key.dart';
import '../lib/models/local_batch.dart';
import '../lib/models/omr_scan_result.dart';

int _failures = 0;
int _checks = 0;

void check(bool ok, String what) {
  _checks++;
  if (!ok) {
    _failures++;
    print('  FAIL: $what');
  }
}

void group(String name, void Function() body) {
  print(name);
  body();
}

Future<void> groupAsync(String name, Future<void> Function() body) async {
  print(name);
  await body();
}

// --- fixtures ---------------------------------------------------------------

/// A key answering every item of [examCode]'s template with the FIRST choice
/// (or the second for the items listed in [second], keyed "section|n").
AnswerKey keyFor(String examCode) {
  final t = omrTemplates[examCode]!;
  final map = <String, String>{};
  for (final s in t.sections) {
    for (final e in s.items.entries) {
      map[AnswerKey.keyFor(s.name, e.key)] = e.value.first.choice;
    }
  }
  return AnswerKey(examCode: examCode, correctChoices: map);
}

/// Decoded sheet: every item marked with [mark] (choice, or null = blank).
OmrScanResult decodedWith(
  String examCode,
  String? Function(String section, int item, String keyChoice, String otherChoice) mark, {
  bool Function(String section, int item)? ambiguous,
}) {
  final t = omrTemplates[examCode]!;
  final items = <OmrItemResult>[];
  for (final s in t.sections) {
    for (final e in s.items.entries) {
      final choices = e.value.map((b) => b.choice).toList();
      final m = mark(s.name, e.key, choices.first, choices.length > 1 ? choices[1] : choices.first);
      final amb = ambiguous?.call(s.name, e.key) ?? false;
      items.add(OmrItemResult(
        sectionName: s.name,
        itemNumber: e.key,
        markedChoice: amb ? null : m,
        isAmbiguous: amb,
      ));
    }
  }
  return OmrScanResult(
    examCode: examCode,
    items: items,
    templateVersion: t.templateVersion,
  );
}

LocalScan scanOf(OmrScanResult decoded, {int revision = 0, List<AnswerCorrection> corrections = const []}) =>
    LocalScan(
      id: 's1',
      imageFileName: 'images/s1.enc',
      capturedAt: DateTime.utc(2026, 5, 1),
      decoded: decoded,
      captureRevision: revision,
      corrections: corrections,
    );

OmrItemResult item(OmrScanResult d, String section, int n) =>
    d.items.firstWhere((i) => i.sectionName == section && i.itemNumber == n);

List<AnswerCorrection> correct(
  LocalScan scan,
  String section,
  int n,
  CorrectedAnswer value, {
  String id = 'c1',
  String? reason,
  DateTime? at,
}) =>
    CorrectionRules.withCorrection(
      scan.corrections,
      id: id,
      scanId: scan.id,
      captureRevision: scan.captureRevision,
      detected: item(scan.decoded, section, n),
      value: value,
      reason: reason,
      editorUid: 'u1',
      editorName: 'Officer',
      at: at ?? DateTime.utc(2026, 5, 2),
    );

LocalScan withHistory(LocalScan s, List<AnswerCorrection> h) =>
    scanOf(s.decoded, revision: s.captureRevision, corrections: h);

int rawOf(LocalScan s, AnswerKey k) => scoreOmrResult(s.effectiveDecoded, k).rawScore;

LocalBatch batchOf({
  String code = 'B-1',
  String exam = 'AT',
  int expected = 10,
  String status = 'Active',
  DateTime? updatedAt,
  String id = 'b1',
}) =>
    LocalBatch(
      id: id,
      batchCode: code,
      examCode: exam,
      examTitle: 'x',
      description: '',
      expectedCount: expected,
      status: status,
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: DateTime.utc(2026),
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
      scans: const [],
    );

Future<void> main() async {
  // 1 -----------------------------------------------------------------------
  group('1. wrong -> correct answer recalculates the score', () {
    final key = keyFor('AT');
    // Every item marked with the SECOND choice = all wrong.
    final decoded = decodedWith('AT', (s, n, k, o) => o);
    var scan = scanOf(decoded);
    check(rawOf(scan, key) == 0, 'all-wrong sheet scores 0');

    final h = correct(scan, 'Section 1', 3, CorrectedAnswer.choice(keyOf(key, 'Section 1', 3)));
    scan = withHistory(scan, h);
    check(rawOf(scan, key) == 1, 'one corrected answer scores 1');
    check(item(scan.effectiveDecoded, 'Section 1', 3).markedChoice == keyOf(key, 'Section 1', 3),
        'effective answer is the corrected choice');
    check(item(scan.decoded, 'Section 1', 3).markedChoice != keyOf(key, 'Section 1', 3),
        'detected answer is preserved untouched');
    check(scan.corrections.single.original.choice == item(decoded, 'Section 1', 3).markedChoice,
        'correction records the original machine-detected value');
    check(scan.corrections.single.corrected.choice == keyOf(key, 'Section 1', 3), 'and the corrected value');
    check(scan.corrections.single.editorUid == 'u1' && scan.corrections.single.correctedAt.year == 2026,
        'and editor + timestamp');

    final scored = scoreOmrResult(scan.effectiveDecoded, key);
    final it = scored.items.firstWhere((i) => i.sectionName == 'Section 1' && i.itemNumber == 3);
    check(it.isCorrect == true, 'item now grades correct (green/check)');
    final before = scoreOmrResult(decoded, key).items.firstWhere((i) => i.sectionName == 'Section 1' && i.itemNumber == 3);
    check(before.isCorrect == false, 'and was wrong (red/X) before');
  });

  // 2 -----------------------------------------------------------------------
  group('2. blank and multiple-mark corrections', () {
    final key = keyFor('AT');
    final decoded = decodedWith('AT', (s, n, k, o) => k); // all correct
    var scan = scanOf(decoded);
    check(rawOf(scan, key) == 72, 'all-correct AT sheet scores 72');

    scan = withHistory(scan, correct(scan, 'Section 1', 1, const CorrectedAnswer.blank(), id: 'a'));
    check(rawOf(scan, key) == 71, 'correcting to blank removes the point');
    check(item(scan.effectiveDecoded, 'Section 1', 1).markedChoice == null &&
            !item(scan.effectiveDecoded, 'Section 1', 1).isAmbiguous,
        'blank reads as no mark');

    scan = withHistory(scan, correct(scan, 'Section 1', 2, const CorrectedAnswer.multiple(), id: 'b'));
    check(rawOf(scan, key) == 70, 'multiple marks never score');
    check(item(scan.effectiveDecoded, 'Section 1', 2).isAmbiguous, 'multiple reads as ambiguous');

    // blank -> real answer again on a previously blank sheet item
    final blankSheet = scanOf(decodedWith('AT', (s, n, k, o) => null));
    final fixed = withHistory(blankSheet, correct(blankSheet, 'Section 2', 14, CorrectedAnswer.choice(keyOf(key, 'Section 2', 14))));
    check(rawOf(fixed, key) == 1, 'blank -> answer scores');
  });

  // 3 -----------------------------------------------------------------------
  group('3. TAT numbering is per section and penalties still apply', () {
    final key = keyFor('TAT');
    // Test I: all correct (30 -> 60). Test II: items 1-10 right, 11-15 wrong,
    // rest blank. Test III: blank.
    final decoded = decodedWith('TAT', (s, n, k, o) {
      if (s == 'Test I') return k;
      if (s == 'Test II') return n <= 10 ? k : (n <= 15 ? o : null);
      return null;
    });
    var scan = scanOf(decoded);
    ExamScore score(LocalScan s) => computeExamScoreForCode(scoreOmrResult(s.effectiveDecoded, key))!;
    check(score(scan).tatTest1Score == 60, 'Test I = 30 x 2 = 60');
    check(score(scan).tatTest2Correct == 10 && score(scan).tatTest2Wrong == 5 && score(scan).tatTest2Score == 5,
        'Test II = max(0, 10 - 5) = 5');
    check(score(scan).tatTotal == 65, 'total 65');

    // Item 12 exists in Test II AND Test III... correct Test II item 12 only.
    scan = withHistory(scan, correct(scan, 'Test II', 12, CorrectedAnswer.choice(keyOf(key, 'Test II', 12))));
    check(score(scan).tatTest2Correct == 11 && score(scan).tatTest2Wrong == 4 && score(scan).tatTest2Score == 7,
        'Test II item 12 corrected: 11 right, 4 wrong -> 7');
    check(score(scan).tatTest1Score == 60, 'Test I is untouched');
    check(score(scan).tatTest3Correct == 0, 'Test III item 12 is NOT the corrected one');
    check(item(scan.effectiveDecoded, 'Test III', 12).markedChoice == null, 'same number in another section unchanged');

    // Test I item 12 is a different item from Test II item 12.
    final other = withHistory(scan, correct(scan, 'Test I', 12, const CorrectedAnswer.blank(), id: 'c2'));
    check(score(other).tatTest1Score == 58, 'correcting Test I item 12 to blank -> 29 x 2');
    check(score(other).tatTest2Correct == 11, 'and leaves Test II as it was');

    // Penalty floor: turn Test II into all wrong, score floors at 0.
    var allWrong = scanOf(decodedWith('TAT', (s, n, k, o) => s == 'Test II' ? o : null));
    check(score(allWrong).tatTest2Score == 0, 'penalties floor Test II at 0');
  });

  // 4 -----------------------------------------------------------------------
  group('4. reset to detected answer', () {
    final key = keyFor('AT');
    final decoded = decodedWith('AT', (s, n, k, o) => o);
    var scan = scanOf(decoded);
    scan = withHistory(scan, correct(scan, 'Section 1', 1, CorrectedAnswer.choice(keyOf(key, 'Section 1', 1)), id: 'a'));
    check(rawOf(scan, key) == 1, 'corrected');
    final reset = CorrectionRules.withReset(
      scan.corrections,
      id: 'r1',
      scanId: 's1',
      captureRevision: 0,
      detected: item(decoded, 'Section 1', 1),
      editorUid: 'u1',
      at: DateTime.utc(2026, 5, 3),
    );
    scan = withHistory(scan, reset);
    check(rawOf(scan, key) == 0, 'reset restores the detected answer score');
    check(scan.corrections.length == 2, 'history keeps both the correction and the reset');
    check(scan.activeCorrections.isEmpty, 'nothing active after reset');
    check(item(scan.effectiveDecoded, 'Section 1', 1).markedChoice == item(decoded, 'Section 1', 1).markedChoice,
        'effective equals detected');
    final again = CorrectionRules.withReset(
      scan.corrections,
      id: 'r2',
      scanId: 's1',
      captureRevision: 0,
      detected: item(decoded, 'Section 1', 1),
      at: DateTime.utc(2026, 5, 4),
    );
    check(identical(again, scan.corrections), 'resetting an item with no correction is a no-op');
  });

  // 5 -----------------------------------------------------------------------
  group('5. repeated taps and retries are idempotent', () {
    final key = keyFor('AT');
    final decoded = decodedWith('AT', (s, n, k, o) => o);
    final scan = scanOf(decoded);
    final v = CorrectedAnswer.choice(keyOf(key, 'Section 1', 1));
    final once = correct(scan, 'Section 1', 1, v, id: 'same');
    final twiceSameId = CorrectionRules.withCorrection(
      once,
      id: 'same',
      scanId: 's1',
      captureRevision: 0,
      detected: item(decoded, 'Section 1', 1),
      value: v,
      at: DateTime.utc(2026, 6, 1),
    );
    check(identical(once, twiceSameId), 'same request id twice -> unchanged');
    final twiceNewId = CorrectionRules.withCorrection(
      once,
      id: 'other',
      scanId: 's1',
      captureRevision: 0,
      detected: item(decoded, 'Section 1', 1),
      value: v,
      at: DateTime.utc(2026, 6, 1),
    );
    check(identical(once, twiceNewId), 'same value again (new id) -> unchanged');
    final backToOriginal = CorrectionRules.withCorrection(
      once,
      id: 'back',
      scanId: 's1',
      captureRevision: 0,
      detected: item(decoded, 'Section 1', 1),
      value: CorrectedAnswer.fromDetected(item(decoded, 'Section 1', 1)),
      at: DateTime.utc(2026, 6, 2),
    );
    check(backToOriginal.last.action == CorrectionAction.reset, 'setting it back to the detected value is recorded as a reset');
    check(CorrectionRules.activeFor(backToOriginal, 0).isEmpty, 'and leaves no active correction');
  });

  // 6 -----------------------------------------------------------------------
  group('6. rescans: older-capture corrections never apply silently', () {
    final key = keyFor('AT');
    final decoded = decodedWith('AT', (s, n, k, o) => o);
    var scan = scanOf(decoded);
    scan = withHistory(scan, correct(scan, 'Section 1', 1, CorrectedAnswer.choice(keyOf(key, 'Section 1', 1))));
    check(rawOf(scan, key) == 1, 'corrected on capture 0');

    // Rescan: new capture revision 1, same history carried over.
    final rescanned = scanOf(decoded, revision: 1, corrections: scan.corrections);
    check(rawOf(rescanned, key) == 0, 'old correction is not applied to the new capture');
    check(rescanned.activeCorrections.isEmpty, 'nothing active on the new capture');
    check(rescanned.corrections.length == 1, 'history is preserved');
    check(rescanned.correctionsNeedingReview.length == 1, 'the old correction is flagged for review');
    check(identical(rescanned.effectiveDecoded, rescanned.decoded), 'effective decode equals fresh detection');

    // Re-deciding the item on the new capture clears the review flag.
    final redecided = withHistory(rescanned, correct(rescanned, 'Section 1', 1, CorrectedAnswer.choice(keyOf(key, 'Section 1', 1)), id: 'c-new'));
    check(redecided.correctionsNeedingReview.isEmpty, 'deciding it again clears the review flag');
    check(rawOf(redecided, key) == 1, 'and applies to the new capture');
    check(redecided.corrections.first.captureRevision == 0 && redecided.corrections.last.captureRevision == 1,
        'each entry stays stamped with its own capture');
  });

  // 7 -----------------------------------------------------------------------
  group('7. history merge (offline edits, reconnects, duplicates, conflicts)', () {
    final key = keyFor('AT');
    final decoded = decodedWith('AT', (s, n, k, o) => o);
    final scan = scanOf(decoded);
    final a = correct(scan, 'Section 1', 1, CorrectedAnswer.choice(keyOf(key, 'Section 1', 1)), id: 'a', at: DateTime.utc(2026, 5, 2));
    final b = correct(scan, 'Section 1', 2, CorrectedAnswer.blank(), id: 'b', at: DateTime.utc(2026, 5, 3));
    final ab = CorrectionRules.merge(a, b);
    final ba = CorrectionRules.merge(b, a);
    check(ab.map((e) => e.id).join() == 'ab' && ba.map((e) => e.id).join() == 'ab', 'merge order does not matter');
    check(CorrectionRules.merge(ab, ab).length == 2, 'duplicate delivery adds nothing');
    // Same item corrected on two devices: the LATER entry wins, both are kept.
    final c = correct(scan, 'Section 1', 1, const CorrectedAnswer.multiple(), id: 'c', at: DateTime.utc(2026, 5, 4));
    final merged = CorrectionRules.merge(a, c);
    check(merged.length == 2, 'conflicting edits both kept in history');
    check(CorrectionRules.activeFor(merged, 0)['Section 1|1']!.id == 'c', 'later edit is the one in force');
  });

  // 8 -----------------------------------------------------------------------
  group('8. rescoreScan feeds corrections through the unchanged scorer', () {
    final key = keyFor('QTM');
    final decoded = decodedWith('QTM', (s, n, k, o) => o);
    var scan = scanOf(decoded);
    final base = LocalScanResult(
      rawScore: 0,
      totalGraded: 60,
      totalItems: 60,
      percentage: 0,
      status: 'Graded',
      scannedAt: DateTime.utc(2026, 5, 1, 9),
      processedByUid: 'scanner',
      processedByName: 'Scanner Person',
    );
    scan = LocalScan(
      id: 's1',
      imageFileName: 'i',
      capturedAt: scan.capturedAt,
      decoded: decoded,
      result: base,
    );
    scan = LocalScan(
      id: 's1',
      imageFileName: 'i',
      capturedAt: scan.capturedAt,
      decoded: decoded,
      result: base,
      corrections: correct(scan, 'Section 2', 15, CorrectedAnswer.choice(keyOf(key, 'Section 2', 15))),
    );
    final r = rescoreScan(scan: scan, answerKey: key, editorUid: 'editor', editorName: 'Editor')!;
    check(r.rawScore == 1 && r.totalGraded == 60, 'QTM raw score recalculated (1 of 60)');
    check(r.processedByUid == 'scanner' && r.scannedAt == base.scannedAt,
        'scanner identity and time kept (editor is on the correction)');
    check(rescoreScan(scan: scan, answerKey: null)!.rawScore == 0, 'no answer key -> stored result untouched');
  });

  // 9 -----------------------------------------------------------------------
  group('9. persistence round trip (restart) and old records', () {
    final key = keyFor('AT');
    final decoded = decodedWith('AT', (s, n, k, o) => o);
    var scan = scanOf(decoded);
    scan = scanOf(decoded,
        revision: 2,
        corrections: correct(scanOf(decoded, revision: 2), 'Section 1', 1,
            CorrectedAnswer.choice(keyOf(key, 'Section 1', 1)),
            reason: 'faint mark'));
    final json = jsonDecode(jsonEncode(scan.toJson())) as Map<String, dynamic>;
    final back = LocalScan.fromJson(json);
    check(back.captureRevision == 2, 'capture revision survives');
    check(back.corrections.length == 1 && back.corrections.single.reason == 'faint mark', 'history and reason survive');
    check(rawOf(back, key) == 1, 'effective reading survives');
    check(back.decoded.items.length == decoded.items.length &&
            item(back.decoded, 'Section 1', 1).markedChoice == item(decoded, 'Section 1', 1).markedChoice,
        'detected answers survive unchanged');

    final legacy = Map<String, dynamic>.from(json)
      ..remove('captureRevision')
      ..remove('corrections');
    final old = LocalScan.fromJson(legacy);
    check(old.captureRevision == 0 && old.corrections.isEmpty, 'record without the new keys loads with defaults');
    check(identical(old.effectiveDecoded, old.decoded), 'and reads exactly as detected');
    final plain = scanOf(decoded).toJson();
    check(!plain.containsKey('corrections') && !plain.containsKey('captureRevision'),
        'a never-corrected scan serialises exactly as before');
  });

  // 10 ----------------------------------------------------------------------
  group('10. student details: birth date, age, last school', () {
    final exam = DateTime(2026, 6, 15);
    check(ExamineeInfo.ageFromBirthDate(DateTime(2010, 6, 15), exam) == 16, 'birthday on exam day counts');
    check(ExamineeInfo.ageFromBirthDate(DateTime(2010, 6, 16), exam) == 15, 'day before birthday: still 15');
    check(ExamineeInfo.ageFromBirthDate(DateTime(2027, 1, 1), exam) == null, 'birth date after exam: no age');

    const noBirth = ExamineeInfo(firstName: 'A', lastName: 'B', examineeNumber: '1', manualAge: 17);
    check(noBirth.ageOn(exam) == 17, 'age-only entry is used as typed');
    final withBirth = noBirth.copyWith(birthDate: DateTime(2010, 6, 15));
    check(withBirth.ageOn(exam) == 16, 'a birth date takes over (derived, never contradictory)');
    check(!withBirth.toJson().containsKey('manualAge'), 'stored record never holds both');
    final conflicting = ExamineeInfo.fromJson({
      'firstName': 'A', 'lastName': 'B', 'examineeNumber': '1',
      'birthDate': '2010-06-15', 'manualAge': 40,
    });
    check(conflicting.manualAge == null && conflicting.ageOn(exam) == 16, 'a conflicting stored age loses to the birth date');

    check(ExamineeInfo.validateBirthDate(DateTime(2999, 1, 1), exam) != null, 'future birth date rejected');
    check(ExamineeInfo.validateBirthDate(DateTime(1900, 1, 1), exam) != null, 'implausible age rejected');
    check(ExamineeInfo.validateBirthDate(DateTime(2010, 6, 15), exam) == null, 'normal birth date accepted');
    check(ExamineeInfo.validateBirthDate(null, exam) == null, 'blank birth date accepted');
    check(ExamineeInfo.validateAge('2') != null && ExamineeInfo.validateAge('101') != null, 'out-of-range ages rejected');
    check(ExamineeInfo.validateAge('abc') != null, 'non-numeric age rejected');
    check(ExamineeInfo.validateAge('') == null && ExamineeInfo.validateAge('17') == null, 'blank and valid ages accepted');

    check(ExamineeInfo.examDateFor(scanCapturedAt: DateTime(2026, 3, 1), batchCreatedAt: DateTime(2026, 2, 1)) == DateTime(2026, 3, 1),
        'exam date = scan capture date');
    check(ExamineeInfo.examDateFor(batchCreatedAt: DateTime(2026, 2, 1)) == DateTime(2026, 2, 1),
        'fallback: batch creation date');

    final full = ExamineeInfo(
      firstName: 'A', lastName: 'B', examineeNumber: '1',
      birthDate: DateTime(2010, 6, 15), lastSchool: 'NDMU High',
    );
    final rt = ExamineeInfo.fromJson(jsonDecode(jsonEncode(full.toJson())) as Map<String, dynamic>);
    check(rt.birthDate == DateTime(2010, 6, 15) && rt.lastSchool == 'NDMU High', 'details persist');

    final old = ExamineeInfo.fromJson({'firstName': 'A', 'lastName': 'B', 'examineeNumber': '1'});
    check(old.birthDate == null && old.manualAge == null && old.lastSchool == '', 'older record loads with empty details');
    check(!old.toJson().containsKey('birthDate') && !old.toJson().containsKey('lastSchool'),
        'and writes back without new keys (format unchanged)');
    check(old.isComplete, 'trio-complete stays complete');
    check(const ExamineeInfo(firstName: '', lastName: '', examineeNumber: '', lastSchool: 'X').isEmpty == false,
        'details-only examinee is not empty');
  });

  // 11 ----------------------------------------------------------------------
  group('11. batch lifecycle rules', () {
    List<BatchProblem> p({String code = 'B-1', String exam = 'AT', int n = 5}) =>
        BatchLifecycle.problems(batchCode: code, examCode: exam, expectedCount: n);
    check(p().isEmpty && BatchLifecycle.statusAfterSave(p()) == 'Active', 'complete batch -> Active');
    check(p(n: 0).isNotEmpty && BatchLifecycle.statusAfterSave(p(n: 0)) == 'Draft', 'no expected count -> Draft');
    check(p(code: '  ').isNotEmpty, 'blank code -> Draft');
    check(p(exam: 'XYZ').isNotEmpty, 'unknown exam -> Draft');
    check(p().isEmpty, 'description and student tags are optional (not required fields)');

    final t0 = DateTime.utc(2026, 1, 1, 12);
    bool conf({bool cloud = true, DateTime? updated, DateTime? pushed, int jobs = 0}) =>
        BatchLifecycle.isCloudConfirmed(
          cloudConfigured: cloud,
          updatedAt: updated ?? t0,
          lastPushedUpdatedAt: pushed,
          outstandingJobs: jobs,
        );
    check(!conf(pushed: null), 'nothing pushed yet -> not confirmed');
    check(conf(pushed: t0), 'pushed this revision, nothing outstanding -> confirmed');
    check(!conf(pushed: t0, jobs: 1), 'queued/started/partial/failed job outstanding -> not confirmed');
    check(!conf(pushed: t0.subtract(const Duration(seconds: 1))), 'ack for an OLDER revision -> not confirmed');
    check(!conf(cloud: false, pushed: t0), 'no cloud configured -> never confirmed');
    check(conf(pushed: t0.add(const Duration(seconds: 1))), 'a later push also covers this revision');

    final same = BatchLifecycle.nextRevision(t0, t0);
    check(same.isAfter(t0), 'revision strictly increases within one clock tick');
    check(BatchLifecycle.nextRevision(t0, t0.subtract(const Duration(hours: 1))).isAfter(t0), 'and if the clock steps back');
    check(BatchLifecycle.nextRevision(t0, t0.add(const Duration(hours: 1))) == t0.add(const Duration(hours: 1)), 'wall clock used when ahead');
  });

  // 12 ----------------------------------------------------------------------
  await groupAsync('12. archive coordinator: Draft -> Active -> Archived', () async {
    final t0 = DateTime.utc(2026, 1, 1, 12);
    final store = <String, LocalBatch>{
      'b1': batchOf(id: 'b1', updatedAt: t0),
      'draft': batchOf(id: 'draft', expected: 0, status: 'Draft', updatedAt: t0),
      'busy': batchOf(id: 'busy', updatedAt: t0),
      'stale': batchOf(id: 'stale', updatedAt: t0),
    };
    final jobs = <String, int>{'busy': 2};
    final pushed = <String, DateTime?>{
      'b1': t0,
      'draft': t0,
      'busy': t0,
      'stale': t0.subtract(const Duration(minutes: 5)),
    };
    var casCalls = 0;
    BatchArchiveCoordinator make({bool cloud = true}) => BatchArchiveCoordinator(
          cloudConfigured: cloud,
          loadBatches: () async => store.values.toList(),
          outstandingJobsFor: (id) => jobs[id] ?? 0,
          lastPushedUpdatedAt: (id) => pushed[id],
          confirmArchived: (id, rev) async {
            casCalls++;
            final b = store[id]!;
            if (b.isArchived || b.updatedAt != rev) return false; // compare-and-set
            store[id] = b.copyWith(status: 'Archived');
            return true;
          },
        );

    check((await make(cloud: false).evaluateAll()).isEmpty && casCalls == 0, 'no cloud -> nothing archived');
    final archived = await make().evaluateAll();
    check(archived.length == 1 && archived.single == 'b1', 'only the confirmed complete batch archives');
    check(store['draft']!.status == 'Draft', 'incomplete batch stays Draft even if pushed');
    check(store['busy']!.status == 'Active', 'outstanding/failed/partial uploads keep it Active');
    check(store['stale']!.status == 'Active', 'ack for an older revision keeps it Active');

    // Edit an archived batch: re-evaluated (Active), not archived again until
    // its NEW revision is pushed.
    store['b1'] = store['b1']!.copyWith(status: 'Active', updatedAt: t0.add(const Duration(minutes: 1)));
    check((await make().evaluateAll()).isEmpty && store['b1']!.status == 'Active',
        'edited archived batch waits for its new revision');
    pushed['b1'] = t0.add(const Duration(minutes: 1));
    check((await make().evaluateAll()).contains('b1') && store['b1']!.isArchived, 'then archives once that revision syncs');

    // Delayed ack race: coordinator captured the OLD revision, batch edited
    // before the compare-and-set runs.
    store['b2'] = batchOf(id: 'b2', updatedAt: t0);
    pushed['b2'] = t0;
    final raced = BatchArchiveCoordinator(
      cloudConfigured: true,
      loadBatches: () async => [store['b2']!],
      outstandingJobsFor: (_) => 0,
      lastPushedUpdatedAt: (id) => pushed[id],
      confirmArchived: (id, rev) async {
        // The user saves an edit between the check and the write.
        store[id] = store[id]!.copyWith(updatedAt: t0.add(const Duration(seconds: 30)));
        final b = store[id]!;
        if (b.isArchived || b.updatedAt != rev) return false;
        store[id] = b.copyWith(status: 'Archived');
        return true;
      },
    );
    check((await raced.evaluateAll()).isEmpty && store['b2']!.status == 'Active',
        'a delayed acknowledgement can not archive newer changes');
  });

  // 13 ----------------------------------------------------------------------
  group('13. cloud `manual` block: round trip, union merge, old rows', () {
    final key = keyFor('AT');
    final decoded = decodedWith('AT', (s, n, k, o) => o);
    final base = scanOf(decoded);
    final h1 = correct(base, 'Section 1', 1, CorrectedAnswer.choice(keyOf(key, 'Section 1', 1)), id: 'dev1', at: DateTime.utc(2026, 5, 2));
    final scan = LocalScan(
      id: 's1',
      imageFileName: 'i',
      capturedAt: base.capturedAt,
      decoded: decoded,
      captureRevision: 1,
      corrections: h1.map((c) => c).toList(),
      examinee: ExamineeInfo(
        firstName: '', lastName: '', examineeNumber: '',
        birthDate: DateTime(2010, 6, 15), lastSchool: 'NDMU High',
      ),
    );
    final cloud = ScanCloudExtensions.decodedForCloud(scan);
    check(OmrScanResult.fromJson(cloud).items.length == decoded.items.length, 'detected block still parses as before');
    final parsed = ScanCloudExtensions.parse(jsonDecode(jsonEncode(cloud)) as Map<String, dynamic>);
    check(parsed.captureRevision == 1 && parsed.corrections.length == 1, 'revision and corrections round-trip');
    check(parsed.details?.birthDate == DateTime(2010, 6, 15) && parsed.details?.lastSchool == 'NDMU High', 'details round-trip');

    // Another device recorded a different correction: pushing must keep it.
    final other = CorrectionRules.withCorrection(
      const [],
      id: 'dev2',
      scanId: 's1',
      captureRevision: 1,
      detected: item(decoded, 'Section 1', 2),
      value: const CorrectedAnswer.blank(),
      at: DateTime.utc(2026, 5, 3),
    );
    final cloudWithOther = ScanCloudExtensions.decodedForCloud(
      LocalScan(id: 's1', imageFileName: 'i', capturedAt: base.capturedAt, decoded: decoded, captureRevision: 1, corrections: other),
    );
    final pushed = ScanCloudExtensions.decodedForCloud(scan, cloudDecoded: jsonDecode(jsonEncode(cloudWithOther)) as Map<String, dynamic>);
    final ids = ScanCloudExtensions.parse(pushed).corrections.map((c) => c.id).toSet();
    check(ids.containsAll({'dev1', 'dev2'}), 'push keeps the other device\'s entries');
    final twice = ScanCloudExtensions.decodedForCloud(scan, cloudDecoded: jsonDecode(jsonEncode(pushed)) as Map<String, dynamic>);
    check(ScanCloudExtensions.parse(twice).corrections.length == 2, 'delivering the same push twice changes nothing');

    final plain = scanOf(decoded);
    check(!ScanCloudExtensions.decodedForCloud(plain).containsKey('manual'), 'nothing to add -> row format unchanged');
    final oldRow = ScanCloudExtensions.parse(plain.decoded.toJson());
    check(oldRow.corrections.isEmpty && oldRow.captureRevision == 0 && oldRow.details == null, 'old cloud rows parse as empty');
  });

  print('');
  print('$_checks checks, $_failures failed');
  if (_failures > 0) {
    throw Exception('$_failures verification check(s) failed');
  }
  print('OK');
}

String keyOf(AnswerKey key, String section, int n) => key.choiceFor(section, n)!;
