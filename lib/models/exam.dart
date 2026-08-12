/// Exam model representing an exam in the Firestore exams collection.
class ExamModel {
  final String examId;
  final String examCode;
  final String title;
  final String category; // 'admission' | 'personality' | 'aptitude' | 'quantitative'
  final int totalItems;
  final int duration; // minutes
  final String instructions;
  final String answerSheetTemplate; // e.g., 'Default-50', 'Default-100', 'Admission-200', 'Personality-300'
  final String status; // 'Draft' | 'Ready' | 'Archived'
  final String createdByUid;
  final String createdByName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String academicYear;
  final String semester;

  const ExamModel({
    required this.examId,
    required this.examCode,
    required this.title,
    required this.category,
    required this.totalItems,
    required this.duration,
    required this.instructions,
    required this.answerSheetTemplate,
    required this.status,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
    required this.academicYear,
    required this.semester,
  });

  /// Creates an ExamModel from Firestore document data
  factory ExamModel.fromFirestore(Map<String, dynamic> data, String documentId) {
    return ExamModel(
      examId: documentId,
      examCode: data['examCode'] as String,
      title: data['title'] as String,
      category: data['category'] as String,
      totalItems: data['totalItems'] as int,
      duration: data['duration'] as int,
      instructions: data['instructions'] as String,
      answerSheetTemplate: data['answerSheetTemplate'] as String,
      status: data['status'] as String,
      createdByUid: data['createdByUid'] as String,
      createdByName: data['createdByName'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
      updatedAt: DateTime.parse(data['updatedAt'] as String),
      academicYear: data['academicYear'] as String,
      semester: data['semester'] as String,
    );
  }

  /// Converts ExamModel to Firestore document data
  Map<String, dynamic> toFirestore() {
    return {
      'examId': examId,
      'examCode': examCode,
      'title': title,
      'category': category,
      'totalItems': totalItems,
      'duration': duration,
      'instructions': instructions,
      'answerSheetTemplate': answerSheetTemplate,
      'status': status,
      'createdByUid': createdByUid,
      'createdByName': createdByName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'academicYear': academicYear,
      'semester': semester,
    };
  }

  /// Creates a copy of this ExamModel with some fields replaced
  ExamModel copyWith({
    String? examId,
    String? examCode,
    String? title,
    String? category,
    int? totalItems,
    int? duration,
    String? instructions,
    String? answerSheetTemplate,
    String? status,
    String? createdByUid,
    String? createdByName,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? academicYear,
    String? semester,
  }) {
    return ExamModel(
      examId: examId ?? this.examId,
      examCode: examCode ?? this.examCode,
      title: title ?? this.title,
      category: category ?? this.category,
      totalItems: totalItems ?? this.totalItems,
      duration: duration ?? this.duration,
      instructions: instructions ?? this.instructions,
      answerSheetTemplate: answerSheetTemplate ?? this.answerSheetTemplate,
      status: status ?? this.status,
      createdByUid: createdByUid ?? this.createdByUid,
      createdByName: createdByName ?? this.createdByName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      academicYear: academicYear ?? this.academicYear,
      semester: semester ?? this.semester,
    );
  }

  /// Helper to check if exam is in Draft status
  bool get isDraft => status == 'Draft';

  /// Helper to check if exam is in Ready status
  bool get isReady => status == 'Ready';

  /// Helper to check if exam is Archived
  bool get isArchived => status == 'Archived';

  /// Helper to check if exam can be edited (Draft only)
  bool get canEdit => status == 'Draft';

  /// Helper to check if exam can have instructions edited (Draft or Ready)
  bool get canEditInstructions => status == 'Draft' || status == 'Ready';

  /// Helper to check if exam can be archived (Draft or Ready)
  bool get canArchive => status == 'Draft' || status == 'Ready';

  /// Helper to check if exam can be marked as Ready (Draft only)
  bool get canMarkReady => status == 'Draft';
}
