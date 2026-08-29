import 'omr_scan_result.dart';

/// The student a scanned sheet belongs to. Attached per [LocalScan],
/// normally entered by staff on the results/review screen while holding the
/// physical sheet (there is no OCR — see the archive/review UI).
///
/// [examineeNumber] is the identifying field results are keyed to for a
/// person; [firstName]/[lastName] are for human-readable lists and exports.
class ExamineeInfo {
  final String firstName;
  final String lastName;
  final String examineeNumber;

  const ExamineeInfo({
    required this.firstName,
    required this.lastName,
    required this.examineeNumber,
  });

  /// "Last, First" — falls back to whichever half is present.
  String get displayName {
    final last = lastName.trim();
    final first = firstName.trim();
    if (last.isNotEmpty && first.isNotEmpty) return '$last, $first';
    if (last.isNotEmpty) return last;
    if (first.isNotEmpty) return first;
    return 'Unnamed';
  }

  bool get isComplete =>
      firstName.trim().isNotEmpty &&
      lastName.trim().isNotEmpty &&
      examineeNumber.trim().isNotEmpty;

  bool get isEmpty =>
      firstName.trim().isEmpty &&
      lastName.trim().isEmpty &&
      examineeNumber.trim().isEmpty;

  ExamineeInfo copyWith({String? firstName, String? lastName, String? examineeNumber}) =>
      ExamineeInfo(
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        examineeNumber: examineeNumber ?? this.examineeNumber,
      );

  Map<String, dynamic> toJson() => {
        'firstName': firstName,
        'lastName': lastName,
        'examineeNumber': examineeNumber,
      };

  factory ExamineeInfo.fromJson(Map<String, dynamic> json) => ExamineeInfo(
        firstName: json['firstName'] as String? ?? '',
        lastName: json['lastName'] as String? ?? '',
        examineeNumber: json['examineeNumber'] as String? ?? '',
      );
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

  bool get isDraft => status == 'Draft';
  bool get isActive => status == 'Active';
  bool get isCompleted => status == 'Completed';
  bool get isArchived => status == 'Archived';

  /// A batch can still receive new scans while it's a working batch.
  bool get canScan => status == 'Draft' || status == 'Active';

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

  const LocalScan({
    required this.id,
    required this.imageFileName,
    this.rectifiedImageFileName,
    required this.capturedAt,
    required this.decoded,
    this.result,
    this.examinee,
  });

  LocalScan copyWith({
    LocalScanResult? result,
    ExamineeInfo? examinee,
    bool clearExaminee = false,
  }) =>
      LocalScan(
        id: id,
        imageFileName: imageFileName,
        rectifiedImageFileName: rectifiedImageFileName,
        capturedAt: capturedAt,
        decoded: decoded,
        result: result ?? this.result,
        examinee: clearExaminee ? null : (examinee ?? this.examinee),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'imageFileName': imageFileName,
        'rectifiedImageFileName': rectifiedImageFileName,
        'capturedAt': capturedAt.toIso8601String(),
        'decoded': decoded.toJson(),
        'result': result?.toJson(),
        'examinee': examinee?.toJson(),
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
      );
}

/// The graded outcome of one [LocalScan]. Field-for-field aligned with the
/// Firestore [ResultModel] so a future cloud repository can write these
/// straight into the `results` collection.
class LocalScanResult {
  final int rawScore;
  final int totalGraded; // items actually covered by the answer key used
  final int totalItems; // items on the sheet, for context
  final double percentage;
  final String status; // 'Graded' | 'Ungraded'
  final DateTime scannedAt;
  final String processedByUid;
  final String processedByName;

  const LocalScanResult({
    required this.rawScore,
    required this.totalGraded,
    required this.totalItems,
    required this.percentage,
    required this.status,
    required this.scannedAt,
    required this.processedByUid,
    required this.processedByName,
  });

  bool get isGraded => status == 'Graded';

  Map<String, dynamic> toJson() => {
        'rawScore': rawScore,
        'totalGraded': totalGraded,
        'totalItems': totalItems,
        'percentage': percentage,
        'status': status,
        'scannedAt': scannedAt.toIso8601String(),
        'processedByUid': processedByUid,
        'processedByName': processedByName,
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
      );
}
