import 'dart:io';
import 'dart:typed_data';

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
  /// time). [rectifiedImage], when given, is also copied in and is purely
  /// display material for the graded overlay (see
  /// [resolveScanRectifiedImage]) — never part of [decoded]/scoring.
  /// [ocrLastNameGuess]/[ocrFirstNameGuess], when given, are on-device OCR's
  /// best-effort read of the sheet's handwritten name field — stored only
  /// to pre-fill the tag-student dialog later (see [LocalScan]), never
  /// treated as a confirmed [ExamineeInfo]. Returns the updated batch.
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
    String? ocrLastNameGuess,
    String? ocrFirstNameGuess,
    String? ocrMiddleNameGuess,
  });

  /// Replaces an existing scan's stored image/decode/result in place —
  /// same scan id and position in the batch; only the photo/decode/
  /// result/rectified image actually change. Used by "Rescan" in the batch
  /// archive, when a sheet's original capture needs to be redone (e.g. a
  /// bad photo). Throws if [scanId] doesn't exist in [batchId].
  ///
  /// [examinee], when given, replaces the stored tag; omitted (the
  /// default), the existing tag is kept as-is — this is what "same
  /// physical sheet, just a bad photo" means. Callers that recompute an
  /// OCR name guess against the new photo (see
  /// AppState.finishRescan) pass a refreshed [examinee] only when the
  /// existing tag wasn't already staff-confirmed, and pass
  /// [ocrLastNameGuess]/[ocrFirstNameGuess]/[ocrMiddleNameGuess] alongside
  /// it the same way [addScan] does.
  Future<LocalBatch> replaceScan({
    required String batchId,
    required String scanId,
    required OmrScanResult decoded,
    required File sourceImage,
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    String? ocrLastNameGuess,
    String? ocrFirstNameGuess,
    String? ocrMiddleNameGuess,
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
}
