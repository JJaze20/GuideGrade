/// One unit of pending cloud work in the offline sync queue.
///
/// A [SyncJob] carries **only identifiers and operation metadata** — never a
/// row snapshot, image bytes, examinee data, a Firebase token, the Supabase
/// publishable key, or any credential. When the sync manager runs a job it
/// re-reads the current local state (from `LocalBatchRepository` /
/// `LocalStorageService`) and builds the request payload then, which is what
/// makes an old queued job safe: it always pushes whatever local says *now*,
/// so it can never overwrite a newer local edit.
///
/// Persisted as an entry in `<appDocuments>/guidegrade_sync/queue.json`
/// (see [SyncQueue]). All timestamps are stored as UTC ISO-8601.
library;

/// The kind of cloud operation a [SyncJob] represents.
///
/// The SCREAMING_SNAKE_CASE wire names below are part of the on-disk
/// contract for `queue.json`; do not rename them without a migration.
enum SyncJobType {
  pushBatch,
  pushScan,
  uploadImage,
  patchImageStatus,
  pushAnswerKey,
  deleteBatch,
  deleteScan,
  deleteStoragePrefix,
}

/// Lifecycle state of a queued job.
enum SyncJobStatus {
  /// Waiting to run, or waiting for its backoff window to elapse
  /// (see [SyncJob.nextAttemptAt]).
  pending,

  /// Handed to the processor. Never trusted across a restart:
  /// [SyncQueue.restore] rewrites any surviving `inProgress` job back to
  /// [pending] because the operation may not have reached the server, and
  /// every job type is idempotent so a re-run is safe.
  inProgress,

  /// A non-retryable failure (payload validation, RLS denial, bad type).
  /// The job stays put and is not retried automatically; a fresh local
  /// mutation that coalesces onto it (see [SyncQueue.enqueue]) revives it,
  /// or the user can trigger an explicit retry.
  failedPermanent,

  /// Blocked on a conflict a human must resolve (e.g. an answer key that
  /// was changed on another device). Not retried automatically.
  blockedConflict,
}

const Map<SyncJobType, String> _typeWire = {
  SyncJobType.pushBatch: 'PUSH_BATCH',
  SyncJobType.pushScan: 'PUSH_SCAN',
  SyncJobType.uploadImage: 'UPLOAD_IMAGE',
  SyncJobType.patchImageStatus: 'PATCH_IMAGE_STATUS',
  SyncJobType.pushAnswerKey: 'PUSH_ANSWER_KEY',
  SyncJobType.deleteBatch: 'DELETE_BATCH',
  SyncJobType.deleteScan: 'DELETE_SCAN',
  SyncJobType.deleteStoragePrefix: 'DELETE_STORAGE_PREFIX',
};

final Map<String, SyncJobType> _typeFromWire = {
  for (final entry in _typeWire.entries) entry.value: entry.key,
};

const Map<SyncJobStatus, String> _statusWire = {
  SyncJobStatus.pending: 'pending',
  SyncJobStatus.inProgress: 'inProgress',
  SyncJobStatus.failedPermanent: 'failedPermanent',
  SyncJobStatus.blockedConflict: 'blockedConflict',
};

final Map<String, SyncJobStatus> _statusFromWire = {
  for (final entry in _statusWire.entries) entry.value: entry.key,
};

final DateTime _epochUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime _parseUtcOr(Object? raw, DateTime fallback) {
  if (raw is String) {
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed.toUtc();
  }
  return fallback;
}

/// A durable, idempotent, coalescable unit of cloud sync work.
class SyncJob {
  SyncJob._({
    required this.id,
    required this.type,
    required this.entityId,
    required this.batchId,
    required this.scanId,
    required this.meta,
    required this.dedupeKey,
    required this.createdAt,
    required this.attempts,
    required this.nextAttemptAt,
    required this.status,
    required this.lastErrorCode,
  });

  /// Lexically sortable, unique within the queue. Format:
  /// `<14-digit epoch millis>_<9-digit per-process counter>` so that a
  /// plain string sort reproduces creation order even for jobs created in
  /// the same millisecond.
  final String id;

  final SyncJobType type;

  /// The primary identifier of the job's target: the batch id for
  /// batch/scan/image/delete jobs, or the exam code for [pushAnswerKey].
  final String entityId;

  /// Set for every batch/scan/image/delete job; null for [pushAnswerKey].
  final String? batchId;

  /// Set for [pushScan], [uploadImage] and [patchImageStatus]; null
  /// otherwise.
  final String? scanId;

  /// Tiny operation metadata only. [uploadImage] uses `{"variant":
  /// "original"}` or `{"variant": "rectified"}`. Never row data.
  final Map<String, String> meta;

  /// Collapse key for coalescing (see [SyncQueue.enqueue]). Derived from
  /// [type] + ids + `meta['variant']`; stored so it survives a reload even
  /// if the derivation ever changes.
  final String dedupeKey;

  /// When the job was first enqueued (UTC). Used only for ordering/audit.
  final DateTime createdAt;

  /// Number of failed runs so far.
  final int attempts;

  /// Earliest time the job may run again (UTC). Equal to [createdAt] for a
  /// fresh job; pushed forward by the retry/backoff logic.
  final DateTime nextAttemptAt;

  final SyncJobStatus status;

  /// Sanitized error code from the last failed run (e.g. `"42501"`,
  /// `"PGRST301"`, `"22P02"`, `"network"`). Never a message, token or
  /// payload.
  final String? lastErrorCode;

  static int _counter = 0;

  /// Monotonic, lexically-sortable id (see [id]).
  static String newId([DateTime? now]) {
    final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final n = _counter++;
    return '${ms.toString().padLeft(14, '0')}_${n.toString().padLeft(9, '0')}';
  }

  /// After a restart the per-process counter restarts at 0. Bump it past
  /// the highest counter already on disk so a job created in the same
  /// millisecond as a pre-restart job cannot get a colliding / out-of-order
  /// id. Safe to call repeatedly.
  static void primeSequence(Iterable<SyncJob> existing) {
    var maxN = -1;
    for (final job in existing) {
      final underscore = job.id.indexOf('_');
      if (underscore < 0) continue;
      final n = int.tryParse(job.id.substring(underscore + 1));
      if (n != null && n > maxN) maxN = n;
    }
    if (maxN >= _counter) _counter = maxN + 1;
  }

  /// The canonical coalescing key for a would-be job. Exposed so the
  /// repository decorator and tests can reason about coalescing without
  /// constructing a job.
  static String dedupeKeyFor({
    required SyncJobType type,
    String? batchId,
    String? scanId,
    String? entityId,
    String? variant,
  }) {
    switch (type) {
      case SyncJobType.pushBatch:
        return 'PUSH_BATCH:$batchId';
      case SyncJobType.pushScan:
        return 'PUSH_SCAN:$batchId:$scanId';
      case SyncJobType.uploadImage:
        return 'UPLOAD_IMAGE:$batchId:$scanId:$variant';
      case SyncJobType.patchImageStatus:
        return 'PATCH_IMAGE_STATUS:$batchId:$scanId';
      case SyncJobType.pushAnswerKey:
        return 'PUSH_ANSWER_KEY:$entityId';
      case SyncJobType.deleteBatch:
        return 'DELETE_BATCH:$batchId';
      case SyncJobType.deleteScan:
        return 'DELETE_SCAN:$batchId:$scanId';
      case SyncJobType.deleteStoragePrefix:
        return 'DELETE_STORAGE_PREFIX:$batchId';
    }
  }

  /// Builds a fresh `pending` job. [now] and [id] are injectable for
  /// deterministic tests.
  factory SyncJob.create({
    required SyncJobType type,
    required String entityId,
    String? batchId,
    String? scanId,
    Map<String, String> meta = const {},
    DateTime? now,
    String? id,
  }) {
    final createdUtc = (now ?? DateTime.now()).toUtc();
    return SyncJob._(
      id: id ?? newId(createdUtc),
      type: type,
      entityId: entityId,
      batchId: batchId,
      scanId: scanId,
      meta: Map<String, String>.unmodifiable(meta),
      dedupeKey: dedupeKeyFor(
        type: type,
        batchId: batchId,
        scanId: scanId,
        entityId: entityId,
        variant: meta['variant'],
      ),
      createdAt: createdUtc,
      attempts: 0,
      nextAttemptAt: createdUtc,
      status: SyncJobStatus.pending,
      lastErrorCode: null,
    );
  }

  /// Tolerant deserializer. Throws [FormatException] only when [type] is
  /// missing/unknown (the queue skips that one entry); every other bad
  /// field falls back to a safe default so a single dirty row cannot break
  /// the whole queue.
  factory SyncJob.fromJson(Map<String, dynamic> json) {
    final typeWire = json['type'] as String?;
    final type = _typeFromWire[typeWire];
    if (type == null) {
      throw FormatException('Unknown SyncJob type: $typeWire');
    }

    final meta = <String, String>{};
    final rawMeta = json['meta'];
    if (rawMeta is Map) {
      rawMeta.forEach((k, v) => meta[k.toString()] = v.toString());
    }

    final createdAt = _parseUtcOr(json['createdAt'], _epochUtc);
    final nextAttemptAt = _parseUtcOr(json['nextAttemptAt'], createdAt);
    final entityId = (json['entityId'] ?? '').toString();
    final batchId = json['batchId'] as String?;
    final scanId = json['scanId'] as String?;
    final storedKey = json['dedupeKey'] as String?;

    return SyncJob._(
      id: (json['id'] ?? newId(createdAt)).toString(),
      type: type,
      entityId: entityId,
      batchId: batchId,
      scanId: scanId,
      meta: Map<String, String>.unmodifiable(meta),
      dedupeKey: (storedKey != null && storedKey.isNotEmpty)
          ? storedKey
          : dedupeKeyFor(
              type: type,
              batchId: batchId,
              scanId: scanId,
              entityId: entityId,
              variant: meta['variant'],
            ),
      createdAt: createdAt,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: nextAttemptAt,
      status: _statusFromWire[json['status'] as String?] ?? SyncJobStatus.pending,
      lastErrorCode: json['lastErrorCode'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': _typeWire[type],
        'entityId': entityId,
        'batchId': batchId,
        'scanId': scanId,
        'meta': meta,
        'dedupeKey': dedupeKey,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'attempts': attempts,
        'nextAttemptAt': nextAttemptAt.toUtc().toIso8601String(),
        'status': _statusWire[status],
        'lastErrorCode': lastErrorCode,
      };

  /// Returns a copy with the fields that change over a job's life. [id],
  /// [type] and the identity fields are immutable. Pass
  /// [clearLastErrorCode] to drop the error code (used when a job is
  /// refreshed by a new local mutation).
  SyncJob copyWith({
    int? attempts,
    DateTime? nextAttemptAt,
    SyncJobStatus? status,
    String? lastErrorCode,
    bool clearLastErrorCode = false,
  }) {
    return SyncJob._(
      id: id,
      type: type,
      entityId: entityId,
      batchId: batchId,
      scanId: scanId,
      meta: meta,
      dedupeKey: dedupeKey,
      createdAt: createdAt,
      attempts: attempts ?? this.attempts,
      nextAttemptAt: (nextAttemptAt ?? this.nextAttemptAt).toUtc(),
      status: status ?? this.status,
      lastErrorCode:
          clearLastErrorCode ? null : (lastErrorCode ?? this.lastErrorCode),
    );
  }

  /// The wire name for [type] (e.g. `PUSH_BATCH`).
  String get typeWireName => _typeWire[type]!;

  /// The wire name for [status] (e.g. `pending`).
  String get statusWireName => _statusWire[status]!;

  /// True for the four job types that write the cloud batch/scan rows or
  /// their Storage objects. These are the jobs a `DELETE_BATCH` for the
  /// same batch supersedes / cancels.
  bool get isBatchContentPush =>
      type == SyncJobType.pushBatch ||
      type == SyncJobType.pushScan ||
      type == SyncJobType.uploadImage ||
      type == SyncJobType.patchImageStatus;

  bool get isPending => status == SyncJobStatus.pending;

  bool get isInProgress => status == SyncJobStatus.inProgress;

  /// Whether the backoff window has elapsed at [now].
  bool isDue(DateTime now) => !nextAttemptAt.isAfter(now);

  /// Whether the job can be picked up for processing at [now]
  /// (pending *and* due). Per-entity serialization is layered on top of
  /// this by the sync manager, not here.
  bool isEligible(DateTime now) => isPending && isDue(now);

  @override
  String toString() => 'SyncJob(${_typeWire[type]} $dedupeKey '
      'status=${_statusWire[status]} attempts=$attempts '
      'next=${nextAttemptAt.toUtc().toIso8601String()})';
}
