/// Outcome of FirestoreService.persistResult -- distinguishes a brand-new
/// result (which increments the batch's actualCount) from a correction to
/// an existing one (which does not).
enum ResultPersistOutcome { created, updated }

/// Result model representing one examinee's graded outcome in the
/// Firestore results collection.
///
/// One document per exam + batch + examinee, by construction -- see
/// [buildId]. Deliberately does not duplicate the answer key or store more
/// examinee detail than [examineeId]; both are looked up by ID when needed.
class ResultModel {
  final String resultId;
  final String examId;
  final String examCode; // denormalized for display, same pattern as BatchModel/ExamineeModel
  final String batchId;
  final String examineeId;
  final int rawScore;
  final int totalGraded; // items actually covered by the Final answer key used
  final int totalItems; // from the exam/template, for context even if totalGraded is less
  final double percentage;
  final String status; // 'Graded' | 'Ungraded'
  final DateTime scannedAt;
  final String processedByUid;
  final String processedByName;

  const ResultModel({
    required this.resultId,
    required this.examId,
    required this.examCode,
    required this.batchId,
    required this.examineeId,
    required this.rawScore,
    required this.totalGraded,
    required this.totalItems,
    required this.percentage,
    required this.status,
    required this.scannedAt,
    required this.processedByUid,
    required this.processedByName,
  });

  /// Deterministic document ID -- one result per exam+batch+examinee.
  /// Writing to this ID is what makes duplicate results impossible by
  /// construction, and what makes a retried/interrupted write safe to
  /// simply retry (see FirestoreService.persistResult).
  static String buildId({
    required String examId,
    required String batchId,
    required String examineeId,
  }) =>
      '${examId}_${batchId}_$examineeId';

  factory ResultModel.fromFirestore(Map<String, dynamic> data, String documentId) {
    return ResultModel(
      resultId: documentId,
      examId: data['examId'] as String,
      examCode: data['examCode'] as String,
      batchId: data['batchId'] as String,
      examineeId: data['examineeId'] as String,
      rawScore: data['rawScore'] as int,
      totalGraded: data['totalGraded'] as int,
      totalItems: data['totalItems'] as int,
      percentage: (data['percentage'] as num).toDouble(),
      status: data['status'] as String,
      scannedAt: DateTime.parse(data['scannedAt'] as String),
      processedByUid: data['processedByUid'] as String,
      processedByName: data['processedByName'] as String,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'resultId': resultId,
      'examId': examId,
      'examCode': examCode,
      'batchId': batchId,
      'examineeId': examineeId,
      'rawScore': rawScore,
      'totalGraded': totalGraded,
      'totalItems': totalItems,
      'percentage': percentage,
      'status': status,
      'scannedAt': scannedAt.toIso8601String(),
      'processedByUid': processedByUid,
      'processedByName': processedByName,
    };
  }

  bool get isGraded => status == 'Graded';
}
