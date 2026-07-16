import 'package:flutter/material.dart';
import '../../models/activity_model.dart';
import '../../models/cloud_file_model.dart';

/// A lightweight in-memory app state shared across screens via
/// ChangeNotifierProvider-style access (kept dependency-free by
/// using InheritedNotifier through [AppStateScope]).
///
/// This mirrors the mock `state` object used in the HTML prototype
/// (recentActivities, activeExamCode, sync timestamps, etc.).
class AppState extends ChangeNotifier {
  String userRole = 'staff'; // 'staff' | 'admin'
  String activeExamCode = 'AT'; // AT | PT | TAT | QTM
  String answerKeyStatus = 'Not Uploaded';

  String databaseLastSynced = 'June 15, 2026, 04:30 PM';
  String localLastUpdated = 'June 16, 2026, 09:15 AM';

  final List<ActivityModel> recentActivities = [
    const ActivityModel(type: 'Admission Exam', date: '06/04/2026', batch: 'Batch 01-A', status: 'Done', examCode: 'AT'),
    const ActivityModel(type: 'Personality Profile', date: '06/05/2026', batch: 'Batch 04', status: 'Done', examCode: 'PT'),
    const ActivityModel(type: 'Quantitative Math', date: '06/10/2026', batch: 'Batch B-9', status: 'Pending', examCode: 'QTM'),
    const ActivityModel(type: 'Teaching Aptitude', date: '06/12/2026', batch: 'Batch T-12', status: 'Pending', examCode: 'TAT'),
  ];

  final List<CloudFileModel> databaseCloudFiles = const [
    CloudFileModel(name: 'Admission Exam - Batch 01-A (Synced)', code: 'AT', total: 50, timestamp: '06/04/2026'),
    CloudFileModel(name: 'Personality Test - Batch 04 (Synced)', code: 'PT', total: 32, timestamp: '06/05/2026'),
  ];

  int currentScannedPage = 0;
  int totalToScan = 50;

  List<ActivityModel> get pendingBatches =>
      recentActivities.where((a) => a.status == 'Pending').toList();

  void addBatch({required String title, required String typeCode}) {
    String typeLabel = 'Admission Exam';
    if (typeCode == 'PT') typeLabel = 'Personality Profile';
    if (typeCode == 'TAT') typeLabel = 'Teaching Aptitude';
    if (typeCode == 'QTM') typeLabel = 'Quantitative Math';

    recentActivities.insert(
      0,
      ActivityModel(
        type: typeLabel,
        date: 'Pending Check',
        batch: title,
        status: 'Pending',
        examCode: typeCode,
      ),
    );
    notifyListeners();
  }

  void markBatchDone(String batchName) {
    final idx = recentActivities.indexWhere((a) => a.batch == batchName);
    if (idx != -1) {
      recentActivities[idx] = recentActivities[idx].copyWith(
        status: 'Done',
        date: 'Just now',
      );
      notifyListeners();
    }
  }

  void setActiveExamCode(String code) {
    activeExamCode = code;
    notifyListeners();
  }

  void uploadAnswerKey() {
    answerKeyStatus = 'Loaded Success';
    notifyListeners();
  }

  void resetScanProgress() {
    currentScannedPage = 0;
    notifyListeners();
  }

  void nextScanPage() {
    currentScannedPage += 1;
    notifyListeners();
  }

  void syncLocalToDatabase() {
    databaseLastSynced = localLastUpdated;
    notifyListeners();
  }
}

/// Simple InheritedNotifier-based scope so screens/widgets can access
/// [AppState] without pulling in a third-party state management package.
class AppStateScope extends InheritedNotifier<AppState> {
  const AppStateScope({
    super.key,
    required AppState super.notifier,
    required super.child,
  });

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppStateScope>();
    assert(scope != null, 'AppStateScope not found in widget tree');
    return scope!.notifier!;
  }
}
