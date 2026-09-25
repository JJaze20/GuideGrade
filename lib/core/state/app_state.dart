import 'dart:async';
import 'dart:io';

// buildLocalScanResult moved to scan_rescoring.dart (pure Dart) and is
// re-exported so existing `app_state.dart` imports keep working.
export '../omr/scan_rescoring.dart' show buildLocalScanResult;

import 'package:camera/camera.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/answer_correction.dart';
import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import '../../models/user.dart';
import '../omr/exam_score.dart';
import '../omr/omr_decoder.dart';
import '../omr/omr_scorer.dart';
import '../omr/scan_rescoring.dart';
import '../omr/omr_templates.dart';
import '../services/batch_repository.dart';
import '../services/local_batch_repository.dart';
import '../services/local_storage_service.dart';
import '../sync/batch_archive_coordinator.dart';
import '../sync/cloud_restore_service.dart';
import '../sync/sync_client.dart';
import '../sync/sync_job.dart';
import '../sync/sync_manager.dart';
import '../utils/omr_perf_log.dart';

class _OmrDecodeRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final String? rectifiedOutputPath;
  final bool diagnosticsEnabled;
  const _OmrDecodeRequest(this.imagePath, this.template,
      {this.rectifiedOutputPath, this.diagnosticsEnabled = false});
}

OmrScanResult _decodeOmrPage(_OmrDecodeRequest request) {
  // Each compute() call gets its own isolate memory, so the diagnostic
  // flag has to be set fresh here, every call — see
  // OmrDecoder.setDiagnosticsEnabled's doc comment.
  OmrDecoder.setDiagnosticsEnabled(request.diagnosticsEnabled);
  return const OmrDecoder().decode(request.imagePath, request.template,
      rectifiedOutputPath: request.rectifiedOutputPath);
}

class _DebugVizRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final String outputDir;
  final int pageIndex;

  /// Whether this pass should ALSO emit the verbose per-contour/per-bubble
  /// log. False writes the stage images alone, which is all the "How it was
  /// read" viewer needs.
  final bool verboseLogging;
  const _DebugVizRequest(this.imagePath, this.template, this.outputDir, this.pageIndex,
      {this.verboseLogging = false});
}

void _saveDebugVisualization(_DebugVizRequest request) {
  // Only ever called (see processCapturedPages) when diagnostics are on,
  // but set explicitly anyway rather than assuming that -- this isolate
  // has no memory of what the calling isolate's flag was.
  // Only the LOGGING follows this flag. saveDebugVisualization's stage
  // images are written unconditionally -- it contains no reference to the
  // verbose switches -- so the viewer works without paying for thousands of
  // synchronous print() calls per sheet, which is what made dim-light
  // scanning crawl.
  OmrDecoder.setDiagnosticsEnabled(request.verboseLogging);
  const OmrDecoder().saveDebugVisualization(request.imagePath, request.template, request.outputDir, request.pageIndex);
}

// _rectifyOmrPage/_RectifyRequest (a separate isolate call into
// OmrDecoder.rectifyForOverlay) removed 2026-09-19 -- decode() now writes
// the review/overlay image itself, for every exam type, reusing its own
// already-fitted registration instead of a second independent corner
// search (see decode()'s doc comment and processCapturedPages' reviewOutput
// local). rectifyForOverlay itself is left defined in
// omr_decoder_native.dart in case something else needs a standalone
// rectify later; nothing in this app calls it any more.

class _CropNameFieldsRequest {
  final String imagePath;
  final OmrExamTemplate template;
  final String lastNameOutPath;
  final String firstNameOutPath;
  final String middleNameOutPath;
  const _CropNameFieldsRequest(
    this.imagePath,
    this.template,
    this.lastNameOutPath,
    this.firstNameOutPath,
    this.middleNameOutPath,
  );
}

/// Runs [OmrDecoder.cropNameFields] on a background isolate — pure OpenCV
/// pixel work, safe off the main isolate. Takes the original captured
/// photo, not the (much lower-resolution) rectified display copy — see
/// cropNameFields' doc comment for why.
({String lastName, String firstName, String middleName})? _cropNameFields(_CropNameFieldsRequest request) {
  return const OmrDecoder().cropNameFields(
    request.imagePath,
    request.template,
    lastNameOutPath: request.lastNameOutPath,
    firstNameOutPath: request.firstNameOutPath,
    middleNameOutPath: request.middleNameOutPath,
  );
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

/// What [AppState.correctScanAnswer] / [AppState.resetScanAnswer] did.
class ScanCorrectionOutcome {
  final LocalBatch batch;

  /// The scan after the change (or unchanged when [changed] is false).
  final LocalScan scan;

  /// False for a repeated or no-op request: nothing was recorded, the
  /// revision did not move and nothing was queued to sync.
  final bool changed;

  /// False when the exam has no answer key loaded, so the correction was
  /// recorded but there is no score to recalculate yet.
  final bool scoreRecalculated;

  const ScanCorrectionOutcome({
    required this.batch,
    required this.scan,
    required this.changed,
    this.scoreRecalculated = true,
  });
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
    _wireArchiveCoordinator();
  }

  // --- batch Archived status ------------------------------------------------
  //
  // A batch becomes Archived only when the cloud has confirmed its current
  // saved revision (see BatchLifecycle / BatchArchiveCoordinator). This
  // listens to the sync manager and re-checks after each change to the queue;
  // it never starts, retries or cancels an upload itself, so upload progress
  // and failures stay separate from the batch's lifecycle status. Not wired
  // (and nothing is ever archived) when there is no cloud data plane.

  BatchArchiveCoordinator? _archiveCoordinator;

  void _wireArchiveCoordinator() {
    final manager = syncManager;
    if (manager == null) return;
    _archiveCoordinator = BatchArchiveCoordinator(
      cloudConfigured: true,
      loadBatches: () => batchRepository.getBatches(),
      outstandingJobsFor: (batchId) =>
          manager.queue.jobs.where((j) => j.batchId == batchId).length,
      lastPushedUpdatedAt: (batchId) =>
          manager.queue.state.batchLastPushedUpdatedAt(batchId),
      confirmArchived: (batchId, updatedAt) =>
          batchRepository.confirmBatchArchived(batchId, updatedAt),
    );
    manager.addListener(_onSyncStateChanged);
  }

  void _onSyncStateChanged() {
    if (_reconnectDisposed) return;
    unawaited(refreshBatchArchiveStatus());
  }

  /// Re-checks every batch against the sync layer's records and archives any
  /// whose current revision the cloud has confirmed. Also useful after a
  /// cloud restore. Never throws; a failure just leaves batches as they were.
  Future<void> refreshBatchArchiveStatus() async {
    final coordinator = _archiveCoordinator;
    if (coordinator == null) return;
    try {
      final archived = await coordinator.evaluateAll();
      if (archived.isNotEmpty && !_reconnectDisposed) notifyListeners();
    } catch (error) {
      _logSyncFailure(error);
    }
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

  /// Best-effort "device has a network" flag for UI (e.g. greying out the
  /// load-from-cloud button). Only updated from connectivity events, so it
  /// assumes online until the first change is reported.
  bool get isOnline => _wasOnline;

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
    if (online != wasOnline) notifyListeners();

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
    syncManager?.removeListener(_onSyncStateChanged);
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
  /// page. Also refreshes the persisted name-crop images to match the
  /// retaken photo, but never touches the existing examinee tag — a
  /// rescan means the same physical sheet, just a bad photo, so whatever
  /// name staff already entered stays exactly as it was; use "Edit
  /// student" if the retake reveals a correction is actually needed.
  /// Leaves [scanBatch] refreshed and clears the rescan/capture state on
  /// success. Returns whether it succeeded — see [rescanSaveError] for the
  /// failure message.
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

      // Crop the name fields out of the retaken photo so staff have an
      // up-to-date image to read if they open "Edit student" — pure pixel
      // work, never blocks saving the rescan itself if it fails. The
      // existing examinee tag (names and all) is preserved; the only change
      // that can happen is that a legacy scan with no generated Examinee ID
      // is given one — see [resolveRescanExaminee] for the exact rule (an
      // existing ID is never replaced merely because a rescan happened).
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
      String? nameCropLastPath;
      String? nameCropFirstPath;
      String? nameCropMiddlePath;
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
          nameCropLastPath = crops?.lastName;
          nameCropFirstPath = crops?.firstName;
          nameCropMiddlePath = crops?.middleName;
        } catch (e, st) {
          // Leave all three crop paths null -- a bad crop call must never
          // block saving the rescan itself.
          debugPrint('finishRescan: cropNameFields threw: $e\n$st');
        }
      }

      // No OCR, hence no fresh name guesses: null (keep the tag as-is) when an
      // Examinee ID already exists, otherwise the existing tag plus a new ID.
      final refreshedExaminee = resolveRescanExaminee(
        existingExaminee: existingExaminee,
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
        nameCropLastImage: nameCropLastPath == null ? null : File(nameCropLastPath),
        nameCropFirstImage: nameCropFirstPath == null ? null : File(nameCropFirstPath),
        nameCropMiddleImage: nameCropMiddlePath == null ? null : File(nameCropMiddlePath),
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

  final Map<String, ({OmrScanResult result, String? reviewPath})>
      _capturePreviews = {};

  /// Decode before accepting the photo, so the score can be shown right
  /// after the capture. The result and review image are reused when the
  /// session is compiled, so the sheet is only decoded once.
  Future<OmrScanResult> previewCapturedPage(XFile file) async {
    final template = omrTemplates[activeExamCode];
    if (template == null) throw StateError('No sheet layout is available.');
    final directory = await _prepareRectifiedImagesDir();
    final reviewPath = directory == null ? null
        : '$directory/preview_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final result = await compute(_decodeOmrPage, _OmrDecodeRequest(
      file.path, template, rectifiedOutputPath: reviewPath,
      diagnosticsEnabled: diagnosticsEnabled,
    ));
    final savedReview = reviewPath != null && await File(reviewPath).exists()
        ? reviewPath : null;
    addCapturedPage(file);
    _capturePreviews[file.path] = (result: result, reviewPath: savedReview);
    return result;
  }

  /// Decoded bubble results for the in-progress scan session, one per
  /// captured page, populated by [processCapturedPages]. Cleared by
  /// [resetScanProgress].
  final List<OmrScanResult> scannedResults = [];

  /// Perspective-corrected copy of each captured page, one per page (same
  /// index as [scannedResults]), used only to draw the per-item graded
  /// overlay in ScannedImageViewerScreen — null for a page where
  /// rectification failed (the sheet still scores normally; this is
  /// display-only and best-effort). Populated by [processCapturedPages]:
  /// `decode()` itself writes this image (see its `rectifiedOutputPath`
  /// param), reusing the exact registration it scored bubbles with, rather
  /// than a separate call re-detecting corners independently (that used to
  /// be true for every exam except TAT — see git history 2026-09-19).
  /// Cleared by [resetScanProgress].
  final List<String?> rectifiedImagePaths = [];

  bool isProcessingScans = false;
  String? scanProcessingError;

  /// Opt-in troubleshooting mode (2026-09-19): off by default, matching
  /// ordinary scanning never generating full diagnostic images or verbose
  /// per-bubble/per-candidate logs. When true, [processCapturedPages]
  /// additionally writes [lastDebugImagesDir]'s annotated debug images for
  /// every page and enables verbose fiducial/bubble logging in the decode
  /// isolate (see [OmrDecoder.setDiagnosticsEnabled]). Recognition,
  /// validation, and scoring are identical either way — this only ever
  /// gates extra output, never an input to decoding. Mirrored by
  /// `ExamScanningScreen._diagnosticsEnabled`, which also gates the live
  /// preview's own diagnostic overlay and is the only current UI for
  /// flipping this (debug builds only — see that field's doc comment).
  bool diagnosticsEnabled = false;

  /// Whether to write [lastDebugImagesDir]'s per-stage images, WITHOUT the
  /// verbose decode logging that [diagnosticsEnabled] also turns on.
  ///
  /// Split from [diagnosticsEnabled] because the two have very different
  /// costs and only one of them is what staff actually want to look at. The
  /// verbose side flips [OmrDecoder.setDiagnosticsEnabled], which re-enables
  /// thousands of synchronous `print()` calls per sheet -- that is what made
  /// scanning crawl in dim light, where the expensive full-quadrant fiducial
  /// fallback runs. The images are one extra decode per page, paid once,
  /// after the real decode, and are the only part the "How it was read"
  /// viewer needs.
  ///
  /// Still off by default: a real exam session should not pay for output
  /// nobody opens. Unlike [diagnosticsEnabled] this one is reachable in a
  /// release build, since the people who need to see how a sheet was read
  /// are running release builds.
  bool debugImagesEnabled = false;

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
    _capturePreviews.clear();
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
    // A rescan replaces one archived sheet. Failed attempts must not remain
    // in the compile queue and veto a subsequent good photo.
    if (rescanScanId != null) {
      capturedPages.clear();
      _capturePreviews.clear();
      scannedResults.clear();
      rectifiedImagePaths.clear();
      scanProcessingError = null;
      rescanSaveError = null;
    }
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

    // Ordinary scanning skips debug-image generation entirely -- it isn't
    // just gated at the write site below, the directory is never even
    // prepared. See diagnosticsEnabled's doc comment.
    //
    // Each run gets its own subfolder. The decoder names its output by page
    // slot (`sheet1_inkmap.jpg` and so on), so a shared folder meant run two
    // silently inherited run one's images for any stage it didn't overwrite
    // -- a decode that bailed early wrote only sheet1_FAILED.jpg and left the
    // previous session's ink map sitting there to be shown as if it were
    // this sheet's. Per-run folders make that impossible, and keep the older
    // runs around to compare against instead of deleting them.
    final debugDir = (diagnosticsEnabled || debugImagesEnabled)
        ? await _prepareDebugImagesDir(
            runSubfolder: 'run_${DateTime.now().millisecondsSinceEpoch}')
        : null;
    lastDebugImagesDir = debugDir;
    final rectifiedDir = await _prepareRectifiedImagesDir();

    final errors = <String>[];
    var pageIndex = 0;
    for (final page in capturedPages) {
      pageIndex++;
      final pageSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      final decodeSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      // Every exam type (2026-09-19; previously TAT-only, with every other
      // exam getting a fully separate rectifyForOverlay isolate call and
      // its own independent corner search below) asks decode() to also
      // write the review/overlay image using the exact same registration
      // it scores bubbles with -- see decode()'s own doc comment on this
      // parameter. Timestamped, not a fixed per-page name, so a rescan
      // retry can never display a stale cached copy of a previous
      // attempt's image at the same path.
      final preview = _capturePreviews[page.path];
      final reviewOutput = preview != null ? preview.reviewPath : rectifiedDir != null
          ? '$rectifiedDir/${scanRef}_${pageIndex}_${DateTime.now().microsecondsSinceEpoch}.jpg' : null;
      var decoded = false;
      try {
        final OmrScanResult result = preview?.result ?? await compute<_OmrDecodeRequest, OmrScanResult>(_decodeOmrPage, _OmrDecodeRequest(page.path, template,
            rectifiedOutputPath: reviewOutput, diagnosticsEnabled: diagnosticsEnabled));
        scannedResults.add(result);
        decoded = true;
      } catch (e) {
        errors.add('Sheet $pageIndex: $e');
      }
      final decodeMs = decodeSw?.elapsedMilliseconds ?? 0;
      final debugSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      // debugDir is only ever non-null when diagnosticsEnabled was true at
      // the top of this run (see above), so this whole second decode-alike
      // pass -- illumination-normalize + CLAHE + threshold run a second
      // time, plus several imwrite()s -- never happens during ordinary
      // scanning.
      if (debugDir != null) {
        try {
          await compute(_saveDebugVisualization,
              _DebugVizRequest(page.path, template, debugDir, pageIndex,
                  verboseLogging: diagnosticsEnabled));
        } catch (_) {
          // Diagnostic-only; never let a debug-image failure block real results.
        }
      }
      final debugMs = debugSw?.elapsedMilliseconds ?? 0;
      // Display-only; a failure here (the file was never written, e.g. a
      // decode failure, or the write itself failing) must never affect
      // scannedResults or block scanning -- just leaves no review image.
      final rectifySw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
      final rectifiedPath = decoded && reviewOutput != null && await File(reviewOutput).exists()
          ? reviewOutput
          : null;
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
    // name-crop image for this batch, never a blocked save.
    final template = omrTemplates[batch.examCode];
    final nameCropDir = await _prepareNameCropDir();

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

        // Crop the handwritten name fields so staff have an image to read
        // when they open "Tag Student" — pure pixel work, never blocks
        // saving the scan itself if it fails. The scan is auto-saved with a
        // freshly generated Examinee ID and blank names (see [autoExaminee]
        // below); staff read the crop and type the name in.
        String? nameCropLastPath;
        String? nameCropFirstPath;
        String? nameCropMiddlePath;
        final nameCropSw = kOmrPerfDebug ? (Stopwatch()..start()) : null;
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
            nameCropLastPath = crops?.lastName;
            nameCropFirstPath = crops?.firstName;
            nameCropMiddlePath = crops?.middleName;
          } catch (e, st) {
            // Leave all three crop paths null — a bad crop call must
            // never block saving the scan itself.
            debugPrint('persistCapturedSessionToBatch: cropNameFields threw: $e\n$st');
          }
        }
        final nameCropMs = nameCropSw?.elapsedMilliseconds ?? 0;
        final autoExaminee = buildAutoExaminee(
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
            nameCropLastImage: nameCropLastPath == null ? null : File(nameCropLastPath),
            nameCropFirstImage: nameCropFirstPath == null ? null : File(nameCropFirstPath),
            nameCropMiddleImage: nameCropMiddlePath == null ? null : File(nameCropMiddlePath),
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
              'persist pageIndex=${i + 1} nameCrop=${nameCropMs}ms '
              'addScan=${addScanSw?.elapsedMilliseconds ?? 0}ms '
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

  // --- manual answer corrections ---------------------------------------------

  /// Corrects what one item of a SAVED scan actually shows, then recalculates
  /// that scan's stored score from its answers as they now read.
  ///
  /// What it does and does not touch:
  ///  * the machine-detected answers and the scan image are never edited —
  ///    the correction is appended to the scan's history ([LocalScan.corrections])
  ///    with the original value, the corrected value, who made it, when, and
  ///    an optional reason;
  ///  * the score is rebuilt through the unchanged exam-specific scoring rules
  ///    ([rescoreScan]) and persisted in the SAME write as the history, so
  ///    results, View Scan, archived batches, analytics and the cloud record
  ///    all read one consistent value;
  ///  * the answer key and the student's details are never modified.
  ///
  /// [requestId] makes the call idempotent: an editor keeps one id per open
  /// dialog, so a double tap or a retried save applies the correction once —
  /// and a request that would not change what the item reads as is a no-op
  /// (no new revision, nothing queued to sync).
  Future<ScanCorrectionOutcome> correctScanAnswer({
    required String batchId,
    required String scanId,
    required String sectionName,
    required int itemNumber,
    required CorrectedAnswer value,
    String? reason,
    required String requestId,
  }) =>
      _changeCorrection(
        batchId: batchId,
        scanId: scanId,
        sectionName: sectionName,
        itemNumber: itemNumber,
        requestId: requestId,
        apply: (history, scan, detected, editor) => CorrectionRules.withCorrection(
          history,
          id: requestId,
          scanId: scanId,
          captureRevision: scan.captureRevision,
          detected: detected,
          value: value,
          reason: reason,
          editorUid: editor.uid,
          editorName: editor.name,
          at: DateTime.now(),
        ),
      );

  /// "Reset to detected answer": records a reset for the item so it reads as
  /// the machine detected it again (the earlier correction stays in the
  /// history). Same idempotency and recalculation as [correctScanAnswer]; a
  /// no-op when the item has no active correction.
  Future<ScanCorrectionOutcome> resetScanAnswer({
    required String batchId,
    required String scanId,
    required String sectionName,
    required int itemNumber,
    required String requestId,
  }) =>
      _changeCorrection(
        batchId: batchId,
        scanId: scanId,
        sectionName: sectionName,
        itemNumber: itemNumber,
        requestId: requestId,
        apply: (history, scan, detected, editor) => CorrectionRules.withReset(
          history,
          id: requestId,
          scanId: scanId,
          captureRevision: scan.captureRevision,
          detected: detected,
          editorUid: editor.uid,
          editorName: editor.name,
          at: DateTime.now(),
        ),
      );

  /// The exact user-facing message when a correction cannot be scored
  /// because no answer key is available for its exam, even after trying to
  /// load one — see [_ensureAnswerKeyForCorrection]. Exposed as a constant
  /// so the thrown [StateError] and its tests share one string.
  static const String answerKeyUnavailableForCorrectionMessage =
      'Answer Key is unavailable. The correction cannot be scored and saved.';

  /// Guarantees [examCode]'s answer key is in [answerKeys] before a
  /// correction is scored and saved, so a correction can never be recorded
  /// as if it were graded when it silently wasn't (see [rescoreScan]'s own
  /// doc comment on why it returns the unchanged result with no key).
  ///
  /// Reuses the EXACT existing cloud-key architecture — [readCloudAnswerKey]
  /// / [adoptAnswerKeyFromCloud], the same pair `AnswerKeyEntryScreen`'s own
  /// "load from cloud" action calls — rather than a second implementation.
  /// A key already cached locally is used as-is with no network call.
  ///
  /// Returns the now-available [AnswerKey], or null when it genuinely could
  /// not be made available: no cloud data plane on this device, no cloud
  /// row for this exam, or the read failed.
  Future<AnswerKey?> _ensureAnswerKeyForCorrection(String examCode) async {
    final cached = answerKeys[examCode];
    if (cached != null) return cached;

    CloudAnswerKeyRead? read;
    try {
      read = await readCloudAnswerKey(examCode);
    } catch (_) {
      read = null;
    }
    if (read == null || !read.exists) return null;

    await adoptAnswerKeyFromCloud(
      examCode,
      cloudVersion: read.version!,
      answers: read.answers ?? const {},
      updatedAt: DateTime.tryParse(read.updatedAt ?? '')?.toUtc() ?? DateTime.now().toUtc(),
    );
    return answerKeys[examCode];
  }

  Future<ScanCorrectionOutcome> _changeCorrection({
    required String batchId,
    required String scanId,
    required String sectionName,
    required int itemNumber,
    required String requestId,
    required List<AnswerCorrection> Function(
      List<AnswerCorrection> history,
      LocalScan scan,
      OmrItemResult detected,
      ({String uid, String name}) editor,
    ) apply,
  }) async {
    final batch = await batchRepository.getBatchById(batchId);
    if (batch == null) throw StateError('Batch $batchId does not exist.');
    final scan = batch.scans.where((s) => s.id == scanId).firstOrNull;
    if (scan == null) throw StateError('Scan $scanId does not exist in batch $batchId.');
    // The ORIGINAL detected value, straight from the untouched decode — the
    // item is looked up by section + number because numbers repeat across
    // TAT's sections.
    final detected = scan.decoded.items
        .where((i) => i.sectionName == sectionName && i.itemNumber == itemNumber)
        .firstOrNull;
    if (detected == null) {
      throw StateError('Item $itemNumber in "$sectionName" is not on this sheet.');
    }
    final user = currentUser;
    final editor = (uid: user?.userId ?? '', name: user?.displayName ?? '');
    final history = apply(scan.corrections, scan, detected, editor);
    if (identical(history, scan.corrections) || history.length == scan.corrections.length) {
      return ScanCorrectionOutcome(batch: batch, scan: scan, changed: false);
    }
    // A correction is actually about to be recorded — guarantee it can be
    // scored BEFORE anything is saved. Nothing is written to the repository
    // and nothing is enqueued for sync when this fails: the scan and its
    // result are left exactly as they were.
    final answerKey = await _ensureAnswerKeyForCorrection(batch.examCode);
    if (answerKey == null) {
      throw StateError(answerKeyUnavailableForCorrectionMessage);
    }
    final result = rescoreScan(
      scan: scan.copyWith(corrections: history),
      answerKey: answerKey,
      editorUid: editor.uid,
      editorName: editor.name,
    );
    final updated = await batchRepository.updateScanCorrections(
      batchId: batchId,
      scanId: scanId,
      corrections: history,
      result: result,
    );
    if (scanBatch?.id == updated.id) scanBatch = updated;
    notifyListeners();
    final updatedScan = updated.scans.firstWhere((s) => s.id == scanId);
    // The key was just guaranteed available above, so the save that just
    // happened always recalculated the score — never the stale-result path.
    return ScanCorrectionOutcome(
      batch: updated,
      scan: updatedScan,
      changed: true,
      scoreRecalculated: true,
    );
  }

  /// App-external "omr_debug" folder for [processCapturedPages]'s debug
  /// visualization images. Returns null (silently) if unavailable. Public
  /// so [ExamScanningScreen] can reuse the same folder to dump a debug
  /// snapshot of a REJECTED capture too (see its own `_capture`'s
  /// misalignment branch) — otherwise a "Page not fully detected" photo
  /// leaves no trace anywhere to diagnose after the fact, since it never
  /// reaches [processCapturedPages] at all.
  Future<String?> prepareDebugImagesDir() => _prepareDebugImagesDir();

  /// [runSubfolder] isolates one processing run's images from every other
  /// run's — see [processCapturedPages], which passes one. Omitted for the
  /// rejected-capture snapshot, which does its own `rejected/` nesting.
  Future<String?> _prepareDebugImagesDir({String? runSubfolder}) async {
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return null;
      final dir = Directory(
        runSubfolder == null
            ? '${base.path}/omr_debug'
            : '${base.path}/omr_debug/$runSubfolder',
      );
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

  /// Staging space for the Last Name/First Name/MI crops — written here
  /// first, then encrypted and copied into the batch's own storage by
  /// [BatchRepository.addScan]/[replaceScan] (see [LocalScan.nameCropLastFileName]
  /// and friends), same two-step flow [_prepareRectifiedImagesDir]'s folder
  /// already uses for the rectified overlay copy. Lives under the OS temp
  /// directory, so it's cleared the same way (no explicit cleanup here,
  /// matching that existing precedent) — the copies that matter live in
  /// the batch directory, not here.
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
