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

class _RectifyRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final String outputPath;
  const _RectifyRequest(this.imagePath, this.template, this.outputPath);
}

/// Runs [OmrDecoder.rectifyForOverlay] — entirely separate from
/// [_decodeOmrPage]/`decode()`, see that method's doc comment. Used only to
/// get a display-quality perspective-corrected image for the graded overlay
/// in ScannedImageViewerScreen; never feeds back into scoring.
String? _rectifyOmrPage(_RectifyRequest request) {
  return const OmrDecoder().rectifyForOverlay(request.imagePath, request.template, request.outputPath);
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
    sessionScanOffset = 0;
    rescanScanId = null;
    notifyListeners();
  }

  void clearScanSession() {
    scanBatch = null;
    scanRef = null;
    sessionScanOffset = 0;
    rescanScanId = null;
    notifyListeners();
  }

  /// Which existing scan (already in [scanBatch]) an in-progress capture
  /// will replace, or null for a normal scan session. Set by [startRescan];
  /// cleared by [finishRescan]/[cancelRescan]/[startScanSession]/
  /// [clearScanSession]. ExamScanningScreen routes completion through
  /// [finishRescan] instead of [processCapturedPages]'s normal
  /// append-to-batch path while this is set.
  String? rescanScanId;

  /// Null when [scanBatch] may still accept another captured page;
  /// otherwise the exact message to show for why it can't (matches the
  /// wording [BatchScanLimitExceededException] throws at the real save
  /// path). Counts both what [scanBatch] already has saved *and* what this
  /// session has captured but not yet persisted (capturedPages) — both will
  /// occupy a slot once [persistCapturedSessionToBatch] runs — so capture
  /// stops right at the cap instead of letting a whole extra multi-sheet
  /// session get captured only to be rejected sheet-by-sheet at save time.
  /// Always null while rescanning ([rescanScanId] set): a rescan replaces
  /// an existing scan, never adds one, so it never touches this cap.
  ///
  /// This is a UI-layer convenience only — [ExamScanningScreen] uses it to
  /// block the capture button and its own "Scan Next" action *before*
  /// wasting a photo, not as the actual enforcement. The real gate is
  /// [BatchScanLimitExceededException] at [BatchRepository.addScan], which
  /// this can never bypass or substitute for (a future screen that skips
  /// this getter still hits that one).
  String? get scanLimitBlockMessage {
    if (rescanScanId != null) return null;
    final batch = scanBatch;
    if (batch == null || !batch.hasScanLimit) return null;
    final used = batch.scanCount + capturedPages.length;
    if (used < batch.expectedCount) return null;
    return 'This batch has reached its scan limit of ${batch.expectedCount} examinees. '
        'Please modify the batch in Batch Management if you need to increase the limit.';
  }

  /// Begins a single-sheet rescan of [scan] (already stored in [batch]):
  /// capture flow works exactly as a normal scan, but [finishRescan]
  /// overwrites [scan] in place instead of appending a new one. Discards
  /// any in-progress (unsaved) capture first, same as starting a normal
  /// session.
  void startRescan(LocalBatch batch, LocalScan scan) {
    resetScanProgress();
    scanBatch = batch;
    activeExamCode = batch.examCode;
    rescanScanId = scan.id;
    notifyListeners();
  }

  /// Abandons an in-progress rescan (e.g. the user backed out of the
  /// scanner) without touching the batch.
  void cancelRescan() {
    rescanScanId = null;
    resetScanProgress();
    notifyListeners();
  }

  /// Outcome of the last [finishRescan] run.
  bool isSavingRescan = false;
  String? rescanSaveError;

  /// Replaces [rescanScanId]'s stored photo/decode/result with whichever
  /// captured page was decoded *last* (so retaking the photo mid-session,
  /// by simply capturing again, naturally picks up the newest attempt
  /// rather than the first). Requires at least one successfully decoded
  /// page. Leaves [scanBatch] refreshed and clears the rescan/capture state
  /// on success. Returns whether it succeeded — see [rescanSaveError] for
  /// the failure message.
  Future<bool> finishRescan() async {
    final batch = scanBatch;
    final scanId = rescanScanId;
    if (batch == null || scanId == null) return false;
    if (capturedPages.isEmpty || scannedResults.isEmpty) return false;

    isSavingRescan = true;
    rescanSaveError = null;
    notifyListeners();

    try {
      final decoded = scannedResults.last;
      final answerKey = answerKeys[batch.examCode];
      final scored = scoreOmrResult(decoded, answerKey);
      final graded = scored.totalGraded > 0;
      final firebaseUser = FirebaseAuth.instance.currentUser;
      final uid = firebaseUser?.uid ?? '';
      final name = firebaseUser?.displayName ?? currentUser?.displayName ?? 'Unknown';
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
      final rectifiedPath = rectifiedImagePaths.isNotEmpty ? rectifiedImagePaths.last : null;
      final updated = await batchRepository.replaceScan(
        batchId: batch.id,
        scanId: scanId,
        decoded: decoded,
        sourceImage: File(capturedPages.last.path),
        rectifiedImage: rectifiedPath == null ? null : File(rectifiedPath),
        result: result,
      );
      scanBatch = updated;
      rescanScanId = null;
      resetScanProgress();
      return true;
    } catch (e) {
      rescanSaveError = 'Could not save the rescan: $e';
      return false;
    } finally {
      isSavingRescan = false;
      notifyListeners();
    }
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

  /// Perspective-corrected copy of each captured page, one per page (same
  /// index as [scannedResults]), used only to draw the per-item graded
  /// overlay in ScannedImageViewerScreen — null for a page where
  /// rectification failed (the sheet still scores normally; this is
  /// display-only and best-effort). Populated by [processCapturedPages] via
  /// a call entirely separate from the real decode — see
  /// [OmrDecoder.rectifyForOverlay]. Cleared by [resetScanProgress].
  final List<String?> rectifiedImagePaths = [];

  bool isProcessingScans = false;
  String? scanProcessingError;

  /// Outcome of the last [persistCapturedSessionToBatch] run.
  bool isSavingToBatch = false;
  int savedScanCount = 0;
  int savedGradedCount = 0;
  String? batchSaveError;
  bool sessionPersistedToBatch = false;

  /// How many scans [scanBatch] already held *before* this session's sheets
  /// were appended by [persistCapturedSessionToBatch] — i.e. the index this
  /// session's sheet 0 lands at in `batch.scans`. Scanning onto a batch that
  /// already has scans from an earlier session (continuing a batch) means
  /// `batch.scans` is longer than this session's own sheet list, so a raw
  /// `batch.scans[sheetIndex]` lookup silently grabs an *earlier* session's
  /// (already-tagged) scan instead of this one's — this offset is what
  /// callers (Exam Results' per-sheet examinee display/tagging) must add to
  /// `sheetIndex` first. Set once, right before this session's scans are
  /// appended; reset to 0 by [startScanSession]/[clearScanSession].
  int sessionScanOffset = 0;

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
    rectifiedImagePaths.clear();
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
    rectifiedImagePaths.clear();
    notifyListeners();

    final debugDir = await _prepareDebugImagesDir();
    lastDebugImagesDir = debugDir;
    final rectifiedDir = await _prepareRectifiedImagesDir();

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
      // Display-only, and computed by a call that never shares any state
      // with the real decode above (see rectifyForOverlay's doc comment) —
      // a failure here must never affect scannedResults or block scanning.
      String? rectifiedPath;
      if (rectifiedDir != null) {
        try {
          rectifiedPath = await compute(
            _rectifyOmrPage,
            _RectifyRequest(page.path, template, '$rectifiedDir/${scanRef}_$pageIndex.jpg'),
          );
        } catch (_) {
          rectifiedPath = null;
        }
      }
      rectifiedImagePaths.add(rectifiedPath);
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
    // Must be captured now, before this session's own addScan calls below
    // start growing batch.scans — see sessionScanOffset's doc comment.
    sessionScanOffset = batch.scans.length;
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
        final rectifiedPath = i < rectifiedImagePaths.length ? rectifiedImagePaths[i] : null;
        try {
          await batchRepository.addScan(
            batchId: batch.id,
            decoded: decoded,
            sourceImage: File(capturedPages[i].path),
            rectifiedImage: rectifiedPath == null ? null : File(rectifiedPath),
            result: result,
          );
          savedScans++;
          if (graded) savedGraded++;
        } on BatchScanLimitExceededException catch (e) {
          // The capture-time check (see scanLimitBlockMessage) should have
          // stopped this from happening in the first place, but this is the
          // real gate: stop saving right here rather than throwing away
          // whichever sheets *did* fit under the cap by letting the outer
          // catch below discard everything this loop already saved.
          batchSaveError = savedScans == 0
              ? e.message
              : 'Saved $savedScans of $pairCount scans to ${batch.batchCode} — $e';
          break;
        }
      }
      // Refresh the bound batch so callers see the new counts/status.
      final refreshed = await batchRepository.getBatchById(batch.id);
      if (refreshed != null) scanBatch = refreshed;

      savedScanCount = savedScans;
      savedGradedCount = savedGraded;
      // Marked persisted (not retried) even when the limit cut it short —
      // whatever did save is durably in the batch, and re-running this
      // would duplicate those instead of picking up where it left off.
      sessionPersistedToBatch = true;
    } catch (e) {
      batchSaveError = 'Could not save the scans to the batch: $e';
    } finally {
      isSavingToBatch = false;
      notifyListeners();
    }
  }

  /// Tags (or clears, when [examinee] is null/empty) the student for the
  /// scan at [sheetIndex] of the just-persisted session. [sheetIndex] is
  /// relative to *this session's own* sheets, not `batch.scans` directly —
  /// see [sessionScanOffset]. Safe no-op until
  /// [persistCapturedSessionToBatch] has run and the batch holds that many
  /// scans. Keeps [scanBatch] refreshed so the results screen reflects it.
  Future<void> tagSessionScanExaminee(int sheetIndex, ExamineeInfo? examinee) async {
    final batch = scanBatch;
    final index = sessionScanOffset + sheetIndex;
    if (batch == null || sheetIndex < 0 || index >= batch.scans.length) return;
    final scanId = batch.scans[index].id;
    final updated = await batchRepository.setScanExaminee(
      batchId: batch.id,
      scanId: scanId,
      examinee: examinee,
    );
    scanBatch = updated;
    notifyListeners();
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

  /// App-private cache folder for [processCapturedPages]'s rectified
  /// (display-only, see [rectifiedImagePaths]) images. Returns null
  /// (silently) if unavailable — that page's overlay just won't be
  /// available, nothing else is affected.
  Future<String?> _prepareRectifiedImagesDir() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/omr_rectified');
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
