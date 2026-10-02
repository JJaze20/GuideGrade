import 'dart:io';
import 'dart:typed_data';

import '../../models/answer_correction.dart';
import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';

/// Storage-agnostic contract for the `Batch -> Scans -> Results` model.
///
/// The whole scanning + archive workflow talks to this interface, never to
/// a concrete store. Today the only implementation is [LocalBatchRepository]
/// (device storage). A cloud-backed implementation (Firestore + Storage, or
/// a syncing wrapper around the local one) can be added later as a sibling
/// class without any change to the screens that depend on this.
/// Thrown by [BatchRepository.addScan] when [LocalBatch.isFull] is already
/// true for the target batch — the scan-count cap ([LocalBatch.expectedCount]
/// once [LocalBatch.hasScanLimit]) is enforced here, at the actual save
/// path, specifically so it can't be bypassed by skipping some other
/// screen's own check (see AppState.scanLimitBlockMessage, which exists
/// only as an earlier, friendlier warning — this exception is the real
/// gate). [message] is worded for direct display to the user.
class BatchScanLimitExceededException implements Exception {
  final int expectedCount;
  final String message;

  BatchScanLimitExceededException(this.expectedCount)
      : message = 'This batch has reached its scan limit of $expectedCount examinees. '
            'Please modify the batch in Batch Management if you need to increase the limit.';

  @override
  String toString() => message;
}

abstract class BatchRepository {
  /// All batches, newest activity first.
  Future<List<LocalBatch>> getBatches();

  Future<LocalBatch?> getBatchById(String id);

  /// Batches whose exam type matches [examCode]. Used by the scan flow to
  /// offer only batches compatible with the selected exam type.
  Future<List<LocalBatch>> getBatchesByExamCode(String examCode);

  Future<LocalBatch> createBatch({
    required String batchCode,
    required String examCode,
    required String examTitle,
    required String description,
    required int expectedCount,
    required String createdByUid,
    required String createdByName,
  });

  /// Persists edits to an existing batch (identifying/audit fields are not
  /// changed). Returns the stored copy.
  Future<LocalBatch> updateBatch(LocalBatch batch);

  /// Removes a batch and everything it contains (images included).
  Future<void> deleteBatch(String id);

  /// Copies [sourceImage] into [batchId]'s container and appends a scan
  /// carrying [decoded] (and [result]/[examinee] when known at capture
  /// time — [examinee] is normally null here; staff tag a scan afterward,
  /// see [setScanExaminee]). [rectifiedImage], when given, is also copied
  /// in and is purely display material for the graded overlay (see
  /// [resolveScanRectifiedImage]) — never part of [decoded]/scoring.
  /// [nameCropLastImage]/[nameCropFirstImage]/[nameCropMiddleImage], when
  /// given, are the sheet's cropped handwritten-name field photos — stored
  /// so staff can read them later while typing a name into
  /// showExamineeDialog (see [LocalScan]); this app never runs automatic
  /// handwriting recognition on them. Returns the updated batch.
  ///
  /// Throws [BatchScanLimitExceededException], with nothing written to
  /// disk, if the batch is already at its scan-count cap — see
  /// [LocalBatch.isFull]. This is the authoritative enforcement of that cap
  /// (any UI-level check is only a friendlier early warning on top of it).
  Future<LocalBatch> addScan({
    required String batchId,
    required OmrScanResult decoded,
    required File sourceImage,
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    File? nameCropLastImage,
    File? nameCropFirstImage,
    File? nameCropMiddleImage,
  });

  /// Replaces an existing scan's stored image/decode/result in place —
  /// same scan id and position in the batch; only the photo/decode/
  /// result/rectified/name-crop images actually change. Used by "Rescan" in
  /// the batch archive, when a sheet's original capture needs to be redone
  /// (e.g. a bad photo). Throws if [scanId] doesn't exist in [batchId].
  ///
  /// [examinee], when given, replaces the stored tag; omitted (the
  /// default, and what [AppState.finishRescan] always passes), the
  /// existing tag is kept as-is — a rescan means the same physical sheet,
  /// just a bad photo, so any already-entered name stays untouched.
  /// [nameCropLastImage]/[nameCropFirstImage]/[nameCropMiddleImage] follow
  /// [addScan]'s convention and always refresh to match the new photo.
  Future<LocalBatch> replaceScan({
    required String batchId,
    required String scanId,
    required OmrScanResult decoded,
    required File sourceImage,
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    File? nameCropLastImage,
    File? nameCropFirstImage,
    File? nameCropMiddleImage,
  });

  /// Attaches/overwrites the grading outcome for one already-stored scan.
  Future<LocalBatch> attachResult({
    required String batchId,
    required String scanId,
    required LocalScanResult result,
  });

  /// Sets (or clears, when [examinee] is null) which student one stored
  /// scan belongs to. Returns the updated batch.
  Future<LocalBatch> setScanExaminee({
    required String batchId,
    required String scanId,
    ExamineeInfo? examinee,
  });

  /// Records manual answer corrections for one stored scan and, in the same
  /// write, the [result] recalculated from them — so the stored history and
  /// the stored score can never disagree. [corrections] is the scan's FULL
  /// history as the caller sees it (from `CorrectionRules`); the store keeps
  /// its append-only rule: entries already stored are never dropped or
  /// rewritten, and a request that adds nothing new is a no-op (no revision
  /// bump, nothing to sync), so a repeated tap or a retried call cannot apply
  /// a correction twice. Never touches the machine-detected `decoded` answers,
  /// the scan image, the answer key or the student's details. Throws if any
  /// NEW entry was made against a different capture than the scan currently
  /// holds (the sheet was rescanned meanwhile). Returns the updated batch.
  Future<LocalBatch> updateScanCorrections({
    required String batchId,
    required String scanId,
    required List<AnswerCorrection> corrections,
    LocalScanResult? result,
  });

  /// Marks [batchId] Archived — but only if its CURRENT saved revision
  /// (`updatedAt`) still equals [confirmedUpdatedAt], the revision the cloud
  /// acknowledged. Returns true when it archived, false when it did not
  /// (already archived, the batch changed since, or its required fields
  /// have problems). Does not change `updatedAt` and never queues a push.
  /// See `BatchLifecycle` for the full status rules.
  Future<bool> confirmBatchArchived(String batchId, DateTime confirmedUpdatedAt);

  /// Decrypted bytes of a stored scan image (see [LocalBatchRepository]'s
  /// doc comment — every image is encrypted at rest), or null if the file
  /// is missing on disk. Every scan has an original image in principle, so
  /// null here means something is actually wrong (deleted out from under
  /// the app), not a normal "none yet" case.
  Future<Uint8List?> resolveScanImage(String batchId, LocalScan scan);

  /// Decrypted bytes of [scan]'s perspective-corrected image, or null when
  /// none was stored for it (see [LocalScan.rectifiedImageFileName]) or the
  /// file is missing on disk.
  Future<Uint8List?> resolveScanRectifiedImage(String batchId, LocalScan scan);

  /// Decrypted bytes of [scan]'s cropped Last Name / First Name / MI
  /// handwriting images, or null when none was stored for it (see
  /// [LocalScan.nameCropLastFileName]/[nameCropFirstFileName]/
  /// [nameCropMiddleFileName]) or the file is missing on disk — both
  /// ordinary, non-error cases (an older scan predating this feature, or a
  /// sheet whose crop failed) that callers should render as "no crop
  /// available", not surface as an error.
  Future<Uint8List?> resolveScanNameCropLast(String batchId, LocalScan scan);
  Future<Uint8List?> resolveScanNameCropFirst(String batchId, LocalScan scan);
  Future<Uint8List?> resolveScanNameCropMiddle(String batchId, LocalScan scan);

  /// Cloud-restore only — never called by the scan/create/edit flows.
  ///
  /// Creates the local batch at [batch.id] if none exists yet. Otherwise
  /// merges only its mutable metadata (batchCode / examTitle / description /
  /// expectedCount / status) into the existing local batch, and only when
  /// [batch.updatedAt] is strictly newer than what's already stored —
  /// audit fields (createdByUid / createdByName / createdAt) and
  /// [LocalBatch.scans] are never touched by this call. See
  /// [upsertScanFromCloud] for scans. Returns the resulting stored batch.
  Future<LocalBatch> upsertBatchFromCloud(LocalBatch batch);

  /// Cloud-restore only — never called by the scan/create/edit flows.
  ///
  /// Appends [scan] to [batchId] if no local scan with [scan.id] already
  /// exists. Otherwise a no-op that leaves the existing local scan
  /// completely untouched — v1 cloud restoration never merges or
  /// overwrites a scan that's already stored locally, regardless of which
  /// is newer. Throws [StateError] if [batchId] itself doesn't exist
  /// locally yet (call [upsertBatchFromCloud] first). Returns the
  /// resulting stored batch.
  Future<LocalBatch> upsertScanFromCloud({
    required String batchId,
    required LocalScan scan,
  });

  /// Cloud-restore only — never called by the scan/capture flow.
  ///
  /// Encrypts [bytes] via the same crypto service every other image write
  /// already uses, then writes them to the exact deterministic local path
  /// [resolveScanImage] already looks for (`images/<scanId>.enc`) — so a
  /// restored image is indistinguishable from a captured one at read time.
  /// [resolveScanImage]/[resolveScanRectifiedImage] are never modified by
  /// this feature; callers that get `null` from them should call this (or
  /// [writeRestoredScanRectifiedImage]) via `CloudRestoreService.
  /// restoreImageIfMissing`, then resolve again.
  Future<void> writeRestoredScanImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  });

  /// Cloud-restore only. Same as [writeRestoredScanImage], for the
  /// perspective-corrected overlay copy (`images/<scanId>_rectified.enc`).
  Future<void> writeRestoredScanRectifiedImage({
    required String batchId,
    required String scanId,
    required Uint8List bytes,
  });
}
