/// Examinee model representing a student/examinee in the Firestore examinees collection.
class ExamineeModel {
  final String examineeId;
  final String studentNumber; // Student Number or Applicant ID
  final String fullName;
  final String course; // Course/Program
  final String yearLevel; // Year Level (if applicable)
  final String sex; // Male, Female
  final String batchId; // Reference to batch
  final String examId; // Reference to exam (denormalized for convenience)
  final String examCode; // Denormalized for display
  final String examTitle; // Denormalized for display
  final String createdByUid; // Immutable
  final String createdByName; // Immutable
  final DateTime createdAt; // Immutable
  final DateTime updatedAt;

  const ExamineeModel({
    required this.examineeId,
    required this.studentNumber,
    required this.fullName,
    required this.course,
    required this.yearLevel,
    required this.sex,
    required this.batchId,
    required this.examId,
    required this.examCode,
    required this.examTitle,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates an ExamineeModel from Firestore document data
  factory ExamineeModel.fromFirestore(Map<String, dynamic> data, String documentId) {
    return ExamineeModel(
      examineeId: documentId,
      studentNumber: data['studentNumber'] as String,
      fullName: data['fullName'] as String,
      course: data['course'] as String? ?? '',
      yearLevel: data['yearLevel'] as String? ?? '',
      sex: data['sex'] as String,
      batchId: data['batchId'] as String,
      examId: data['examId'] as String,
      examCode: data['examCode'] as String,
      examTitle: data['examTitle'] as String,
      createdByUid: data['createdByUid'] as String,
      createdByName: data['createdByName'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
      updatedAt: DateTime.parse(data['updatedAt'] as String),
    );
  }

  /// Converts ExamineeModel to Firestore document data
  Map<String, dynamic> toFirestore() {
    return {
      'examineeId': examineeId,
      'studentNumber': studentNumber,
      'fullName': fullName,
      'course': course,
      'yearLevel': yearLevel,
      'sex': sex,
      'batchId': batchId,
      'examId': examId,
      'examCode': examCode,
      'examTitle': examTitle,
      'createdByUid': createdByUid,
      'createdByName': createdByName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Creates a copy of this ExamineeModel with some fields replaced
  /// Note: Audit fields (createdByUid, createdByName, createdAt) are never overwritten
  ExamineeModel copyWith({
    String? examineeId,
    String? studentNumber,
    String? fullName,
    String? course,
    String? yearLevel,
    String? sex,
    String? batchId,
    String? examId,
    String? examCode,
    String? examTitle,
    DateTime? updatedAt,
  }) {
    return ExamineeModel(
      examineeId: examineeId ?? this.examineeId,
      studentNumber: studentNumber ?? this.studentNumber,
      fullName: fullName ?? this.fullName,
      course: course ?? this.course,
      yearLevel: yearLevel ?? this.yearLevel,
      sex: sex ?? this.sex,
      batchId: batchId ?? this.batchId,
      examId: examId ?? this.examId,
      examCode: examCode ?? this.examCode,
      examTitle: examTitle ?? this.examTitle,
      createdByUid: createdByUid, // Never overwritten
      createdByName: createdByName, // Never overwritten
      createdAt: createdAt, // Never overwritten
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Helper to check if examinee is male
  bool get isMale => sex.toLowerCase() == 'male';

  /// Helper to check if examinee is female
  bool get isFemale => sex.toLowerCase() == 'female';
}
