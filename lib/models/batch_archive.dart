import 'local_batch.dart';

/// The Guidance Council Web Archive marker for one batch (a
/// `batch_archives` row — see `supabase/migrations/0007_create_batch_archives.sql`).
///
/// Its existence means "this batch is archived in the Web application". It
/// is entirely separate from `batches.status` (the mobile app's workflow
/// status): creating or reading one never touches the batch, its scans, or
/// its status.
class BatchArchive {
  const BatchArchive({
    required this.batchId,
    required this.archivedAt,
    required this.archivedByUid,
    this.archivedByName,
    this.reason,
  });

  final String batchId;
  final DateTime archivedAt;
  final String archivedByUid;
  final String? archivedByName;
  final String? reason;
}

/// An archived batch for the Web Archive list: the batch itself (metadata
/// only, exactly as the Results page maps it), its archive marker, and the
/// number of scans it holds.
class ArchivedBatchEntry {
  const ArchivedBatchEntry({
    required this.batch,
    required this.archive,
    required this.scanCount,
  });

  final LocalBatch batch;
  final BatchArchive archive;
  final int scanCount;
}
