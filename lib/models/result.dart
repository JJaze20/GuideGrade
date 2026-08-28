/// Outcome of FirestoreService.persistResult -- distinguishes a brand-new
/// result (which increments the batch's actualCount) from a correction to
/// an existing one (which does not).
enum ResultPersistOutcome { created, updated }

/// Result model representing one graded scan outcome in the Firestore
/// results collection.
///
/// One document per completed scan -- [resultId] is a fresh,
/// Firestore-generated ID (see FirestoreService.newResultDocumentId),
/// assigned once per scan and never recomputed, so multiple sheets
/// scanned within the same batch each get their own document. Does not
/// identify or store any examinee-specific data: GuideGrade does not
/// collect examinee personal information, so a result is keyed purely by
/// exam + batch + its own generated ID.
class ResultModel {
  final String resultId;
  final String examId;
  final String examCode; // denormalized for display, same pattern as BatchModel
  final String batchId;
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
    required this.rawScore,
    required this.totalGraded,
    required this.totalItems,
    required this.percentage,
    required this.status,
    required this.scannedAt,
    required this.processedByUid,
    required this.processedByName,
  });

  factory ResultModel.fromFirestore(Map<String, dynamic> data, String documentId) {
    return ResultModel(
      resultId: documentId,
      examId: data['examId'] as String,
      examCode: data['examCode'] as String,
      batchId: data['batchId'] as String,
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
