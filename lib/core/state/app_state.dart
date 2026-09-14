import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import '../../models/user.dart';
import '../omr/exam_score.dart';
import '../omr/name_ocr_service.dart';
import '../omr/omr_decoder.dart';
import '../omr/omr_scorer.dart';
import '../omr/omr_templates.dart';
import '../services/batch_repository.dart';
import '../services/local_batch_repository.dart';
import '../services/local_storage_service.dart';
import '../sync/cloud_restore_service.dart';
import '../sync/sync_client.dart';
import '../sync/sync_job.dart';
import '../sync/sync_manager.dart';
import '../utils/omr_perf_log.dart';

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

class _CropNameFieldsRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final String lastNameOutPath;
  final String firstNameOutPath;
  final String middleInitialOutPath;
  const _CropNameFieldsRequest(
    this.imagePath,
    this.template,
    this.lastNameOutPath,
    this.firstNameOutPath,
    this.middleInitialOutPath,
  );
}

/// Runs [OmrDecoder.cropNameFields] on a background isolate — pure OpenCV
/// pixel work, safe off the main isolate unlike the OCR step itself (see
/// NameOcrService, which must run on the main isolate as it's a platform
/// channel call). Takes the original captured photo, not the (much
/// lower-resolution) rectified display copy — see cropNameFields' doc
/// comment for why.
({String lastName, String firstName, String middleInitial})? _cropNameFields(_CropNameFieldsRequest request) {
  return const OmrDecoder().cropNameFields(
    request.imagePath,
    request.template,
    lastNameOutPath: request.lastNameOutPath,
    firstNameOutPath: request.firstNameOutPath,
    middleInitialOutPath: request.middleInitialOutPath,
  );
}

/// Whether [a] and [b] (both last names, case-insensitive) look like
/// different people rather than the same name with a bit of OCR noise —
/// used by [AppState.finishRescan] to catch a rescan accidentally done
/// against a *different* physical sheet. A small edit-distance bound
/// (scaled to length, floor of 2) tolerates a typical single-letter OCR
/// misread; anything past that reads as a genuinely different name.
bool _namesLikelyDiffer(String a, String b) {
  final la = a.trim().toLowerCase();
  final lb = b.trim().toLowerCase();
  if (la.isEmpty || lb.isEmpty || la == lb) return false;
  final distance = _levenshteinDistance(la, lb);
  final threshold = math.max(2, (math.max(la.length, lb.length) * 0.3).round());
  return distance > threshold;
}

/// Classic edit-distance DP — see NameOcrService's own copy for the same
/// algorithm applied to a different comparison (label-vs-recognized-text
/// there, name-vs-name here); kept separate since one lives in a
/// native-only file and the other needs to run from this shared file.
int _levenshteinDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var previous = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0);
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      current[j] = [current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost].reduce((v, e) => v < e ? v : e);
    }
    previous = current;
  }
  return previous[b.length];
}

/// Where one exam's answer key stands relative to the cloud, derived purely
/// from the local `PUSH_ANSWER_KEY` queue jobs — no network read.
enum AnswerKeySyncStatus {
  /// No cloud data plane on this run ([AppState.syncManager] is null).
  notConfigured,

  /// No pending or blocked job — the last push (if any) settled.
  upToDate,

  /// A push is queued or in flight.
  pending,

  /// A push hit `conflict('answer_key_changed')` and is parked as
  /// `blockedConflict`; the user must adopt the cloud copy or force-push.
  conflict,
}

/// Builds the [LocalScanResult] persisted for one scanned sheet from the
/// exam-aware [ExamScore] the official scoring layer produces.
///
/// Used by BOTH persistence paths ([AppState.persistCapturedSessionToBatch]
/// for a fresh capture and [AppState.finishRescan] for a retake) so the two
/// always persist an identically-computed result — there is no path left on
/// the old generic scorer.
///
///  * [examScore] is `computeExamScoreForCode(scored)`. It is null only
///    when no exam template is registered for `scored.examCode`; in that
///    case the pre-exam-aware generic values are kept so an unrecognised
///    exam still persists something.
///  * `rawScore` / `totalItems` / the `tat*` breakdown come straight from
///    [ExamScore]. For TAT, `rawScore` is the 160-point total and
///    `totalItems` is 130; for AT / QTM `rawScore` is the correct-answer
///    count and `totalItems` is the fixed 72 / 60.
///  * `percentage` is the Admission Test's official `rawScore / 72 * 100`
///    when [ExamScore.hasOfficialPercentage]. QTM and TAT have no official
///    percentage, so to avoid changing the meaning of the non-nullable
///    `LocalScanResult.percentage` field (and its result-screen / archive /
///    batch-average consumers) in this local-persistence-only phase, they
///    keep the existing generic `scored.percentage`. This is a documented
///    compatibility shim, not an invented rule; per-exam percentage
///    semantics are for the Result UI / Supabase phases.
///  * `status` keeps the existing answer-key-availability rule
///    ([ExamScore.isGraded] is `totalGraded > 0`).
@visibleForTesting
LocalScanResult buildLocalScanResult(
  ScoredResult scored,
  ExamScore? examScore, {
  required String processedByUid,
  required String processedByName,
  DateTime? scannedAt,
}) {
  final now = scannedAt ?? DateTime.now();

  if (examScore == null) {
    final graded = scored.totalGraded > 0;
    return LocalScanResult(
      rawScore: scored.rawScore,
      totalGraded: scored.totalGraded,
      totalItems: scored.items.length,
      percentage: scored.percentage,
      status: graded ? 'Graded' : 'Ungraded',
      scannedAt: now,
      processedByUid: processedByUid,
      processedByName: processedByName,
    );
  }

  final percentage = examScore.hasOfficialPercentage
      ? examScore.percentage
      : scored.percentage;

  return LocalScanResult(
    rawScore: examScore.rawScore,
    totalGraded: examScore.totalGraded,
    totalItems: examScore.totalItems,
    percentage: percentage,
    status: examScore.isGraded ? 'Graded' : 'Ungraded',
    scannedAt: now,
    processedByUid: processedByUid,
    processedByName: processedByName,
    tatTest1Correct: examScore.tatTest1Correct,
    tatTest1Wrong: examScore.tatTest1Wrong,
    tatTest1Score: examScore.tatTest1Score,
    tatTest2Correct: examScore.tatTest2Correct,
    tatTest2Wrong: examScore.tatTest2Wrong,
    tatTest2Score: examScore.tatTest2Score,
    tatTest3Correct: examScore.tatTest3Correct,
    tatTest3Wrong: examScore.tatTest3Wrong,
    tatTest3Score: examScore.tatTest3Score,
    tatTotal: examScore.tatTotal,
  );
}

/// Monotonic counter backing [generateExamineeId] — mirrors the same
/// millis+counter pattern [SyncJob.newId] already uses elsewhere in this
/// codebase as its "sufficiently unique ID" convention (no UUID package is
/// a dependency of this project).
int _examineeIdCounter = 0;

/// A fresh, sufficiently-unique generated Examinee ID for one scan record.
///
/// This is **Option A**: an identifier for this one scan/examination
/// record, never a permanent cross-exam applicant identity, and never the
/// scan's own database primary key (a caller must not treat it as such).
/// [now] is injectable for deterministic tests; production callers always
/// omit it.
@visibleForTesting
String generateExamineeId([DateTime? now]) {
  final millis = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final n = _examineeIdCounter++;
  return 'EX-$millis-$n';
}

/// Builds the automatic [ExamineeInfo] for a freshly-captured scan —
/// always non-null, always carrying a freshly [generateId]d Examinee ID,
/// with each OCR-guessed name field independently present or blank (never
/// a placeholder like `"UNKNOWN"`). Used by
/// [AppState.persistCapturedSessionToBatch] for every new scan, regardless
/// of whether OCR read any name field at all — the generated ID no longer
/// depends on OCR succeeding.
@visibleForTesting
ExamineeInfo buildAutoExaminee({
  String? ocrLastNameGuess,
  String? ocrFirstNameGuess,
  String? ocrMiddleNameGuess,
  required String Function() generateId,
}) {
  return ExamineeInfo(
    lastName: ocrLastNameGuess ?? '',
    firstName: ocrFirstNameGuess ?? '',
    middleName: ocrMiddleNameGuess ?? '',
    examineeNumber: generateId(),
  );
}

/// Resolves what [AppState.finishRescan] should pass as the rescanned
/// sheet's `examinee` (contract: `null` means "keep the existing tag
/// exactly as-is" — see [BatchRepository.replaceScan]).
///
///  * No generated ID yet on [existingExaminee] (a legacy scan predating
///    this feature, or `existingExaminee == null`): always returns a fresh
///    [ExamineeInfo] carrying a newly [generateId]d Examinee ID — a rescan
///    must never leave a record permanently id-less — refreshing names
///    from this pass's OCR where available and otherwise falling back to
///    whatever [existingExaminee] already had.
///  * An existing generated ID is already present and the tag is not yet
///    fully complete (see [ExamineeInfo.isComplete]) and this pass's OCR
///    produced at least one fresh guess: returns a refreshed name using
///    the SAME existing Examinee ID (never a new one merely because of a
///    rescan).
///  * Otherwise (a fully-tagged existing record, or no fresh OCR to
///    refresh with): returns `null` — the existing tag is left untouched.
@visibleForTesting
ExamineeInfo? resolveRescanExaminee({
  required ExamineeInfo? existingExaminee,
  String? ocrLastNameGuess,
  String? ocrFirstNameGuess,
  String? ocrMiddleNameGuess,
  required String Function() generateId,
}) {
  final hasId = existingExaminee != null && existingExaminee.examineeNumber.trim().isNotEmpty;
  final hasFreshOcr =
      ocrLastNameGuess != null || ocrFirstNameGuess != null || ocrMiddleNameGuess != null;

  if (!hasId) {
    return ExamineeInfo(
      lastName: ocrLastNameGuess ?? existingExaminee?.lastName ?? '',
      firstName: ocrFirstNameGuess ?? existingExaminee?.firstName ?? '',
      middleName: ocrMiddleNameGuess ?? existingExaminee?.middleName ?? '',
      examineeNumber: generateId(),
    );
  }

  if (!existingExaminee.isComplete && hasFreshOcr) {
    return ExamineeInfo(
      lastName: ocrLastNameGuess ?? '',
      firstName: ocrFirstNameGuess ?? '',
      middleName: ocrMiddleNameGuess ?? '',
      examineeNumber: existingExaminee.examineeNumber,
    );
  }

  return null;
}

/// A lightweight in-memory app state shared across screens via
/// [AppStateScope] (an InheritedNotifier, so no third-party state package).
class AppState extends ChangeNotifier {
  /// [batchRepository] defaults to a bare [LocalBatchRepository]; the wired
  /// app injects a [SyncingBatchRepository] (paired with [syncManager]) when
  /// the cloud data plane is configured. Existing `AppState()` callers are
  /// unaffected. This phase only holds the dependencies — nothing here
  /// drives the [syncManager].
  AppState({
    BatchRepository? batchRepository,
    this.syncManager,
    this.cloudRestoreService,
    LocalStorageService? localStorage,
    Stream<List<ConnectivityResult>>? connectivityStream,
    this.reconnectSyncDebounce = const Duration(seconds: 2),
  })  : batchRepository = batchRepository ?? LocalBatchRepository(),
        _localStorage = localStorage ?? LocalStorageService() {
    _wireReconnectSync(connectivityStream);
  }

  /// The offline sync coordinator, or null when the cloud data plane is not
  /// configured for this run. Held for later wiring phases (answer-key
  /// push, login/lifecycle control); no code in this phase starts, pauses,
  /// or drains it.
  final SyncManager? syncManager;

  /// The Supabase → GuideGrade cloud-retrieval orchestrator, or null when
  /// the cloud data plane is not configured for this run (mirrors
  /// [syncManager]). v1 is manually triggered only: nothing in [AppState]
  /// calls [CloudRestoreService.restoreAll] automatically — see
  /// CloudArchiveScreen's "Restore from Cloud" action, the only caller of
  /// [CloudRestoreService.restoreAll]. [CloudRestoreService.
  /// restoreImageIfMissing] is additionally called lazily by any screen
  /// that resolves a scan's image and gets `null` back.
  final CloudRestoreService? cloudRestoreService;

  /// The signed-in, Firestore-approved user for this session — null until a
  /// login screen successfully authorizes a sign-in (see
  /// AuthService._authorize) and cleared again on logout. [AppRoutes]'s
  /// route guard keys off this (not just Firebase's own auth state).
  UserModel? currentUser;

  void setCurrentUser(UserModel? user) {
    currentUser = user;
    _applySyncRunStateFor(user);
    notifyListeners();
  }

  /// Runs the offline sync engine only while an **active Guidance Council**
  /// user is signed in; pauses it for a System Administrator, an inactive
  /// account, an unknown role, or logout. No-op when the cloud data plane
  /// is not configured ([syncManager] is null).
  ///
  /// This is the only place [syncManager]'s run state is driven. Role and
  /// active status are read from the app's own [UserModel] — Firebase custom
  /// claims are never inspected here. Pausing stops new jobs from starting
  /// but never deletes the persisted queue, `sync_state.json`, or any
  /// pending job.
  void _applySyncRunStateFor(UserModel? user) {
    final manager = syncManager;
    if (manager == null) return;
    final activeGuidance =
        user != null && user.isActive && user.isGuidanceCouncil;
    if (activeGuidance) {
      unawaited(manager.start());
    } else {
      manager.pause();
    }
  }

  // --- automatic offline -> online synchronization -------------------------
  //
  // A single connectivity subscription (owned here, the sync lifecycle
  // integration point) that, on a *disconnected -> connected* edge, asks the
  // EXISTING [SyncManager] to drain its existing queue via [SyncManager.
  // syncNow] — which pulls every still-pending job's retry backoff forward
  // to now and runs one drain pass. It never touches the queue, jobs,
  // Supabase, Storage, or local data directly, and never revives
  // failedPermanent / blockedConflict jobs. It respects
  // [_applySyncRunStateFor]: the drain fires only while a manager exists and
  // `isActive` (an active Guidance Council session).

  /// How long to wait after a disconnected -> connected edge before asking
  /// the sync manager to drain, so rapid flapping collapses into one
  /// attempt. Injectable so tests need no real 2-second wait.
  final Duration reconnectSyncDebounce;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _reconnectSyncTimer;
  bool _reconnectDisposed = false;

  /// Assume online at startup so only a genuine offline->online transition
  /// (not the first event on an already-online device) triggers a drain.
  bool _wasOnline = true;

  void _wireReconnectSync(Stream<List<ConnectivityResult>>? stream) {
    // No cloud data plane -> nothing to drain, so never subscribe.
    if (stream == null || syncManager == null) return;
    _connectivitySub = stream.listen(
      _onConnectivityChanged,
      onError: (_) {
        // A platform-channel hiccup must never crash the app or the sync
        // engine; connectivity is a best-effort nudge only.
      },
    );
  }

  /// connectivity_plus 7.3.1: `onConnectivityChanged` is
  /// `Stream<List<ConnectivityResult>>`; the list is never empty and
  /// contains `ConnectivityResult.none` only as its sole element when
  /// offline. "Online" therefore means any element other than `none`,
  /// which also covers wifi/mobile/ethernet/vpn/bluetooth reported
  /// simultaneously.
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (_reconnectDisposed) return;
    final online = results.any((r) => r != ConnectivityResult.none);
    final wasOnline = _wasOnline;
    _wasOnline = online;

    if (online && !wasOnline) {
      // Disconnected -> connected: (re)arm a one-shot debounce so rapid
      // flapping collapses into a single drain attempt once things settle.
      _reconnectSyncTimer?.cancel();
      _reconnectSyncTimer = Timer(reconnectSyncDebounce, _fireReconnectSync);
    } else if (!online) {
      // Dropped again before the debounce elapsed: abandon the attempt.
      _reconnectSyncTimer?.cancel();
      _reconnectSyncTimer = null;
    }
  }

  void _fireReconnectSync() {
    _reconnectSyncTimer = null;
    if (_reconnectDisposed) return;
    final manager = syncManager;
    if (manager == null || !manager.isActive) return;
    unawaited(_safeSyncNow(manager));
  }

  Future<void> _safeSyncNow(SyncManager manager) async {
    try {
      await manager.syncNow();
    } catch (error) {
      // Type only — never surface a raw error from a background nudge.
      debugPrint('AppState: reconnect sync failed (${error.runtimeType})');
    }
  }

  @override
  void dispose() {
    if (_reconnectDisposed) return; // idempotent
    _reconnectDisposed = true;
    _reconnectSyncTimer?.cancel();
    _reconnectSyncTimer = null;
    unawaited(_connectivitySub?.cancel());
    _connectivitySub = null;
    super.dispose();
  }

  /// Sheet-layout lookup key for the active exam type. AT | TAT | QTM.
  /// This alone never identifies a scan session — see [scanBatch].
  String activeExamCode = 'AT';

  /// Manually-entered answer keys (see AnswerKeyEntryScreen), one per exam
  /// code that's had a key saved. The scorer only ever reads this map.
  final Map<String, AnswerKey> answerKeys = {};

  final LocalStorageService _localStorage;

  /// The one storage seam for the `Batch -> Scans -> Results` model. A
  /// [SyncingBatchRepository] in the wired app, a bare [LocalBatchRepository]
  /// otherwise; either way the screens only ever see [BatchRepository].
  final BatchRepository batchRepository;

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
      final firebaseUser = FirebaseAuth.instance.currentUser;
      final uid = firebaseUser?.uid ?? '';
      final name = firebaseUser?.displayName ?? currentUser?.displayName ?? 'Unknown';
      final result = buildLocalScanResult(
        scored,
        computeExamScoreForCode(scored),
        processedByUid: uid,
        processedByName: name,
      );
      final rectifiedPath = rectifiedImagePaths.isNotEmpty ? rectifiedImagePaths.last : null;

      // Re-run the same best-effort OCR guess as a fresh scan gets (see
      // persistCapturedSessionToBatch) against the retaken photo, then
      // decide what to do with it:
      //  - No existing tag, or an existing tag staff never confirmed with
      //    an examinee number (i.e. it's itself just a prior OCR guess or
      //    empty): refresh the name from this fresh read, same as a normal
      //    scan's auto-fill.
      //  - An existing tag staff already confirmed (has a number): never
      //    silently overwritten. Instead, if the fresh read's last name
      //    clearly disagrees with the confirmed one, this looks like a
      //    *different* physical sheet was just rescanned into this slot —
      //    abort before saving anything and surface [rescanSaveError]
      //    (already wired to a SnackBar in exam_scanning_screen.dart).
      // See [resolveRescanExaminee] for the exact resolution logic,
      // including the Examinee ID rule: an existing generated ID is always
      // preserved across a rescan, and one is generated fresh only for a
      // record that never had one (e.g. a legacy scan predating this
      // feature) — never merely because a rescan happened.
      LocalScan? existingScan;
      for (final s in batch.scans) {
        if (s.id == scanId) {
          existingScan = s;
          break;
        }
      }
      final existingExaminee = existingScan?.examinee;
      final template = omrTemplates[batch.examCode];
      final nameCropDir = await _prepareNameCropDir();
      String? ocrLastNameGuess;
      String? ocrFirstNameGuess;
      String? ocrMiddleNameGuess;
      if (template != null && nameCropDir != null) {
        try {
          final crops = await compute(
            _cropNameFields,
            _CropNameFieldsRequest(
              capturedPages.last.path,
              template,
              '$nameCropDir/${scanId}_rescan_last.jpg',
              '$nameCropDir/${scanId}_rescan_first.jpg',
              '$nameCropDir/${scanId}_rescan_mi.jpg',
            ),
          );
          if (crops != null) {
            const nameOcr = NameOcrService();
            ocrLastNameGuess = await nameOcr.recognizeName(crops.lastName, fieldLabel: 'Last Name');
            ocrFirstNameGuess = await nameOcr.recognizeName(crops.firstName, fieldLabel: 'First Name');
            ocrMiddleNameGuess = await nameOcr.recognizeName(crops.middleInitial, fieldLabel: 'MI');
          }
        } catch (_) {
          // Leave all three guesses null -- a bad crop/OCR call must never
          // block saving the rescan itself.
        }
      }

      if (existingExaminee != null && existingExaminee.isComplete) {
        if (ocrLastNameGuess != null && _namesLikelyDiffer(existingExaminee.lastName, ocrLastNameGuess)) {
          rescanSaveError = 'This looks like a different sheet: detected "$ocrLastNameGuess", but '
              'this slot is tagged "${existingExaminee.lastName}". Rescan cancelled — clear the '
              'student tag first if you meant to replace it.';
          return false;
        }
      }
      final refreshedExaminee = resolveRescanExaminee(
        existingExaminee: existingExaminee,
        ocrLastNameGuess: ocrLastNameGuess,
        ocrFirstNameGuess: ocrFirstNameGuess,
        ocrMiddleNameGuess: ocrMiddleNameGuess,
        generateId: generateExamineeId,
      );

      final updated = await batchRepository.replaceScan(
        batchId: batch.id,
        scanId: scanId,
        decoded: decoded,
        sourceImage: File(capturedPages.last.path),
        rectifiedImage: rectifiedPath == null ? null : File(rectifiedPath),
        result: result,
        examinee: refreshedExaminee,
        ocrLastNameGuess: ocrLastNameGuess,
        ocrFirstNameGuess: ocrFirstNameGuess,
        ocrMiddleNameGuess: ocrMiddleNameGuess,
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

  /// Tells [AppLockGate] to ignore an `AppLifecycleState.resumed` event
  /// instead of re-locking, for as long as this is true. Set by a screen
  /// that knowingly causes spurious resumes of its own doing (see
  /// ExamScanningScreen's landscape/TAT handling) so that isn't mistaken
  /// for the user actually returning from the background. Not a
  /// notifyListeners()-driven flag — [AppLockGate] reads it directly inside
  /// its own lifecycle callback, so no rebuild is needed either way.
  bool suppressAppLock = false;

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

  /// Saves [key] locally — the source of truth — then, when the cloud data
  /// plane is configured ([syncManager] non-null), mirrors it to the sync
  /// queue: exactly one `PUSH_ANSWER_KEY` job (identity = exam code) plus
  /// one fire-and-forget [SyncManager.wake].
  ///
  /// Sequence: local save → enqueue → wake → return. The local save is
  /// awaited and its exception propagates (nothing is enqueued or woken on
  /// failure). The cloud mirror is best-effort: a queue failure is logged
  /// (type only) and swallowed, never turning a successful local save into
  /// a reported failure. No Supabase/network call is made from here.
  Future<void> setAnswerKey(AnswerKey key) async {
    answerKeys[key.examCode] = key;
    notifyListeners();
    await _localStorage.saveAnswerKeys(answerKeys);
    await _enqueueAnswerKeyPush(key.examCode);
  }

  Future<void> _enqueueAnswerKeyPush(String examCode) async {
    final manager = syncManager;
    if (manager == null) return; // local-only run: nothing to mirror

    var enqueued = false;
    try {
      await manager.queue.enqueue(SyncJob.create(
        type: SyncJobType.pushAnswerKey,
        entityId: examCode,
      ));
      enqueued = true;
    } catch (error) {
      _logSyncFailure(error);
    }
    if (enqueued) {
      unawaited(_safeWake(manager));
    }
  }

  Future<void> _safeWake(SyncManager manager) async {
    try {
      await manager.wake();
    } catch (error) {
      _logSyncFailure(error);
    }
  }

  void _logSyncFailure(Object error) {
    // Type only — matches the sanitized logging used across the sync layer.
    debugPrint('AppState: answer-key sync step failed (${error.runtimeType})');
  }

  /// The cloud-sync standing of [examCode]'s answer key, read only from the
  /// local `PUSH_ANSWER_KEY` jobs (see [AnswerKeySyncStatus]). A
  /// `blockedConflict` job wins over a pending one.
  AnswerKeySyncStatus answerKeySyncStatusFor(String examCode) {
    final manager = syncManager;
    if (manager == null) return AnswerKeySyncStatus.notConfigured;

    final dedupeKey = SyncJob.dedupeKeyFor(
      type: SyncJobType.pushAnswerKey,
      entityId: examCode,
    );
    final jobs = manager.queue.jobsWithDedupeKey(dedupeKey);
    if (jobs.any((j) => j.status == SyncJobStatus.blockedConflict)) {
      return AnswerKeySyncStatus.conflict;
    }
    if (jobs.any((j) =>
        j.status == SyncJobStatus.pending ||
        j.status == SyncJobStatus.inProgress)) {
      return AnswerKeySyncStatus.pending;
    }
    return AnswerKeySyncStatus.upToDate;
  }

  /// A short, user-facing label for [examCode]'s answer-key sync standing —
  /// never an internal code (`blockedConflict` / `answer_key_changed` are
  /// not surfaced). Deliberately separate from [answerKeyStatus], which only
  /// means "a key is loaded in memory", not "the cloud has this key".
  String answerKeySyncLabelFor(String examCode) {
    if (!answerKeys.containsKey(examCode)) return 'Not set';
    switch (answerKeySyncStatusFor(examCode)) {
      case AnswerKeySyncStatus.notConfigured:
        return 'Local';
      case AnswerKeySyncStatus.pending:
        return 'Syncing';
      case AnswerKeySyncStatus.conflict:
        return 'Conflict';
      case AnswerKeySyncStatus.upToDate:
        return 'Synced';
    }
  }

  /// Read-only fetch of the current cloud answer key for [examCode], routed
  /// through the sync layer's [SyncClient] so no screen ever imports or
  /// calls Supabase. Null when there is no cloud data plane on this run.
  ///
  /// The returned [CloudAnswerKeyRead] is already sanitized by the client —
  /// version, answers, updated-by *name* and updated-at only; never a UID,
  /// an email or a token. Callers hold it in memory only.
  Future<CloudAnswerKeyRead?> readCloudAnswerKey(String examCode) {
    final manager = syncManager;
    if (manager == null) return Future<CloudAnswerKeyRead?>.value(null);
    return manager.client.readAnswerKey(examCode);
  }

  /// Resolve an answer-key conflict by taking the cloud copy: overwrite the
  /// local [AnswerKey] with [answers], persist it, set the local sync
  /// baseline to the cloud [cloudVersion] / [updatedAt], and drop the parked
  /// `PUSH_ANSWER_KEY` job(s). No push is enqueued and no network call is
  /// made.
  Future<void> adoptAnswerKeyFromCloud(
    String examCode, {
    required int cloudVersion,
    required Map<String, String> answers,
    required DateTime updatedAt,
  }) async {
    answerKeys[examCode] =
        AnswerKey(examCode: examCode, correctChoices: Map.of(answers));
    notifyListeners();
    await _localStorage.saveAnswerKeys(answerKeys);

    final manager = syncManager;
    if (manager == null) return;

    manager.queue.state.setAnswerKeyPushed(
      examCode,
      version: cloudVersion,
      updatedAt: updatedAt.toUtc(),
    );
    await _safeSaveState(manager);
    await _removeAnswerKeyJobs(examCode, manager);
  }

  /// Resolve an answer-key conflict by keeping the local copy: drop the
  /// parked job(s) and enqueue a fresh `PUSH_ANSWER_KEY` whose [SyncJob.meta]
  /// carries only `force=true` and the [expectedCloudVersion] the user just
  /// reviewed, then wake the manager once. The local [AnswerKey] is left
  /// unchanged; the guarded force push in `SupabaseSyncClient` still refuses
  /// if the cloud moved past [expectedCloudVersion].
  Future<void> prepareAnswerKeyForcePush(
    String examCode,
    int expectedCloudVersion,
  ) async {
    final manager = syncManager;
    if (manager == null) return;

    await _removeAnswerKeyJobs(examCode, manager);

    var enqueued = false;
    try {
      await manager.queue.enqueue(SyncJob.create(
        type: SyncJobType.pushAnswerKey,
        entityId: examCode,
        meta: {
          'force': 'true',
          'expectedCloudVersion': expectedCloudVersion.toString(),
        },
      ));
      enqueued = true;
    } catch (error) {
      _logSyncFailure(error);
    }
    if (enqueued) {
      unawaited(_safeWake(manager));
    }
  }

  /// Remove every `PUSH_ANSWER_KEY` job for [examCode] that is not already
  /// running. Awaited (this is not a hot path) and best-effort per job.
  Future<void> _removeAnswerKeyJobs(
    String examCode,
    SyncManager manager,
  ) async {
    final dedupeKey = SyncJob.dedupeKeyFor(
      type: SyncJobType.pushAnswerKey,
      entityId: examCode,
    );
    for (final job in manager.queue.jobsWithDedupeKey(dedupeKey)) {
      if (job.status == SyncJobStatus.inProgress) continue;
      try {
        await manager.queue.remove(job.id);
      } catch (error) {
        _logSyncFailure(error);
      }
    }
  }

  Future<void> _safeSaveState(SyncManager manager) async {
    try {
      await manager.queue.saveState();
    } catch (error) {
      _logSyncFailure(error);
    }
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
      final pageSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      final decodeSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      try {
        final result = await compute(_decodeOmrPage, _OmrDecodeRequest(page.path, template));
        scannedResults.add(result);
      } catch (e) {
        errors.add('Sheet $pageIndex: $e');
      }
      final decodeMs = decodeSw?.elapsedMilliseconds ?? 0;
      final debugSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      if (debugDir != null) {
        try {
          await compute(_saveDebugVisualization, _DebugVizRequest(page.path, template, debugDir, pageIndex));
        } catch (_) {
          // Diagnostic-only; never let a debug-image failure block real results.
        }
      }
      final debugMs = debugSw?.elapsedMilliseconds ?? 0;
      // Display-only, and computed by a call that never shares any state
      // with the real decode above (see rectifyForOverlay's doc comment) —
      // a failure here must never affect scannedResults or block scanning.
      String? rectifiedPath;
      final rectifySw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
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
      final rectifyMs = rectifySw?.elapsedMilliseconds ?? 0;
      rectifiedImagePaths.add(rectifiedPath);
      if (pageSw != null) {
        omrPerfLog(
          'page pageIndex=$pageIndex decode=${decodeMs}ms debugViz=${debugMs}ms '
          'rectify=${rectifyMs}ms total=${pageSw.elapsedMilliseconds}ms',
        );
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
    // Must be captured now, before this session's own addScan calls below
    // start growing batch.scans — see sessionScanOffset's doc comment.
    sessionScanOffset = batch.scans.length;
    notifyListeners();

    final answerKey = answerKeys[batch.examCode];
    final firebaseUser = FirebaseAuth.instance.currentUser;
    final uid = firebaseUser?.uid ?? '';
    final name = firebaseUser?.displayName ?? currentUser?.displayName ?? 'Unknown';
    // Both null-checked below; a missing template or crop dir just means no
    // OCR suggestion for this batch, never a blocked save.
    final template = omrTemplates[batch.examCode];
    final nameCropDir = await _prepareNameCropDir();
    const nameOcr = NameOcrService();

    var savedScans = 0;
    var savedGraded = 0;
    final persistBatchSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
    try {
      final pairCount =
          capturedPages.length < scannedResults.length ? capturedPages.length : scannedResults.length;
      for (var i = 0; i < pairCount; i++) {
        final persistPageSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
        final decoded = scannedResults[i];
        final scored = scoreOmrResult(decoded, answerKey);
        final graded = scored.totalGraded > 0;
        final result = buildLocalScanResult(
          scored,
          computeExamScoreForCode(scored),
          processedByUid: uid,
          processedByName: name,
        );
        final rectifiedPath = i < rectifiedImagePaths.length ? rectifiedImagePaths[i] : null;

        // Best-effort on-device OCR suggestion, used to pre-fill the name —
        // never blocks saving, and never invents a placeholder when OCR
        // fails or only partially reads. See NameOcrService's doc comment
        // on why a guess can come back null. The scan is auto-saved with a
        // freshly generated Examinee ID regardless of what OCR returns —
        // see [autoExaminee] below and [buildAutoExaminee]/
        // [generateExamineeId]. Manual Tag Student remains available purely
        // as a correction mechanism for the name (and, if needed, the ID).
        String? ocrLastNameGuess;
        String? ocrFirstNameGuess;
        String? ocrMiddleNameGuess;
        final ocrCropSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
        var ocrRecognizeMs = 0;
        if (template != null && nameCropDir != null) {
          try {
            final crops = await compute(
              _cropNameFields,
              _CropNameFieldsRequest(
                capturedPages[i].path,
                template,
                '$nameCropDir/${scanRef}_${i}_last.jpg',
                '$nameCropDir/${scanRef}_${i}_first.jpg',
                '$nameCropDir/${scanRef}_${i}_mi.jpg',
              ),
            );
            if (crops != null) {
              final ocrRecognizeSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
              ocrLastNameGuess = await nameOcr.recognizeName(crops.lastName, fieldLabel: 'Last Name');
              ocrFirstNameGuess = await nameOcr.recognizeName(crops.firstName, fieldLabel: 'First Name');
              ocrMiddleNameGuess = await nameOcr.recognizeName(crops.middleInitial, fieldLabel: 'MI');
              if (ocrRecognizeSw != null) ocrRecognizeMs = ocrRecognizeSw.elapsedMilliseconds;
            }
          } catch (_) {
            // Leave all three guesses null — a bad crop/OCR call must
            // never block saving the scan itself.
          }
        }
        final ocrCropMs = ocrCropSw?.elapsedMilliseconds ?? 0;
        final autoExaminee = buildAutoExaminee(
          ocrLastNameGuess: ocrLastNameGuess,
          ocrFirstNameGuess: ocrFirstNameGuess,
          ocrMiddleNameGuess: ocrMiddleNameGuess,
          generateId: generateExamineeId,
        );

        final addScanSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
        try {
          await batchRepository.addScan(
            batchId: batch.id,
            decoded: decoded,
            sourceImage: File(capturedPages[i].path),
            rectifiedImage: rectifiedPath == null ? null : File(rectifiedPath),
            result: result,
            examinee: autoExaminee,
            ocrLastNameGuess: ocrLastNameGuess,
            ocrFirstNameGuess: ocrFirstNameGuess,
            ocrMiddleNameGuess: ocrMiddleNameGuess,
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
        } finally {
          if (persistPageSw != null) {
            omrPerfLog(
              'persist pageIndex=${i + 1} ocrCrop=${ocrCropMs}ms '
              'ocrRecognize=${ocrRecognizeMs}ms addScan=${addScanSw?.elapsedMilliseconds ?? 0}ms '
              'total=${persistPageSw.elapsedMilliseconds}ms',
            );
          }
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
      if (persistBatchSw != null) {
        omrPerfLog(
          'persistBatch pages=$savedScans total=${persistBatchSw.elapsedMilliseconds}ms',
        );
      }
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
  /// visualization images. Returns null (silently) if unavailable. Public
  /// so [ExamScanningScreen] can reuse the same folder to dump a debug
  /// snapshot of a REJECTED capture too (see its own `_capture`'s
  /// misalignment branch) — otherwise a "Page not fully detected" photo
  /// leaves no trace anywhere to diagnose after the fact, since it never
  /// reaches [processCapturedPages] at all.
  Future<String?> prepareDebugImagesDir() => _prepareDebugImagesDir();

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

  /// Scratch space for the Last Name/First Name crops fed to on-device OCR
  /// (see NameOcrService) — small, transient images, never referenced by a
  /// saved [LocalScan]. Lives under the OS temp directory like
  /// [_prepareRectifiedImagesDir]'s own folder, so it's cleared the same way
  /// (no explicit cleanup here, matching that existing precedent).
  Future<String?> _prepareNameCropDir() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/omr_name_crops');
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
