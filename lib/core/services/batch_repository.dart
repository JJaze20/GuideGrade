import 'dart:io';

import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';

/// Storage-agnostic contract for the `Batch -> Scans -> Results` model.
///
/// The whole scanning + archive workflow talks to this interface, never to
/// a concrete store. Today the only implementation is [LocalBatchRepository]
/// (device storage). A cloud-backed implementation (Firestore + Storage, or
/// a syncing wrapper around the local one) can be added later as a sibling
/// class without any change to the screens that depend on this.
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
  /// time). Returns the updated batch.
  Future<LocalBatch> addScan({
    required String batchId,
    required OmrScanResult decoded,
    required File sourceImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
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

  /// Absolute file for a stored scan image, for display.
  Future<File> resolveScanImage(String batchId, LocalScan scan);
}
