import 'dart:convert';

import '../core/omr/duplicate_scan_detector.dart';
import 'answer_correction.dart';
import 'omr_scan_result.dart';

/// The student a scanned sheet belongs to. Attached per [LocalScan],
/// entered by staff on the results/review screen while looking at the
/// sheet's own handwritten-name crop (see [LocalScan.nameCropLastFileName]/
/// [nameCropFirstFileName]/[nameCropMiddleFileName] and
/// showExamineeDialog) — this app never attempts automatic handwriting
/// recognition; a scan's name is only ever set by a human typing it in.
///
/// [examineeNumber] is the identifying field results are keyed to for a
/// person; [firstName]/[lastName] are for human-readable lists and exports.
class ExamineeInfo {
  final String firstName;
  final String lastName;

  /// Optional — unlike [firstName]/[lastName], never required for
  /// [isComplete]. Many students go by initial only or don't have one.
  final String middleName;
  final String examineeNumber;

  /// Optional details entered by staff, never read off the sheet and never
  /// required — [isComplete] deliberately ignores all three so an untagged or
  /// name-only examinee still saves and scans exactly as before.
  ///
  /// Only date-only precision is kept: stored and compared as a calendar
  /// date, so a time zone can never shift the birth date by a day.
  final DateTime? birthDate;

  /// A hand-entered age, kept ONLY while [birthDate] is unknown. When a birth
  /// date exists the age is derived from it (see [ageOn]) and this is
  /// ignored, so the record can never hold two contradictory values.
  final int? manualAge;

  final String lastSchool;

  const ExamineeInfo({
    required this.firstName,
    required this.lastName,
    this.middleName = '',
    required this.examineeNumber,
    this.birthDate,
    this.manualAge,
    this.lastSchool = '',
  });

  /// Age in whole years on [examDate]: derived from [birthDate] when there
  /// is one, otherwise the hand-entered [manualAge] (as entered — it is not
  /// aged forward), otherwise null. Never guessed.
  ///
  /// The examination date is the day the sheet was scanned — see
  /// [examDateFor]. Null when the birth date is after [examDate] (invalid).
  int? ageOn(DateTime examDate) {
    final b = birthDate;
    if (b == null) return manualAge;
    return ageFromBirthDate(b, examDate);
  }

  /// Whole years between [birthDate] and [onDate], by calendar date (the
  /// birthday counts on the day itself). Null when [birthDate] is after
  /// [onDate].
  static int? ageFromBirthDate(DateTime birthDate, DateTime onDate) {
    final b = DateTime(birthDate.year, birthDate.month, birthDate.day);
    final d = DateTime(onDate.year, onDate.month, onDate.day);
    if (b.isAfter(d)) return null;
    var years = d.year - b.year;
    if (d.month < b.month || (d.month == b.month && d.day < b.day)) years--;
    return years;
  }

  /// The examination date used to derive age for [scan] within its batch:
  /// the scan's capture date; if a caller has no scan (a tag being entered
  /// before any capture time exists) the batch's creation date; and only if
  /// neither is known, today. Documented fallback order — nothing invents a
  /// date silently.
  static DateTime examDateFor({DateTime? scanCapturedAt, DateTime? batchCreatedAt, DateTime? now}) =>
      scanCapturedAt ?? batchCreatedAt ?? now ?? DateTime.now();

  /// Validation for a birth date entry: null when fine, otherwise a
  /// message for the field. [examDate] bounds it so a birth date can't be
  /// later than the examination it belongs to.
  static String? validateBirthDate(DateTime? birthDate, DateTime examDate, {DateTime? now}) {
    if (birthDate == null) return null;
    final today = now ?? DateTime.now();
    final b = DateTime(birthDate.year, birthDate.month, birthDate.day);
    if (b.isAfter(DateTime(today.year, today.month, today.day))) {
      return 'Birth date can’t be in the future.';
    }
    if (b.isAfter(DateTime(examDate.year, examDate.month, examDate.day))) {
      return 'Birth date can’t be after the examination date.';
    }
    if (ageFromBirthDate(b, examDate)! > maxAge) {
      return 'That birth date gives an age over $maxAge. Check the year.';
    }
    return null;
  }

  /// Validation for a hand-entered age (whole years). Null when fine.
  static String? validateAge(String? text) {
    final t = text?.trim() ?? '';
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null) return 'Enter the age as a whole number.';
    if (n < minAge || n > maxAge) return 'Enter an age from $minAge to $maxAge.';
    return null;
  }

  static const int minAge = 3;
  static const int maxAge = 100;

  /// "Last, First Middle" — the whole middle name, not an initial. Falls back to
  /// whichever of last/first is present, and omits the middle name entirely when
  /// [middleName] is blank.
  String get displayName {
    final last = lastName.trim();
    final first = firstName.trim();
    final middle = middleName.trim();
    final middleSuffix = middle.isEmpty ? '' : ' $middle';
    if (last.isNotEmpty && first.isNotEmpty) return '$last, $first$middleSuffix';
    if (last.isNotEmpty) return last;
    if (first.isNotEmpty) return '$first$middleSuffix';
    return 'Unnamed';
  }

  bool get isComplete =>
      firstName.trim().isNotEmpty &&
      lastName.trim().isNotEmpty &&
      examineeNumber.trim().isNotEmpty;

  bool get isEmpty =>
      firstName.trim().isEmpty &&
      lastName.trim().isEmpty &&
      middleName.trim().isEmpty &&
      examineeNumber.trim().isEmpty &&
      birthDate == null &&
      manualAge == null &&
      lastSchool.trim().isEmpty;

  /// Whether only the optional extras are present — no name and no number.
  bool get hasOnlyExtras =>
      firstName.trim().isEmpty &&
      lastName.trim().isEmpty &&
      middleName.trim().isEmpty &&
      examineeNumber.trim().isEmpty &&
      !isEmpty;

  ExamineeInfo copyWith({
    String? firstName,
    String? lastName,
    String? middleName,
    String? examineeNumber,
    DateTime? birthDate,
    int? manualAge,
    String? lastSchool,
    bool clearBirthDate = false,
    bool clearManualAge = false,
  }) =>
      ExamineeInfo(
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        middleName: middleName ?? this.middleName,
        examineeNumber: examineeNumber ?? this.examineeNumber,
        birthDate: clearBirthDate ? null : (birthDate ?? this.birthDate),
        manualAge: clearManualAge ? null : (manualAge ?? this.manualAge),
        lastSchool: lastSchool ?? this.lastSchool,
      );

  /// Additive JSON: the three extra keys are written only when present, so a
  /// record without them serializes exactly as it did before this existed,
  /// and [fromJson] accepts any older record.
  Map<String, dynamic> toJson() => {
        'firstName': firstName,
        'lastName': lastName,
        'middleName': middleName,
        'examineeNumber': examineeNumber,
        if (birthDate != null) 'birthDate': _dateOnly(birthDate!),
        // Only while the birth date is unknown — never both.
        if (birthDate == null && manualAge != null) 'manualAge': manualAge,
        if (lastSchool.trim().isNotEmpty) 'lastSchool': lastSchool,
      };

  factory ExamineeInfo.fromJson(Map<String, dynamic> json) {
    final bd = _parseDateOnly(json['birthDate'] as String?);
    return ExamineeInfo(
      firstName: json['firstName'] as String? ?? '',
      lastName: json['lastName'] as String? ?? '',
      middleName: json['middleName'] as String? ?? '',
      examineeNumber: json['examineeNumber'] as String? ?? '',
      birthDate: bd,
      // A stored age next to a birth date is ignored: the birth date wins.
      manualAge: bd == null ? json['manualAge'] as int? : null,
      lastSchool: json['lastSchool'] as String? ?? '',
    );
  }

  /// `YYYY-MM-DD` — a calendar date with no time or zone to shift.
  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime? _parseDateOnly(String? s) {
    if (s == null || s.isEmpty) return null;
    final parsed = DateTime.tryParse(s);
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// Public for the cloud mapper, which stores the same `YYYY-MM-DD` form.
  static String birthDateToText(DateTime d) => _dateOnly(d);
  static DateTime? birthDateFromText(String? s) => _parseDateOnly(s);
}

/// Local, on-device representation of a batch and everything it contains.
///
/// A [LocalBatch] is the central container connecting an exam type, its
/// scanned answer-sheet images, and the graded results for each of those
/// scans. It is deliberately shaped to mirror the Firestore [BatchModel]
/// (same identifying/audit fields) so a future cloud-backed
/// `BatchRepository` implementation can map one straight onto the other
/// without touching the scan or archive UI.
///
/// Persistence layout (see LocalBatchRepository):
/// `<appDocs>/guidegrade_batches/<id>/batch.json` and
/// `<appDocs>/guidegrade_batches/<id>/images/<scanId>.jpg`
class LocalBatch {
  final String id;
  final String batchCode; // e.g. B-202608-123 (human-facing, kept from Create Batch)
  final String examCode; // AT | QTM | TAT — the "exam type"
  final String examTitle; // denormalized from the exam catalog, for display
  final String description;
  final int expectedCount; // staff estimate of how many sheets to scan
  final String status; // 'Draft' | 'Active' | 'Completed' | 'Archived'
  final String createdByUid;
  final String createdByName;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Every scan captured under this batch, in capture order.
  final List<LocalScan> scans;

  const LocalBatch({
    required this.id,
    required this.batchCode,
    required this.examCode,
    required this.examTitle,
    required this.description,
    required this.expectedCount,
    required this.status,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
    this.scans = const [],
  });

  int get scanCount => scans.length;

  /// Whether [expectedCount] is enforced as a hard cap on how many scans
  /// this batch can hold. A batch with no estimate set (0, or negative from
  /// bad data) has no cap -- [expectedCount] used to be advisory-only, so
  /// this keeps that behavior for any batch that predates the scan-limit
  /// feature or was never given a real estimate.
  bool get hasScanLimit => expectedCount > 0;

  /// How many more scans this batch can accept right now, or null when
  /// [hasScanLimit] is false. Always derived from the live [scans] list
  /// (never a separately-tracked counter), so it's automatically correct
  /// after a reload, an app restart, a scan being added/replaced, or the
  /// batch being edited -- there's nothing else that needs to stay in sync.
  int? get remainingCapacity {
    if (!hasScanLimit) return null;
    final remaining = expectedCount - scanCount;
    return remaining < 0 ? 0 : remaining;
  }

  /// True once [scanCount] has reached [expectedCount], for a batch with a
  /// cap. Always false when [hasScanLimit] is false.
  bool get isFull => hasScanLimit && scanCount >= expectedCount;

  /// True once at least one scan in this batch has been graded.
  bool get resultsAvailable => scans.any((s) => s.result != null);

  int get gradedCount => scans.where((s) => s.result != null).length;

  /// Mean percentage across graded scans, or null when none are graded.
  double? get averagePercentage {
    final graded = scans.where((s) => s.result != null).toList();
    if (graded.isEmpty) return null;
    final sum = graded.fold<double>(0, (acc, s) => acc + s.result!.percentage);
    return sum / graded.length;
  }

  /// Scans that don't yet carry a complete examinee identity.
  int get untaggedScanCount =>
      scans.where((s) => s.examinee?.isComplete != true).length;

  /// Examinee numbers used by more than one scan in this batch (data-entry
  /// mistakes to flag). Blank numbers are ignored.
  Set<String> get duplicateExamineeNumbers {
    final seen = <String>{};
    final dupes = <String>{};
    for (final s in scans) {
      final n = s.examinee?.examineeNumber.trim() ?? '';
      if (n.isEmpty) continue;
      if (!seen.add(n)) dupes.add(n);
    }
    return dupes;
  }

  /// Pairs of already-saved scans whose decoded marks are nearly identical
  /// — a strong signal the same physical sheet was scanned twice into
  /// different slots (mistaken for an unscanned sheet in the physical
  /// stack, or picked up again after being set aside). Content-based, so it
  /// catches this independent of whether either sheet has been tagged yet
  /// — see [findDuplicateScanPairs]'s doc comment for the matching rule.
  /// Empty when there's nothing to flag.
  List<({LocalScan a, LocalScan b, double matchFraction})> get likelyDuplicateScans =>
      findDuplicateScanPairs(scans.map((s) => s.decoded).toList())
          .map((p) => (a: scans[p.indexA], b: scans[p.indexB], matchFraction: p.matchFraction))
          .toList();

  /// Scans the scanner flagged as unclear (double/stray marks) that nobody has
  /// resolved yet, in capture order. Derived from data already stored on each
  /// scan — no image is decoded. A wrong answer never lands here; only scanner
  /// uncertainty does. See [LocalScan.unresolvedFlaggedItems].
  List<LocalScan> get scansNeedingReview =>
      scans.where((s) => s.needsReview).toList();

  /// How many scans are in [scansNeedingReview]. Zero clears the batch's
  /// "Needs review" indicator.
  int get needsReviewCount => scans.where((s) => s.needsReview).length;

  bool get needsReview => scans.any((s) => s.needsReview);

  bool get isDraft => status == 'Draft';
  bool get isActive => status == 'Active';
  bool get isCompleted => status == 'Completed';
  bool get isArchived => status == 'Archived';

  /// A batch can still receive new scans while it's a working batch.
  /// Archived batches still accept scans: Archived only means the cloud has
  /// confirmed the latest saved revision, and a new scan simply moves the
  /// batch back to Active until that revision syncs (see BatchLifecycle).
  bool get canScan => status == 'Draft' || status == 'Active' || status == 'Archived';

  LocalBatch copyWith({
    String? batchCode,
    String? examCode,
    String? examTitle,
    String? description,
    int? expectedCount,
    String? status,
    DateTime? updatedAt,
    List<LocalScan>? scans,
  }) {
    return LocalBatch(
      id: id,
      batchCode: batchCode ?? this.batchCode,
      examCode: examCode ?? this.examCode,
      examTitle: examTitle ?? this.examTitle,
      description: description ?? this.description,
      expectedCount: expectedCount ?? this.expectedCount,
      status: status ?? this.status,
      createdByUid: createdByUid, // never overwritten
      createdByName: createdByName, // never overwritten
      createdAt: createdAt, // never overwritten
      updatedAt: updatedAt ?? this.updatedAt,
      scans: scans ?? this.scans,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'batchCode': batchCode,
        'examCode': examCode,
        'examTitle': examTitle,
        'description': description,
        'expectedCount': expectedCount,
        'status': status,
        'createdByUid': createdByUid,
        'createdByName': createdByName,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'scans': scans.map((s) => s.toJson()).toList(),
      };

  factory LocalBatch.fromJson(Map<String, dynamic> json) => LocalBatch(
        id: json['id'] as String,
        batchCode: json['batchCode'] as String,
        examCode: json['examCode'] as String,
        examTitle: json['examTitle'] as String? ?? '',
        description: json['description'] as String? ?? '',
        expectedCount: json['expectedCount'] as int? ?? 0,
        status: json['status'] as String? ?? 'Draft',
        createdByUid: json['createdByUid'] as String? ?? '',
        createdByName: json['createdByName'] as String? ?? 'Unknown',
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        scans: (json['scans'] as List<dynamic>? ?? [])
            .map((e) => LocalScan.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One scanned answer sheet inside a [LocalBatch]: the captured image plus
/// what the OMR decoder read off it, and — once graded — its result.
class LocalScan {
  /// Non-personal technical id, unique within the batch. Doubles as the
  /// image file's base name (`images/<id>.jpg`).
  final String id;

  /// Path to the stored image, relative to the batch directory
  /// (e.g. "images/s_1723552000000_0.jpg").
  final String imageFileName;

  /// Path to a perspective-corrected copy of [imageFileName], relative to
  /// the batch directory, used only to draw the per-item graded overlay in
  /// ScannedImageViewerScreen — null when none was produced (rectification
  /// failed for this sheet, or it predates this field). Purely display —
  /// [decoded] is never derived from this image.
  final String? rectifiedImageFileName;

  final DateTime capturedAt;

  /// What the decoder read off this sheet.
  final OmrScanResult decoded;

  /// Grading outcome for this sheet, or null if it was never graded
  /// (e.g. scanned without a Final answer key loaded).
  final LocalScanResult? result;

  /// Which student this sheet belongs to. Null until staff tag it (on the
  /// results or archive-detail screen).
  final ExamineeInfo? examinee;

  /// Paths to the cropped handwritten Last Name / First Name / MI field
  /// images, relative to the batch directory (e.g.
  /// "images/s_1723552000000_0_name_last.enc") — the evidence staff read
  /// while typing a name into showExamineeDialog. Null when cropping failed
  /// for this sheet, or the scan predates this field (older archived
  /// scans display normally with no crop shown).
  final String? nameCropLastFileName;
  final String? nameCropFirstFileName;
  final String? nameCropMiddleFileName;

  /// Which capture of this scan slot [decoded]/the stored images belong to:
  /// 0 for the first capture (and every scan saved before this field
  /// existed), +1 each time a rescan replaces the capture. Corrections are
  /// stamped with the revision they were made on and only ever apply to that
  /// capture — see [AnswerCorrection.captureRevision].
  final int captureRevision;

  /// When the photo currently stored for this sheet was taken by a rescan,
  /// or null if it is still the original capture. [capturedAt] never moves on
  /// a rescan — it is the sheet's original date — so this is the only record
  /// of when the replacement happened. Local only: there is no cloud column
  /// for it.
  final DateTime? rescannedAt;

  /// Append-only history of manual answer corrections and resets for this
  /// scan, oldest first, across every capture. [decoded] is never edited:
  /// the machine-detected answers and the scan image stay as captured, and
  /// [effectiveDecoded] is what a correction changes.
  final List<AnswerCorrection> corrections;

  const LocalScan({
    required this.id,
    required this.imageFileName,
    this.rectifiedImageFileName,
    required this.capturedAt,
    required this.decoded,
    this.result,
    this.examinee,
    this.nameCropLastFileName,
    this.nameCropFirstFileName,
    this.nameCropMiddleFileName,
    this.captureRevision = 0,
    this.rescannedAt,
    this.corrections = const [],
  });

  /// [decoded] with this capture's active corrections applied — what scoring,
  /// the review overlay and analytics should read. Equal to [decoded] when
  /// there are none.
  OmrScanResult get effectiveDecoded =>
      CorrectionRules.effective(decoded, corrections, captureRevision);

  /// Items the scanner could not read cleanly (a double/stray mark) that a
  /// reviewer has not yet decided. An item leaves this list as soon as the
  /// current capture has an active correction for it. Read from the stored
  /// [decoded] answers and [corrections] only — nothing is re-decoded.
  List<OmrItemResult> get unresolvedFlaggedItems {
    final active = activeCorrections;
    return [
      for (final item in decoded.items)
        if (item.isAmbiguous &&
            !active.containsKey(AnswerCorrection.keyFor(item.sectionName, item.itemNumber)))
          item,
    ];
  }

  /// Whether at least one flagged item is still unresolved, or the sheet as
  /// a whole was accepted only by the mesh rescue (see
  /// [OmrScanResult.meshRescued]) -- a capture the pipeline would previously
  /// have discarded, so it always warrants a look even when every item read
  /// cleanly.
  bool get needsReview => unresolvedFlaggedItems.isNotEmpty || decoded.meshRescued;

  /// Whether [other] is this exact stored record — same capture, answers,
  /// score, student details, corrections and image references. Used to
  /// notice that a sheet changed (or was replaced) while a review of it was
  /// open. Compares the persisted form, so it can't drift from what is saved.
  bool sameStoredStateAs(LocalScan other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  /// Corrections on this capture that currently change an answer.
  Map<String, AnswerCorrection> get activeCorrections =>
      CorrectionRules.activeFor(corrections, captureRevision);

  /// Corrections made on an earlier capture that a rescan left unreviewed —
  /// kept for history, never applied to the current capture.
  List<AnswerCorrection> get correctionsNeedingReview =>
      CorrectionRules.needingReview(corrections, captureRevision);

  LocalScan copyWith({
    LocalScanResult? result,
    ExamineeInfo? examinee,
    bool clearExaminee = false,
    List<AnswerCorrection>? corrections,
  }) =>
      LocalScan(
        id: id,
        imageFileName: imageFileName,
        rectifiedImageFileName: rectifiedImageFileName,
        capturedAt: capturedAt,
        decoded: decoded,
        result: result ?? this.result,
        examinee: clearExaminee ? null : (examinee ?? this.examinee),
        nameCropLastFileName: nameCropLastFileName,
        nameCropFirstFileName: nameCropFirstFileName,
        nameCropMiddleFileName: nameCropMiddleFileName,
        captureRevision: captureRevision,
        corrections: corrections ?? this.corrections,
        rescannedAt: rescannedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'imageFileName': imageFileName,
        'rectifiedImageFileName': rectifiedImageFileName,
        'capturedAt': capturedAt.toIso8601String(),
        'decoded': decoded.toJson(),
        'result': result?.toJson(),
        'examinee': examinee?.toJson(),
        'nameCropLastFileName': nameCropLastFileName,
        'nameCropFirstFileName': nameCropFirstFileName,
        'nameCropMiddleFileName': nameCropMiddleFileName,
        // Additive: absent for a scan with no rescan and no corrections, so
        // such a scan serializes exactly as it did before these existed.
        if (captureRevision != 0) 'captureRevision': captureRevision,
        if (rescannedAt != null) 'rescannedAt': rescannedAt!.toIso8601String(),
        if (corrections.isNotEmpty)
          'corrections': corrections.map((c) => c.toJson()).toList(),
      };

  factory LocalScan.fromJson(Map<String, dynamic> json) => LocalScan(
        id: json['id'] as String,
        imageFileName: json['imageFileName'] as String,
        rectifiedImageFileName: json['rectifiedImageFileName'] as String?,
        capturedAt: DateTime.parse(json['capturedAt'] as String),
        decoded: OmrScanResult.fromJson(json['decoded'] as Map<String, dynamic>),
        result: json['result'] == null
            ? null
            : LocalScanResult.fromJson(json['result'] as Map<String, dynamic>),
        examinee: json['examinee'] == null
            ? null
            : ExamineeInfo.fromJson(json['examinee'] as Map<String, dynamic>),
        // Absent on any scan captured before these fields existed — those
        // just display with no crop, per their own doc comment above.
        nameCropLastFileName: json['nameCropLastFileName'] as String?,
        nameCropFirstFileName: json['nameCropFirstFileName'] as String?,
        nameCropMiddleFileName: json['nameCropMiddleFileName'] as String?,
        captureRevision: json['captureRevision'] as int? ?? 0,
        rescannedAt: json['rescannedAt'] == null ? null : DateTime.parse(json['rescannedAt'] as String),
        corrections: (json['corrections'] as List<dynamic>? ?? [])
            .map((e) => AnswerCorrection.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// The graded outcome of one [LocalScan]. Field-for-field aligned with the
/// Firestore [ResultModel] so a future cloud repository can write these
/// straight into the `results` collection.
///
/// The `rawScore` / `totalGraded` / `totalItems` / `percentage` fields hold
/// the exam's headline result (for TAT, `rawScore` is the 160-point total).
/// The nullable `tatTest{1,2,3}*` / `tatTotal` fields carry the per-test
/// TAT breakdown and are populated only for TAT sheets; they are absent
/// from the JSON of every non-TAT result and from any result written before
/// this breakdown existed, so [fromJson] tolerates their absence.
class LocalScanResult {
  final int rawScore;
  final int totalGraded; // items actually covered by the answer key used
  final int totalItems; // items on the sheet, for context
  final double percentage;
  final String status; // 'Graded' | 'Ungraded'
  final DateTime scannedAt;
  final String processedByUid;
  final String processedByName;

  /// TAT per-test breakdown — null for non-TAT results and for results
  /// persisted before the breakdown was added. `tatTest1Score` is
  /// `correct * 2`; `tatTest2Score` / `tatTest3Score` are
  /// `max(0, correct - wrong)`; `tatTotal` is their sum (max 160).
  final int? tatTest1Correct;
  final int? tatTest1Wrong;
  final int? tatTest1Score;
  final int? tatTest2Correct;
  final int? tatTest2Wrong;
  final int? tatTest2Score;
  final int? tatTest3Correct;
  final int? tatTest3Wrong;
  final int? tatTest3Score;
  final int? tatTotal;

  const LocalScanResult({
    required this.rawScore,
    required this.totalGraded,
    required this.totalItems,
    required this.percentage,
    required this.status,
    required this.scannedAt,
    required this.processedByUid,
    required this.processedByName,
    this.tatTest1Correct,
    this.tatTest1Wrong,
    this.tatTest1Score,
    this.tatTest2Correct,
    this.tatTest2Wrong,
    this.tatTest2Score,
    this.tatTest3Correct,
    this.tatTest3Wrong,
    this.tatTest3Score,
    this.tatTotal,
  });

  bool get isGraded => status == 'Graded';

  /// Whether this result carries the TAT per-test breakdown.
  bool get hasTatBreakdown => tatTotal != null;

  Map<String, dynamic> toJson() => {
        'rawScore': rawScore,
        'totalGraded': totalGraded,
        'totalItems': totalItems,
        'percentage': percentage,
        'status': status,
        'scannedAt': scannedAt.toIso8601String(),
        'processedByUid': processedByUid,
        'processedByName': processedByName,
        // Additive: only present for TAT results. Non-TAT results keep the
        // exact JSON shape they had before the breakdown existed.
        if (tatTest1Correct != null) 'tatTest1Correct': tatTest1Correct,
        if (tatTest1Wrong != null) 'tatTest1Wrong': tatTest1Wrong,
        if (tatTest1Score != null) 'tatTest1Score': tatTest1Score,
        if (tatTest2Correct != null) 'tatTest2Correct': tatTest2Correct,
        if (tatTest2Wrong != null) 'tatTest2Wrong': tatTest2Wrong,
        if (tatTest2Score != null) 'tatTest2Score': tatTest2Score,
        if (tatTest3Correct != null) 'tatTest3Correct': tatTest3Correct,
        if (tatTest3Wrong != null) 'tatTest3Wrong': tatTest3Wrong,
        if (tatTest3Score != null) 'tatTest3Score': tatTest3Score,
        if (tatTotal != null) 'tatTotal': tatTotal,
      };

  factory LocalScanResult.fromJson(Map<String, dynamic> json) => LocalScanResult(
        rawScore: json['rawScore'] as int? ?? 0,
        totalGraded: json['totalGraded'] as int? ?? 0,
        totalItems: json['totalItems'] as int? ?? 0,
        percentage: (json['percentage'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String? ?? 'Ungraded',
        scannedAt: DateTime.parse(json['scannedAt'] as String),
        processedByUid: json['processedByUid'] as String? ?? '',
        processedByName: json['processedByName'] as String? ?? 'Unknown',
        // Absent in every pre-breakdown record and in all non-TAT records.
        tatTest1Correct: json['tatTest1Correct'] as int?,
        tatTest1Wrong: json['tatTest1Wrong'] as int?,
        tatTest1Score: json['tatTest1Score'] as int?,
        tatTest2Correct: json['tatTest2Correct'] as int?,
        tatTest2Wrong: json['tatTest2Wrong'] as int?,
        tatTest2Score: json['tatTest2Score'] as int?,
        tatTest3Correct: json['tatTest3Correct'] as int?,
        tatTest3Wrong: json['tatTest3Wrong'] as int?,
        tatTest3Score: json['tatTest3Score'] as int?,
        tatTotal: json['tatTotal'] as int?,
      );
}
