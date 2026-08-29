import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import '../../models/user.dart';
import '../omr/omr_decoder.dart';
import '../omr/omr_scorer.dart';
import '../omr/omr_templates.dart';
import '../services/batch_repository.dart';
import '../services/local_batch_repository.dart';
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
/// [AppStateScope] (an InheritedNotifier, so no third-party state package).
class AppState extends ChangeNotifier {
  /// The signed-in, Firestore-approved user for this session — null until a
  /// login screen successfully authorizes a sign-in (see
  /// AuthService._authorize) and cleared again on logout. [AppRoutes]'s
  /// route guard keys off this (not just Firebase's own auth state).
  UserModel? currentUser;

  void setCurrentUser(UserModel? user) {
    currentUser = user;
    notifyListeners();
  }

  /// Sheet-layout lookup key for the active exam type. AT | TAT | QTM.
  /// This alone never identifies a scan session — see [scanBatch].
  String activeExamCode = 'AT';

  /// Manually-entered answer keys (see AnswerKeyEntryScreen), one per exam
  /// code that's had a key saved. The scorer only ever reads this map.
  final Map<String, AnswerKey> answerKeys = {};

  final LocalStorageService _localStorage = LocalStorageService();

  /// The one storage seam for the `Batch -> Scans -> Results` model. Local
  /// today; a cloud implementation can replace this without touching the
  /// screens that use it.
  final BatchRepository batchRepository = LocalBatchRepository();

  // --------------------------------------------------------------------
  // Active scan session. A scan can only ever be started against a real
  // [LocalBatch] (see startScanSession), so every captured sheet and every
  // result is guaranteed to belong to a selected, exam-type-compatible
  // batch. Cleared by [clearScanSession] — NOT by [resetScanProgress],
  // since Exam Results still needs this identity after scanning finishes in
  // order to persist the session into the batch.
  // --------------------------------------------------------------------
  LocalBatch? scanBatch;
  String? scanRef;

  String? get scanBatchId => scanBatch?.id;
  String? get scanBatchCode => scanBatch?.batchCode;

  /// True once a real batch has been selected for this scan session — i.e.
  /// it's safe to persist scans + results against it.
  bool get hasRealScanSession => scanBatch != null;

  /// Begins a scan session bound to [batch]. The exam type follows the
  /// batch, so the scanner and scorer can't drift onto a different layout.
  void startScanSession(LocalBatch batch) {
    scanBatch = batch;
    activeExamCode = batch.examCode;
    scanRef = 's_${DateTime.now().millisecondsSinceEpoch}';
    notifyListeners();
  }

  void clearScanSession() {
    scanBatch = null;
    scanRef = null;
    notifyListeners();
  }

  String get answerKeyStatus => answerKeys.containsKey(activeExamCode) ? 'Loaded Success' : 'Not Uploaded';

  /// Loads persisted app data (answer keys). Called once at startup.
  Future<void> loadPersistedData() async {
    final keys = await _localStorage.loadAnswerKeys();
    answerKeys
      ..clear()
      ..addAll(keys);
    notifyListeners();
  }

  int currentScannedPage = 0;

  /// Raw captured sheet photos for the in-progress scan session, one per
  /// page, in capture order. Cleared by [resetScanProgress].
  final List<XFile> capturedPages = [];

  /// Decoded bubble results for the in-progress scan session, one per
  /// captured page, populated by [processCapturedPages]. Cleared by
  /// [resetScanProgress].
  final List<OmrScanResult> scannedResults = [];

  bool isProcessingScans = false;
  String? scanProcessingError;

  /// Outcome of the last [persistCapturedSessionToBatch] run.
  bool isSavingToBatch = false;
  int savedScanCount = 0;
  int savedGradedCount = 0;
  String? batchSaveError;
  bool sessionPersistedToBatch = false;

  /// Where the last processCapturedPages() run wrote debug visualization
  /// images. Diagnostic only — never blocks or affects real scan results.
  String? lastDebugImagesDir;

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
    isSavingToBatch = false;
    savedScanCount = 0;
    savedGradedCount = 0;
    batchSaveError = null;
    sessionPersistedToBatch = false;
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

  /// Writes the just-finished scan session into its bound [scanBatch]:
  /// copies every captured image into the batch container, grades each
  /// decoded sheet against the loaded Final answer key (if any), and
  /// attaches a [LocalScanResult]. Idempotent per session via
  /// [sessionPersistedToBatch].
  Future<void> persistCapturedSessionToBatch() async {
    final batch = scanBatch;
    if (batch == null || sessionPersistedToBatch || isSavingToBatch) return;
    if (scannedResults.isEmpty) return;

    isSavingToBatch = true;
    batchSaveError = null;
    notifyListeners();

    final answerKey = answerKeys[batch.examCode];
    final firebaseUser = FirebaseAuth.instance.currentUser;
    final uid = firebaseUser?.uid ?? '';
    final name = firebaseUser?.displayName ?? currentUser?.displayName ?? 'Unknown';

    var savedScans = 0;
    var savedGraded = 0;
    try {
      final pairCount =
          capturedPages.length < scannedResults.length ? capturedPages.length : scannedResults.length;
      for (var i = 0; i < pairCount; i++) {
        final decoded = scannedResults[i];
        final scored = scoreOmrResult(decoded, answerKey);
        final graded = scored.totalGraded > 0;
        final result = LocalScanResult(
          rawScore: scored.rawScore,
          totalGraded: scored.totalGraded,
          totalItems: scored.items.length,
          percentage: scored.percentage,
          status: graded ? 'Graded' : 'Ungraded',
          scannedAt: DateTime.now(),
          processedByUid: uid,
          processedByName: name,
        );
        await batchRepository.addScan(
          batchId: batch.id,
          decoded: decoded,
          sourceImage: File(capturedPages[i].path),
          result: result,
        );
        savedScans++;
        if (graded) savedGraded++;
      }
      // Refresh the bound batch so callers see the new counts/status.
      final refreshed = await batchRepository.getBatchById(batch.id);
      if (refreshed != null) scanBatch = refreshed;

      savedScanCount = savedScans;
      savedGradedCount = savedGraded;
      sessionPersistedToBatch = true;
    } catch (e) {
      batchSaveError = 'Could not save the scans to the batch: $e';
    } finally {
      isSavingToBatch = false;
      notifyListeners();
    }
  }

  /// App-external "omr_debug" folder for [processCapturedPages]'s debug
  /// visualization images. Returns null (silently) if unavailable.
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
