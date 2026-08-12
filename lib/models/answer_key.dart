/// Answer Key model representing an answer key in the Firestore answer_keys collection.
class AnswerKeyModel {
  final String answerKeyId;
  final String examId;
  final String version; // e.g., "1.0", "1.1", "2.0"
  final String status; // 'Draft' | 'Final'
  final String answerFormat; // e.g., 'multiple_choice'
  final List<String> allowedChoices; // e.g., ['A', 'B', 'C', 'D']
  final Map<String, String> answers; // Question-numbered: {"1": "A", "2": "B", ...}
  final int totalItems;
  final String createdByUid; // Immutable
  final String createdByName; // Immutable
  final DateTime createdAt; // Immutable
  final DateTime updatedAt;

  const AnswerKeyModel({
    required this.answerKeyId,
    required this.examId,
    required this.version,
    required this.status,
    required this.answerFormat,
    required this.allowedChoices,
    required this.answers,
    required this.totalItems,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates an AnswerKeyModel from Firestore document data.
  factory AnswerKeyModel.fromFirestore(
      Map<String, dynamic> data,
      String documentId,
      ) {
    return AnswerKeyModel(
      answerKeyId: documentId,
      examId: data['examId'] as String,
      version: data['version'] as String,
      status: data['status'] as String,
      answerFormat: data['answerFormat'] as String,
      allowedChoices: List<String>.from(data['allowedChoices'] as List),
      answers: Map<String, String>.from(data['answers'] as Map),
      totalItems: data['totalItems'] as int,
      createdByUid: data['createdByUid'] as String,
      createdByName: data['createdByName'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
      updatedAt: DateTime.parse(data['updatedAt'] as String),
    );
  }

  /// Converts AnswerKeyModel to Firestore document data.
  Map<String, dynamic> toFirestore() {
    return {
      'answerKeyId': answerKeyId,
      'examId': examId,
      'version': version,
      'status': status,
      'answerFormat': answerFormat,
      'allowedChoices': allowedChoices,
      'answers': answers,
      'totalItems': totalItems,
      'createdByUid': createdByUid,
      'createdByName': createdByName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Creates a copy of this AnswerKeyModel with some fields replaced.
  /// Audit fields are never overwritten.
  AnswerKeyModel copyWith({
    String? answerKeyId,
    String? examId,
    String? version,
    String? status,
    String? answerFormat,
    List<String>? allowedChoices,
    Map<String, String>? answers,
    int? totalItems,
    DateTime? updatedAt,
  }) {
    return AnswerKeyModel(
      answerKeyId: answerKeyId ?? this.answerKeyId,
      examId: examId ?? this.examId,
      version: version ?? this.version,
      status: status ?? this.status,
      answerFormat: answerFormat ?? this.answerFormat,
      allowedChoices: allowedChoices ?? this.allowedChoices,
      answers: answers ?? this.answers,
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