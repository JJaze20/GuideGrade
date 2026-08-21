import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/activity_model.dart';
import '../../models/answer_key.dart';
import '../../models/cloud_file_model.dart';
import '../../models/omr_scan_result.dart';
import '../../models/user.dart';
import '../omr/omr_decoder.dart';
import '../omr/omr_templates.dart';
import '../services/local_storage_service.dart';

class _OmrDecodeRequest {
  final String imagePath;
  final OmrExamTemplate template;
  const _OmrDecodeRequest(this.imagePath, this.template);
}

OmrScanResult _decodeOmrPage(_OmrDecodeRequest request) {
  return const OmrDecoder().decode(request.imagePath, request.template);
}

class _DebugVizRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final String outputDir;
  final int pageIndex;
  const _DebugVizRequest(this.imagePath, this.template, this.outputDir, this.pageIndex);
}

void _saveDebugVisualization(_DebugVizRequest request) {
  const OmrDecoder().saveDebugVisualization(request.imagePath, request.template, request.outputDir, request.pageIndex);
}

/// A lightweight in-memory app state shared across screens via
/// ChangeNotifierProvider-style access (kept dependency-free by
/// using InheritedNotifier through [AppStateScope]).
///
/// This mirrors the mock `state` object used in the HTML prototype
/// (recentActivities, activeExamCode, sync timestamps, etc.).
class AppState extends ChangeNotifier {
  /// The signed-in, Firestore-approved user for this session — null until a
  /// login screen successfully authorizes a sign-in (see
  /// AuthService._authorize) and cleared again on logout. [AppRoutes]'s
  /// route guard keys off this (not just Firebase's own auth state) so a
  /// protected screen can never be reached without having actually passed
  /// Firestore authorization, not merely Firebase authentication.
  UserModel? currentUser;

  void setCurrentUser(UserModel? user) {
    currentUser = user;
    notifyListeners();
  }

  String activeExamCode = 'AT'; // AT | TAT | QTM

  /// Manually-entered answer keys (see AnswerKeyEntryScreen), one per exam
  /// code that's had a key saved. Also where the Firestore Final answer key
  /// ends up after Exam Setup loads and converts it (see
  /// core/omr/answer_key_adapter.dart) -- the scorer only ever reads this
  /// map, regardless of which path populated it.
  final Map<String, AnswerKey> answerKeys = {};

  // --------------------------------------------------------------------
  // Real scan-session identity. Populated by Exam Setup once a real
  // Firestore ExamModel, BatchModel, and ExamineeModel have all been
  // selected -- [activeExamCode] alone is never sufficient to identify a
  // scan session against Firestore, since it's just the sheet-layout
  // lookup key and carries no exam/batch/examinee identity. Cleared only
  // by [clearScanSession] -- NOT by [resetScanProgress], since Exam
  // Results still needs this identity after scanning finishes in order to
  // persist a ResultModel.
  // --------------------------------------------------------------------
  String? scanExamId;
  String? scanExamTitle;
  int? scanTotalItems;
  String? scanBatchId;
  String? scanBatchCode;
  String? scanExamineeId;
  String? scanExamineeName;

  /// True once a real exam+batch+examinee have all been selected for this
  /// session -- i.e. it's safe to persist a ResultModel against them.
  bool get hasRealScanSession =>
      scanExamId != null && scanBatchId != null && scanExamineeId != null;

  void setScanSession({
    required String examId,
    required String examCode,
    required String examTitle,
    required int totalItems,
    required String batchId,
    required String batchCode,
    required String examineeId,
    required String examineeName,
  }) {
    scanExamId = examId;
    activeExamCode = examCode;
    scanExamTitle = examTitle;
    scanTotalItems = totalItems;
    scanBatchId = batchId;
    scanBatchCode = batchCode;
    scanExamineeId = examineeId;
    scanExamineeName = examineeName;
    notifyListeners();
  }

  void clearScanSession() {
    scanExamId = null;
    scanExamTitle = null;
    scanTotalItems = null;
    scanBatchId = null;
    scanBatchCode = null;
    scanExamineeId = null;
    scanExamineeName = null;
    notifyListeners();
  }

  String get answerKeyStatus => answerKeys.containsKey(activeExamCode) ? 'Loaded Success' : 'Not Uploaded';

  String databaseLastSynced = 'June 15, 2026, 04:30 PM';
  String localLastUpdated = 'June 16, 2026, 09:15 AM';

  final LocalStorageService _localStorage = LocalStorageService();

  /// The diagnostic batches/results registry shown on Staff Home. Persisted
  /// to device storage via [_localStorage] — [loadPersistedData] populates
  /// this at startup, and every mutation ([addBatch], [markBatchDone])
  /// saves it back, so batches survive app restarts and version upgrades
  /// rather than resetting to mock data every launch.
  final List<ActivityModel> recentActivities = [];

  /// Loads persisted app data. Called once at startup, before the first
  /// frame, so the registry never flashes empty then populates.
  Future<void> loadPersistedData() async {
    final activities = await _localStorage.loadActivities();
    recentActivities
      ..clear()
      ..addAll(activities);
    final keys = await _localStorage.loadAnswerKeys();
    answerKeys
      ..clear()
      ..addAll(keys);
    notifyListeners();
  }

  final List<CloudFileModel> databaseCloudFiles = const [
    CloudFileModel(name: 'Admission Exam - Batch 01-A (Synced)', code: 'AT', total: 50, timestamp: '06/04/2026'),
  ];

  int currentScannedPage = 0;
  int totalToScan = 50;

  /// Raw captured sheet photos for the in-progress scan session, one per
  /// page, in capture order. Cleared by [resetScanProgress].
  final List<XFile> capturedPages = [];

  /// Decoded bubble results for the in-progress scan session, one per
  /// captured page, populated by [processCapturedPages]. Cleared by
  /// [resetScanProgress].
  final List<OmrScanResult> scannedResults = [];

  bool isProcessingScans = false;
  String? scanProcessingError;

  /// Where the last processCapturedPages() run wrote debug visualization
  /// images (corner-detection + bubble-grid overlays), if it managed to.
  /// Diagnostic only — never blocks or affects real scan results.
  String? lastDebugImagesDir;

  List<ActivityModel> get pendingBatches =>
      recentActivities.where((a) => a.status == 'Pending').toList();

  void addBatch({required String title, required String typeCode}) {
    String typeLabel = 'Admission Exam';
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
    _localStorage.saveActivities(recentActivities);
  }

  void markBatchDone(String batchName) {
    final idx = recentActivities.indexWhere((a) => a.batch == batchName);
    if (idx != -1) {
      recentActivities[idx] = recentActivities[idx].copyWith(
        status: 'Done',
        date: 'Just now',
      );
      notifyListeners();
      _localStorage.saveActivities(recentActivities);
    }
  }

  void setActiveExamCode(String code) {
    activeExamCode = code;
    notifyListeners();
  }

  void setAnswerKey(AnswerKey key) {
    answerKeys[key.examCode] = key;
    unawaited(_localStorage.saveAnswerKeys(answerKeys));
    notifyListeners();
  }

  void resetScanProgress() {
    currentScannedPage = 0;
    capturedPages.clear();
    scannedResults.clear();
    scanProcessingError = null;
    notifyListeners();
  }

  /// Records a freshly captured sheet photo and advances the page counter.
  void addCapturedPage(XFile file) {
    capturedPages.add(file);
    currentScannedPage = capturedPages.length;
    notifyListeners();
  }

  /// Runs the OMR decoder over every page in [capturedPages] for the active
  /// exam template, populating [scannedResults]. Each page is decoded on a
  /// background isolate so the UI stays responsive.
  Future<void> processCapturedPages() async {
    final template = omrTemplates[activeExamCode];
    if (template == null) {
      scanProcessingError = 'No sheet layout is defined for exam code "$activeExamCode".';
      notifyListeners();
      return;
    }

    isProcessingScans = true;
    scanProcessingError = null;
    scannedResults.clear();
    notifyListeners();

    final debugDir = await _prepareDebugImagesDir();
    lastDebugImagesDir = debugDir;

    // Process every page independently: a failure on one sheet shouldn't
    // hide debug output for it (debug images are most useful for exactly
    // the pages that fail) or block decoding the rest of the batch.
    final errors = <String>[];
    var pageIndex = 0;
    for (final page in capturedPages) {
      pageIndex++;
      try {
        final result = await compute(_decodeOmrPage, _OmrDecodeRequest(page.path, template));
        scannedResults.add(result);
      } catch (e) {
        errors.add('Sheet $pageIndex: $e');
      }
      if (debugDir != null) {
        try {
          await compute(_saveDebugVisualization, _DebugVizRequest(page.path, template, debugDir, pageIndex));
        } catch (_) {
          // Diagnostic-only; never let a debug-image failure block real results.
        }
      }
    }

    scanProcessingError = errors.isEmpty ? null : errors.join('\n');
    isProcessingScans = false;
    notifyListeners();
  }

  /// App-external "omr_debug" folder for [processCapturedPages]'s debug
  /// visualization images. Returns null (silently) if unavailable rather
  /// than failing the real scan over a diagnostic feature.
  Future<String?> _prepareDebugImagesDir() async {
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return null;
      final dir = Directory('${base.path}/omr_debug');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir.path;
    } catch (_) {
      return null;
    }
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