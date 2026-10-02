/// Batch model representing a batch of answer sheets in the Firestore batches collection.
class BatchModel {
  final String batchId;
  final String batchCode; // Auto-generated unique code (e.g., B-2026-001)
  final String examId; // Reference to exam
  final String examCode; // Denormalized for display
  final String examTitle; // Denormalized for display
  final String status; // 'Draft' | 'Active' | 'Completed' | 'Archived'
  final String description;
  final int expectedCount; // Expected number of answer sheets
  final int actualCount; // Actual number of scanned answer sheets
  final String createdByUid; // Immutable
  final String createdByName; // Immutable
  final DateTime createdAt; // Immutable
  final DateTime updatedAt;

  const BatchModel({
    required this.batchId,
    required this.batchCode,
    required this.examId,
    required this.examCode,
    required this.examTitle,
    required this.status,
    required this.description,
    required this.expectedCount,
    required this.actualCount,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Creates a BatchModel from Firestore document data
  factory BatchModel.fromFirestore(Map<String, dynamic> data, String documentId) {
    return BatchModel(
      batchId: documentId,
      batchCode: data['batchCode'] as String,
      examId: data['examId'] as String,
      examCode: data['examCode'] as String,
      examTitle: data['examTitle'] as String,
      status: data['status'] as String,
      description: data['description'] as String? ?? '',
      expectedCount: data['expectedCount'] as int,
      actualCount: data['actualCount'] as int,
      createdByUid: data['createdByUid'] as String,
      createdByName: data['createdByName'] as String,
      createdAt: DateTime.parse(data['createdAt'] as String),
      updatedAt: DateTime.parse(data['updatedAt'] as String),
    );
  }

  /// Converts BatchModel to Firestore document data
  Map<String, dynamic> toFirestore() {
    return {
      'batchId': batchId,
      'batchCode': batchCode,
      'examId': examId,
      'examCode': examCode,
      'examTitle': examTitle,
      'status': status,
      'description': description,
      'expectedCount': expectedCount,
      'actualCount': actualCount,
      'createdByUid': createdByUid,
      'createdByName': createdByName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Creates a copy of this BatchModel with some fields replaced
  /// Note: Audit fields (createdByUid, createdByName, createdAt) are never overwritten
  BatchModel copyWith({
    String? batchId,
    String? batchCode,
    String? examId,
    String? examCode,
    String? examTitle,
    String? status,
    String? description,
    int? expectedCount,
    int? actualCount,
    DateTime? updatedAt,
  }) {
    return BatchModel(
      batchId: batchId ?? this.batchId,
      batchCode: batchCode ?? this.batchCode,
      examId: examId ?? this.examId,
      examCode: examCode ?? this.examCode,
      examTitle: examTitle ?? this.examTitle,
      status: status ?? this.status,
      description: description ?? this.description,
      expectedCount: expectedCount ?? this.expectedCount,
      actualCount: actualCount ?? this.actualCount,
      createdByUid: createdByUid, // Never overwritten
      createdByName: createdByName, // Never overwritten
      createdAt: createdAt, // Never overwritten
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Helper to check if batch is in Draft status
  bool get isDraft => status == 'Draft';

  /// Helper to check if batch is Active
  bool get isActive => status == 'Active';

  /// Helper to check if batch is Completed
  bool get isCompleted => status == 'Completed';

  /// Helper to check if batch is Archived
  bool get isArchived => status == 'Archived';

  /// Helper to check if batch can be edited
  bool get canEdit => status == 'Draft';

  /// Helper to check if batch can be activated
  bool get canActivate => status == 'Draft';

  /// Helper to check if batch can be completed
  bool get canComplete => status == 'Active';

  /// Helper to check if batch can be archived
  bool get canArchive => status == 'Active' || status == 'Completed';
}
