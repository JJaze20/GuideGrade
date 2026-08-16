/// Answer Key model representing an answer key in the Firestore answer_keys collection.
///
/// Schema version 2 (current): [answers] is keyed by section name, then by
/// item number, matching [OmrExamTemplate.sections] exactly --
/// `{"Test II": {"47": "T"}}` -- so exam types like TAT that restart item
/// numbering at 1 in every section never collide. There is no
/// `allowedChoices` field: the OMR template is the sole source of truth for
/// which choices are valid per item (Admission's per-item alternating
/// choice pools can't be expressed as one flat list anyway), so this model
/// never stores a second, driftable copy of that.
///
/// Schema version 1 (legacy, read-only): documents written before section
/// support existed store [answers] as a flat `{"1": "A"}` map. Those are
/// parsed into [legacyFlatAnswers] instead of [answers] -- see [isLegacy] --
/// and are never reinterpreted as valid for scoring here; callers decide
/// per exam type whether/how a legacy key can be migrated (see
/// lib/core/omr/answer_key_adapter.dart).
class AnswerKeyModel {
  final String answerKeyId;
  final String examId;
  final String version; // e.g., "1.0", "1.1", "2.0"
  final String status; // 'Draft' | 'Final'
  final int schemaVersion; // 2 = current section-aware format
  final Map<String, Map<String, String>> answers; // sectionName -> itemNumber -> choice; empty when isLegacy
  final Map<String, String> legacyFlatAnswers; // only populated when isLegacy; raw pre-migration data
  final int totalItems;
  final String createdByUid; // Immutable
  final String createdByName; // Immutable
  final DateTime createdAt; // Immutable
  final DateTime updatedAt;

  static const int currentSchemaVersion = 2;

  const AnswerKeyModel({
    required this.answerKeyId,
    required this.examId,
    required this.version,
    required this.status,
    required this.schemaVersion,
    required this.answers,
    required this.legacyFlatAnswers,
    required this.totalItems,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates an AnswerKeyModel from Firestore document data. Detects
  /// pre-section-support documents (missing schemaVersion, or a flat
  /// `answers` map) and routes them into [legacyFlatAnswers] rather than
  /// misreading them as section-shaped.
  factory AnswerKeyModel.fromFirestore(
      Map<String, dynamic> data,
      String documentId,
      ) {
    final storedSchemaVersion = data['schemaVersion'] as int?;
    final rawAnswers = data['answers'] as Map? ?? {};
    final isNestedShape = storedSchemaVersion == currentSchemaVersion &&
        rawAnswers.values.every((v) => v is Map);

    if (isNestedShape) {
      final parsed = <String, Map<String, String>>{};
      rawAnswers.forEach((sectionName, itemMap) {
        parsed[sectionName as String] = Map<String, String>.from(itemMap as Map);
      });
      return AnswerKeyModel(
        answerKeyId: documentId,
        examId: data['examId'] as String,
        version: data['version'] as String,
        status: data['status'] as String,
        schemaVersion: currentSchemaVersion,
        answers: parsed,
        legacyFlatAnswers: const {},
        totalItems: data['totalItems'] as int,
        createdByUid: data['createdByUid'] as String,
        createdByName: data['createdByName'] as String,
        createdAt: DateTime.parse(data['createdAt'] as String),
        updatedAt: DateTime.parse(data['updatedAt'] as String),
      );
    }

    // Legacy (schemaVersion 1 or absent): answers is a flat {"1": "A"} map.
    return AnswerKeyModel(
      answerKeyId: documentId,
      examId: data['examId'] as String,
      version: data['version'] as String,
      status: data['status'] as String,
      schemaVersion: storedSchemaVersion ?? 1,
      answers: const {},
      legacyFlatAnswers: Map<String, String>.from(rawAnswers),
      totalItems: data['totalItems'] as int,
      createdByUid: data['createdByUid'] as String,
      createdByName: data['createdByName'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
      updatedAt: DateTime.parse(data['updatedAt'] as String),
    );
  }

  /// Converts AnswerKeyModel to Firestore document data. Always writes the
  /// current section-aware schema -- a legacy document loaded via
  /// [legacyFlatAnswers] is never written back in its old flat shape; by
  /// the time this is called, [answers] should already hold the
  /// staff-reviewed/re-entered section-aware data (see the answer key
  /// editor screen).
  Map<String, dynamic> toFirestore() {
    return {
      'answerKeyId': answerKeyId,
      'examId': examId,
      'version': version,
      'status': status,
      'schemaVersion': currentSchemaVersion,
      'answers': answers,
      'totalItems': totalItems,
      'createdByUid': createdByUid,
      'createdByName': createdByName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Creates a copy of this AnswerKeyModel with some fields replaced.
  /// Audit fields are never overwritten. A copy always carries the current
  /// schema version and empty [legacyFlatAnswers] -- copyWith is only ever
  /// used to build a document that's about to be saved, and saved
  /// documents are always current-schema (see [toFirestore]).
  AnswerKeyModel copyWith({
    String? answerKeyId,
    String? examId,
    String? version,
    String? status,
    Map<String, Map<String, String>>? answers,
    int? totalItems,
    DateTime? updatedAt,
  }) {
    return AnswerKeyModel(
      answerKeyId: answerKeyId ?? this.answerKeyId,
      examId: examId ?? this.examId,
      version: version ?? this.version,
      status: status ?? this.status,
      schemaVersion: currentSchemaVersion,
      answers: answers ?? this.answers,
      legacyFlatAnswers: const {},
      totalItems: totalItems ?? this.totalItems,
      createdByUid: createdByUid,
      createdByName: createdByName,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Helper to check if answer key is in Draft status.
  bool get isDraft => status == 'Draft';

  /// Helper to check if answer key is Final.
  bool get isFinal => status == 'Final';

  /// Helper to check if answer key can be edited.
  bool get canEdit => status == 'Draft';

  /// Helper to check if answer key can be marked as Final.
  bool get canMarkFinal => status == 'Draft';

  /// True for documents written before section support existed. Never
  /// usable for scoring as-is -- see lib/core/omr/answer_key_adapter.dart.
  bool get isLegacy => schemaVersion != currentSchemaVersion;
}

/// The correct choice per question for one exam code, entered manually by
/// staff (see AnswerKeyEntryScreen) rather than uploaded from a file.
///
/// Keyed by section name + item number, not item number alone. Exam types
/// like TAT restart numbering at 1 in every section, so a flat item-number
/// key would collide across sections.
class AnswerKey {
  final String examCode;
  final Map<String, String> correctChoices;

  const AnswerKey({
    required this.examCode,
    required this.correctChoices,
  });

  static String keyFor(String sectionName, int itemNumber) {
    return '$sectionName|$itemNumber';
  }

  String? choiceFor(String sectionName, int itemNumber) {
    return correctChoices[keyFor(sectionName, itemNumber)];
  }
}