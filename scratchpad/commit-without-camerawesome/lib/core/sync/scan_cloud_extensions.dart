import '../../models/answer_correction.dart';
import '../../models/local_batch.dart';

/// How manual answer corrections and the optional student details reach (and
/// come back from) the cloud WITHOUT a schema migration.
///
/// The `scans` table has no columns for them, and no migration files exist in
/// this repository, so adding real columns to the upsert would fail every scan
/// push permanently (an unknown column is a 4xx "permanent" outcome). The row
/// does already carry a free-form `decoded` jsonb, which older app builds
/// read with [OmrScanResult.fromJson] and simply ignore any unknown key of.
/// So the additions ride there, under one namespaced, versioned key:
///
/// ```json
/// "decoded": {
///   "examCode": "TAT", "items": [ ...the machine-detected answers, untouched... ],
///   "manual": {
///     "v": 1,
///     "captureRevision": 1,
///     "corrections": [ ...AnswerCorrection.toJson()... ],
///     "studentDetails": { "birthDate": "2008-03-14", "manualAge": 17, "lastSchool": "..." }
///   }
/// }
/// ```
///
/// The machine-detected `items` are never rewritten — the corrected values
/// live only in `manual.corrections` — and `raw_score`/`total_graded`/… still
/// carry the RECALCULATED score, so a consumer that only reads those columns
/// sees the corrected result.
///
/// A dedicated set of columns is the cleaner long-term home; that needs a
/// cloud migration this repo does not contain, so it is left as a follow-up.
class ScanCloudExtensions {
  const ScanCloudExtensions._();

  static const String key = 'manual';
  static const int version = 1;

  /// The `decoded` object to upsert for [scan]: its machine-detected JSON
  /// plus the `manual` block when there is anything to put in it.
  ///
  /// [cloudDecoded] is the row's CURRENT cloud `decoded` (when the caller
  /// could read it). Correction history is UNION-merged with the cloud's by
  /// entry id, so a push from one device never erases entries another device
  /// already recorded, and delivering the same push twice changes nothing.
  /// Student details and the capture revision are this device's own (the
  /// same last-writer rule the rest of the scan row already follows).
  static Map<String, dynamic> decodedForCloud(
    LocalScan scan, {
    Map<String, dynamic>? cloudDecoded,
  }) {
    final base = scan.decoded.toJson();
    final cloudManual = _manualOf(cloudDecoded);
    final cloudHistory = _correctionsOf(cloudManual);
    final history = CorrectionRules.merge(scan.corrections, cloudHistory);

    final details = _detailsJson(scan.examinee);
    final revision = scan.captureRevision;

    if (history.isEmpty && details == null && revision == 0) return base;

    return {
      ...base,
      key: {
        'v': version,
        if (revision != 0) 'captureRevision': revision,
        if (history.isNotEmpty)
          'corrections': history.map((c) => c.toJson()).toList(),
        if (details != null) 'studentDetails': details,
      },
    };
  }

  /// Reads the `manual` block back out of a cloud `decoded` object. Tolerates
  /// its absence (every row written before this existed) and any unknown
  /// extra keys.
  static ParsedManual parse(Map<String, dynamic> decoded) {
    final manual = _manualOf(decoded);
    final detailsJson = manual?['studentDetails'];
    ExamineeDetails? details;
    if (detailsJson is Map<String, dynamic>) {
      final birth = ExamineeInfo.birthDateFromText(detailsJson['birthDate'] as String?);
      details = ExamineeDetails(
        birthDate: birth,
        manualAge: birth == null ? detailsJson['manualAge'] as int? : null,
        lastSchool: detailsJson['lastSchool'] as String? ?? '',
      );
    }
    return ParsedManual(
      captureRevision: (manual?['captureRevision'] as int?) ?? 0,
      corrections: _correctionsOf(manual),
      details: details,
    );
  }

  static Map<String, dynamic>? _manualOf(Map<String, dynamic>? decoded) {
    final m = decoded?[key];
    return m is Map<String, dynamic> ? m : null;
  }

  static List<AnswerCorrection> _correctionsOf(Map<String, dynamic>? manual) {
    final raw = manual?['corrections'];
    if (raw is! List) return const [];
    final out = <AnswerCorrection>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      try {
        out.add(AnswerCorrection.fromJson(e));
      } catch (_) {
        // One malformed entry must not drop the rest of the history.
      }
    }
    return out;
  }

  static Map<String, dynamic>? _detailsJson(ExamineeInfo? e) {
    if (e == null) return null;
    final birth = e.birthDate;
    final age = birth == null ? e.manualAge : null; // never both
    final school = e.lastSchool.trim();
    if (birth == null && age == null && school.isEmpty) return null;
    return {
      if (birth != null) 'birthDate': ExamineeInfo.birthDateToText(birth),
      if (age != null) 'manualAge': age,
      if (school.isNotEmpty) 'lastSchool': school,
    };
  }
}

/// The optional student details as stored in the cloud block.
class ExamineeDetails {
  final DateTime? birthDate;
  final int? manualAge;
  final String lastSchool;

  const ExamineeDetails({this.birthDate, this.manualAge, this.lastSchool = ''});

  bool get isEmpty => birthDate == null && manualAge == null && lastSchool.isEmpty;
}

class ParsedManual {
  final int captureRevision;
  final List<AnswerCorrection> corrections;
  final ExamineeDetails? details;

  const ParsedManual({
    required this.captureRevision,
    required this.corrections,
    required this.details,
  });
}
