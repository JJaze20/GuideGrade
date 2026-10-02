/// Represents a diagnostic test batch/session shown in the
/// Staff Home "Diagnostic Batches & Results Registry" list.
class ActivityModel {
  final String type; // e.g. Admission Exam, Teaching Aptitude
  final String date;
  final String batch;
  final String status; // 'Done' | 'Pending'
  final String examCode; // AT | TAT | QTM

  const ActivityModel({
    required this.type,
    required this.date,
    required this.batch,
    required this.status,
    required this.examCode,
  });

  bool get isDone => status == 'Done';

  ActivityModel copyWith({
    String? type,
    String? date,
    String? batch,
    String? status,
    String? examCode,
  }) {
    return ActivityModel(
      type: type ?? this.type,
      date: date ?? this.date,
      batch: batch ?? this.batch,
      status: status ?? this.status,
      examCode: examCode ?? this.examCode,
    );
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'date': date,
    'batch': batch,
    'status': status,
    'examCode': examCode,
  };

  factory ActivityModel.fromJson(Map<String, dynamic> json) => ActivityModel(
    type: json['type'] as String,
    date: json['date'] as String,
    batch: json['batch'] as String,
    status: json['status'] as String,
    examCode: json['examCode'] as String,
  );
}
