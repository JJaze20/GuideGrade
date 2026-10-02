import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../services/local_batch_repository.dart';
import 'sync_client.dart';
import 'sync_job.dart';
import 'sync_outcome.dart';
import 'sync_queue.dart';

/// Drives the offline sync queue: restores it on startup, reconciles local
/// truth against what has been pushed, and drains eligible jobs one at a
/// time through a [SyncClient], applying retry/backoff, permanent-failure
/// and conflict rules.
///
/// It is a plain injectable object (constructor injection, no global
/// singleton). The app builds exactly one and controls its lifecycle;
/// [SyncManager] never inspects Firebase — the integration layer decides
/// when [start] / [pause] are called.
class SyncManager extends ChangeNotifier {
  SyncManager({
    required this.queue,
    required this.client,
    required this.batchRepository,
    required this.loadAnswerKeys,
    DateTime Function()? clock,
    double Function()? jitter,
  })  : _clock = clock ?? _defaultClock,
        _jitter = jitter ?? _defaultJitter;

  final SyncQueue queue;
  final SyncClient client;
  final LocalBatchRepository batchRepository;

  /// Reads the current local answer keys (backed by `LocalStorageService`
  /// in the app). Injected as a capability so tests need no SharedPreferences.
  final Future<Map<String, AnswerKey>> Function() loadAnswerKeys;

  final DateTime Function() _clock;
  final double Function() _jitter;

  static DateTime _defaultClock() => DateTime.now().toUtc();
  static final math.Random _rng = math.Random();
  static double _defaultJitter() => 0.5 + _rng.nextDouble() * 0.5;

  /// Exponential backoff bounds (approved Phase 9A design).
  static const int _baseBackoffMs = 5 * 1000;
  static const int _capBackoffMs = 15 * 60 * 1000;

  // --- lifecycle state -------------------------------------------------------

  bool _active = false;
  bool _processing = false;
  bool _disposed = false;
  DateTime? _lastRunAt;

  // Set by [wake] when a wake arrives while a drain is already running, so
  // the running drain makes one more pass before it exits. Closes the
  // "a job was enqueued just as the loop was ending" gap without ever
  // making the drain infinite.
  bool _wakePending = false;

  // Debug-only guard against a second concurrently-active manager. Off in
  // release; harmless for unit tests (each disposes in tearDown).
  static int _activeManagerCount = 0;
  bool _countsAsActive = false;

  // --- read-only status (for a UI badge) -----------------------------------

  int get pendingCount => queue.byStatus(SyncJobStatus.pending).length;

  int get inProgressCount => queue.byStatus(SyncJobStatus.inProgress).length;

  int get failedPermanentCount =>
      queue.byStatus(SyncJobStatus.failedPermanent).length;

  int get blockedConflictCount =>
      queue.byStatus(SyncJobStatus.blockedConflict).length;

  /// When the drain loop last ran (whether or not it did any work).
  DateTime? get lastRunAt => _lastRunAt;

  /// True while the drain loop is executing.
  bool get isRunning => _processing;

  /// True between [start] and [pause] (or [dispose]).
  bool get isActive => _active;

  // --- public API ----------------------------------------------------------

  /// Loads the persisted queue (which itself resets any surviving
  /// `inProgress` job to `pending` and clamps a far-future backoff), then
  /// runs the startup reconcile pass. Does not start draining.
  Future<void> restore() async {
    if (_disposed) return;
    await queue.restore();
    await _reconcile();
    _notify();
  }

  /// Marks the manager active and kicks a drain. The integration layer
  /// calls this only when a `guidance_council` user is signed in.
  Future<void> start() async {
    if (_disposed) return;
    _active = true;
    _markActive();
    _notify();
    await processQueue();
  }

  /// Stops new jobs from starting. A job already in flight is allowed to
  /// finish (the drain loop re-checks [_active] between jobs). The queue
  /// stays on disk; no pending job is removed.
  void pause() {
    if (_disposed) return;
    _active = false;
    _markInactive();
    _notify();
  }

  /// Drains eligible jobs one at a time, oldest first, serialized per
  /// entity. No-op if already draining, if paused, or if nothing is
  /// eligible.
  ///
  /// If [wake] flags more work while this is running (e.g. a scan enqueues
  /// jobs just as the inner loop is about to exit), the drain makes one
  /// more pass. It is not infinite: it stops as soon as no wake is pending
  /// and nothing is eligible.
  Future<void> processQueue() async {
    if (_disposed || !_active || _processing) {
      _diag('processQueue skipped ('
          '${_disposed ? 'disposed' : (!_active ? 'inactive' : 'already-running')}'
          ')');
      return;
    }
    _processing = true;
    _notify();
    try {
      _diag('drain start: '
          'eligible=${queue.eligible(_clock()).length} '
          'pending=${queue.byStatus(SyncJobStatus.pending).length} '
          'inProgress=${queue.byStatus(SyncJobStatus.inProgress).length} '
          'failedPermanent=${queue.byStatus(SyncJobStatus.failedPermanent).length} '
          'blockedConflict=${queue.byStatus(SyncJobStatus.blockedConflict).length}');
      do {
        _wakePending = false;
        while (_active && !_disposed) {
          final now = _clock();
          final job = _pickNextRunnableJob(now);
          if (job == null) break;
          try {
            await _runJob(job);
          } catch (_) {
            // A queue-persistence failure (or other unexpected error): end
            // this pass instead of spinning. restore() recovers any job
            // left marked inProgress.
            break;
          }
        }
        // Between the `while` exit and the `_wakePending` check there is no
        // await, so a wake() cannot slip past unseen: any wake() that ran
        // during this pass is caught here and triggers exactly one more.
      } while (_wakePending && _active && !_disposed);
    } finally {
      _processing = false;
      _lastRunAt = _clock();
      _notify();
    }
  }

  /// Manual "Sync Now": pulls every *pending* job's backoff forward to now
  /// and drains. Does not revive `failedPermanent` or `blockedConflict`
  /// jobs, and does not itself change the active/paused state (the
  /// integration layer starts the manager before exposing this).
  Future<void> syncNow() async {
    if (_disposed) return;
    final now = _clock();
    for (final job in queue.jobs) {
      if (job.status == SyncJobStatus.pending && job.nextAttemptAt.isAfter(now)) {
        await queue.update(job.copyWith(nextAttemptAt: now));
      }
    }
    await processQueue();
  }

  /// Nudges the drain after work is enqueued once the manager is already
  /// running (a scan's jobs land after [start]'s single post-login pass has
  /// finished). Behaviour:
  ///  * no-op when disposed or paused/inactive;
  ///  * if a drain is already in flight, flags it to make one more pass so
  ///    the just-enqueued jobs are not stranded — it never starts a second
  ///    concurrent drain;
  ///  * otherwise runs the existing [processQueue].
  ///
  /// It performs no sync logic of its own — it only (re)starts the
  /// [processQueue] mechanism — and never throws to the (fire-and-forget)
  /// caller. `SyncingBatchRepository` calls this after every successful
  /// enqueue.
  Future<void> wake() async {
    if (_disposed || !_active) return;
    if (_processing) {
      _wakePending = true;
      return;
    }
    try {
      await processQueue();
    } catch (_) {
      // processQueue is already internally guarded; never surface an error.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _active = false;
    _markInactive();
    super.dispose();
  }

  // --- reconcile ---------------------------------------------------------

  Future<void> _reconcile() async {
    final state = queue.state;
    final List<LocalBatch> localBatches = await batchRepository.getBatches();
    final localBatchIds = <String>{};

    for (final batch in localBatches) {
      localBatchIds.add(batch.id);
      final lastPushed = state.batchLastPushedUpdatedAt(batch.id);
      final batchNeedsPush = lastPushed == null ||
          batch.updatedAt.toUtc().isAfter(lastPushed);

      if (batchNeedsPush) {
        await _enqueueIfAbsent(
          type: SyncJobType.pushBatch,
          entityId: batch.id,
          batchId: batch.id,
        );
      }

      for (final scan in batch.scans) {
        final hasRectified = scan.rectifiedImageFileName != null;
        final originalUploaded = state.scanOriginalUploaded(batch.id, scan.id);
        final rectifiedUploaded =
            state.scanRectifiedUploaded(batch.id, scan.id);
        final imageWorkPending =
            !originalUploaded || (hasRectified && !rectifiedUploaded);

        if (batchNeedsPush) {
          await _enqueueIfAbsent(
            type: SyncJobType.pushScan,
            entityId: scan.id,
            batchId: batch.id,
            scanId: scan.id,
          );
        }
        if (!originalUploaded) {
          await _enqueueIfAbsent(
            type: SyncJobType.uploadImage,
            entityId: scan.id,
            batchId: batch.id,
            scanId: scan.id,
            variant: 'original',
          );
        }
        if (hasRectified && !rectifiedUploaded) {
          await _enqueueIfAbsent(
            type: SyncJobType.uploadImage,
            entityId: scan.id,
            batchId: batch.id,
            scanId: scan.id,
            variant: 'rectified',
          );
        }
        if (imageWorkPending) {
          await _enqueueIfAbsent(
            type: SyncJobType.patchImageStatus,
            entityId: scan.id,
            batchId: batch.id,
            scanId: scan.id,
          );
        }
      }
    }

    final answerKeys = await loadAnswerKeys();
    for (final examCode in answerKeys.keys) {
      final tracked = state.answerKeyLastPushedVersion(examCode) != null ||
          state.answerKeyLastPushedUpdatedAt(examCode) != null;
      if (!tracked) {
        await _enqueueIfAbsent(
          type: SyncJobType.pushAnswerKey,
          entityId: examCode,
        );
      }
    }

    for (final orphanId in _orphanBatchIds(state, localBatchIds)) {
      final hasDelete = queue.jobs.any((j) =>
          j.type == SyncJobType.deleteBatch && j.batchId == orphanId);
      if (hasDelete) continue;
      // DELETE_BATCH is enqueued first so it always carries the older id and
      // therefore runs before DELETE_STORAGE_PREFIX for the same batch.
      await queue.enqueue(SyncJob.create(
        type: SyncJobType.deleteBatch,
        entityId: orphanId,
        batchId: orphanId,
        now: _clock(),
      ));
      await queue.enqueue(SyncJob.create(
        type: SyncJobType.deleteStoragePrefix,
        entityId: orphanId,
        batchId: orphanId,
        now: _clock(),
      ));
    }
  }

  /// Enqueues a job only when no job with the same dedupe key already
  /// exists in any status — so reconcile never disturbs a job that is
  /// backing off, `failedPermanent`, or `blockedConflict`.
  Future<void> _enqueueIfAbsent({
    required SyncJobType type,
    required String entityId,
    String? batchId,
    String? scanId,
    String? variant,
  }) async {
    final key = SyncJob.dedupeKeyFor(
      type: type,
      batchId: batchId,
      scanId: scanId,
      entityId: entityId,
      variant: variant,
    );
    if (queue.jobsWithDedupeKey(key).isNotEmpty) return;
    await queue.enqueue(SyncJob.create(
      type: type,
      entityId: entityId,
      batchId: batchId,
      scanId: scanId,
      meta: variant == null ? const {} : {'variant': variant},
      now: _clock(),
    ));
  }

  Iterable<String> _orphanBatchIds(SyncState state, Set<String> localBatchIds) {
    final ids = <String>{};
    for (final key in state.toJson().keys) {
      if (key.startsWith('batch:')) {
        ids.add(key.substring('batch:'.length));
      } else if (key.startsWith('scan:')) {
        final parts = key.split(':');
        if (parts.length >= 2 && parts[1].isNotEmpty) ids.add(parts[1]);
      }
    }
    ids.removeWhere(localBatchIds.contains);
    return ids;
  }

  // --- drain ------------------------------------------------------------

  /// The next job to run: the globally-oldest eligible (pending + due) job
  /// that is also the oldest still-active job in its entity group, so a
  /// newer job never jumps ahead of an older sibling that is still pending
  /// or backing off.
  SyncJob? _pickNextRunnableJob(DateTime now) {
    final due = queue.eligible(now); // pending && due, oldest id first
    if (due.isEmpty) return null;
    final all = queue.jobs; // every job, oldest id first
    for (final candidate in due) {
      final group = _groupKey(candidate);
      SyncJob? head;
      for (final job in all) {
        if (_groupKey(job) != group) continue;
        if (job.status == SyncJobStatus.pending ||
            job.status == SyncJobStatus.inProgress) {
          head = job;
          break;
        }
      }
      if (head == null) continue;
      if (head.id != candidate.id) continue; // an older sibling goes first
      if (head.status == SyncJobStatus.inProgress) continue; // defensive
      return candidate;
    }
    return null;
  }

  /// A batch and all of its scan/image/delete jobs share one lock;
  /// answer-key jobs lock per exam code.
  String _groupKey(SyncJob job) => job.type == SyncJobType.pushAnswerKey
      ? 'answerKey:${job.entityId}'
      : 'batch:${job.batchId}';

  Future<void> _runJob(SyncJob job) async {
    _diag('dispatch ${job.typeWireName} ${job.entityId} attempt=${job.attempts}');
    if (_missingRequiredField(job) != null) {
      await _applyOutcome(job, const SyncOutcome.permanent('bad_job'));
      return;
    }

    final running = job.copyWith(status: SyncJobStatus.inProgress);
    await queue.update(running); // persist inProgress before execution
    _notify();

    SyncOutcome outcome;
    try {
      outcome = await _dispatch(running);
    } catch (_) {
      // SupabaseSyncClient already converts every failure to a SyncOutcome;
      // this only stops an unforeseen throw from stranding the job.
      outcome = const SyncOutcome.permanent('unknown');
    }

    await _applyOutcome(running, outcome); // persist the result
    _notify();
  }

  Future<SyncOutcome> _dispatch(SyncJob job) {
    switch (job.type) {
      case SyncJobType.pushBatch:
        return client.pushBatch(job.batchId!);
      case SyncJobType.pushScan:
        return client.pushScan(job.batchId!, job.scanId!, meta: job.meta);
      case SyncJobType.uploadImage:
        return client.uploadImage(job);
      case SyncJobType.patchImageStatus:
        return client.patchImageStatus(job.batchId!, job.scanId!);
      case SyncJobType.pushAnswerKey:
        return client.pushAnswerKey(job.entityId, meta: job.meta);
      case SyncJobType.deleteBatch:
        return client.deleteBatch(job.batchId!);
      case SyncJobType.deleteStoragePrefix:
        return client.deleteStoragePrefix(job.batchId!);
    }
  }

  String? _missingRequiredField(SyncJob job) {
    switch (job.type) {
      case SyncJobType.pushBatch:
      case SyncJobType.deleteBatch:
      case SyncJobType.deleteStoragePrefix:
        return job.batchId == null ? 'batchId' : null;
      case SyncJobType.pushScan:
      case SyncJobType.uploadImage:
      case SyncJobType.patchImageStatus:
        if (job.batchId == null) return 'batchId';
        if (job.scanId == null) return 'scanId';
        return null;
      case SyncJobType.pushAnswerKey:
        return job.entityId.isEmpty ? 'entityId' : null;
    }
  }

  Future<void> _applyOutcome(SyncJob job, SyncOutcome outcome) async {
    _diag('${job.typeWireName} ${job.entityId} -> ${outcome.kind.name}'
        '${outcome.code == null ? '' : '(${outcome.code})'} '
        'attempts=${job.attempts}');
    if (outcome.isSuccess) {
      await queue.remove(job.id);
      // The client mutates queue.state in place on success — make it durable.
      await queue.saveState();
      return;
    }
    if (outcome.isTransient) {
      final attempts = job.attempts + 1;
      await queue.update(job.copyWith(
        status: SyncJobStatus.pending,
        attempts: attempts,
        nextAttemptAt: _clock().add(_backoff(attempts)),
        lastErrorCode: outcome.code,
      ));
      return;
    }
    if (outcome.isConflict) {
      await queue.update(job.copyWith(
        status: SyncJobStatus.blockedConflict,
        lastErrorCode: outcome.code,
      ));
      return;
    }
    // permanent (or any unforeseen kind): do not retry automatically.
    await queue.update(job.copyWith(
      status: SyncJobStatus.failedPermanent,
      lastErrorCode: outcome.code,
    ));
  }

  /// `min(CAP, BASE * 2^(n-1)) * jitter`, jitter in [0.5, 1.0].
  Duration _backoff(int attempts) {
    final n = attempts < 1 ? 1 : attempts;
    final exponential = _baseBackoffMs * math.pow(2, n - 1);
    final capped = math.min(exponential.toDouble(), _capBackoffMs.toDouble());
    return Duration(milliseconds: (capped * _clampedJitter()).round());
  }

  double _clampedJitter() {
    final value = _jitter();
    if (value.isNaN || value < 0.5) return 0.5;
    if (value > 1.0) return 1.0;
    return value;
  }

  // --- helpers ---------------------------------------------------------

  void _markActive() {
    if (_countsAsActive) return;
    _countsAsActive = true;
    _activeManagerCount++;
    assert(
      _activeManagerCount <= 1,
      'More than one SyncManager is active; the app must build exactly one.',
    );
  }

  void _markInactive() {
    if (!_countsAsActive) return;
    _countsAsActive = false;
    _activeManagerCount--;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// One-line sync-flow trace. Reaches `adb logcat` in a release build (same
  /// as the existing `SyncQueue` / `SupabaseSyncClient` logs). Deliberately
  /// carries only job wire names, entity ids, attempt counts and the
  /// already-sanitized [SyncOutcome.code] — never a token, key, request
  /// body, URL, or PII.
  void _diag(String message) {
    debugPrint('SyncManager: $message');
  }
}
