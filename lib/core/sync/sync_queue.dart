import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'sync_job.dart';

/// Durable, restart-surviving queue of pending cloud [SyncJob]s plus the
/// companion "what have we already pushed?" ledger ([SyncState]).
///
/// Storage (mirrors `LocalBatchRepository`'s "one JSON manifest, written
/// whole" idiom):
///
/// ```
/// <appDocuments>/guidegrade_sync/
///   queue.json        - the SyncJob list
///   sync_state.json   - the SyncState map
/// ```
///
/// Every mutating method rewrites the affected file with a temp-file +
/// flush + atomic-rename, and [restore] can recover from a leftover
/// `*.tmp` if a write was interrupted. There are **no** network, Supabase
/// or Firebase calls anywhere in this class.
class SyncQueue {
  SyncQueue({this.rootOverride, DateTime Function()? clock})
      : _clock = clock ?? _nowUtc;

  /// Test seam: when set, the queue lives under here instead of the
  /// platform documents directory (so unit tests never touch
  /// `path_provider`). Mirrors `LocalBatchRepository.rootOverride`.
  final Directory? rootOverride;

  /// Injectable clock; always expected to return a UTC instant.
  final DateTime Function() _clock;

  static DateTime _nowUtc() => DateTime.now().toUtc();

  static const _folderName = 'guidegrade_sync';
  static const _queueFileName = 'queue.json';
  static const _stateFileName = 'sync_state.json';
  static const _tmpSuffix = '.tmp';

  /// A [SyncJob.nextAttemptAt] further out than this is treated as clock
  /// corruption and pulled back to "now" on [restore]. The real backoff
  /// cap in the approved design is 15 minutes, so an hour is safely clear
  /// of any legitimate schedule.
  static const _schedulingHorizon = Duration(hours: 1);

  final List<SyncJob> _jobs = [];
  SyncState _state = SyncState();
  bool _restored = false;
  Directory? _dirCache;

  // ---------------------------------------------------------------------------
  // Read-only views
  // ---------------------------------------------------------------------------

  /// Snapshot of the queue in execution order (oldest [SyncJob.id] first).
  List<SyncJob> get jobs => List<SyncJob>.unmodifiable(_jobs);

  int get length => _jobs.length;

  bool get isEmpty => _jobs.isEmpty;

  bool get isNotEmpty => _jobs.isNotEmpty;

  bool get isRestored => _restored;

  /// The mutable sync-state ledger. After changing it, call [saveState]
  /// (or [flush]) to persist.
  SyncState get state => _state;

  SyncJob? jobById(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  List<SyncJob> jobsWithDedupeKey(String dedupeKey) =>
      _jobs.where((j) => j.dedupeKey == dedupeKey).toList(growable: false);

  List<SyncJob> byStatus(SyncJobStatus status) =>
      _jobs.where((j) => j.status == status).toList(growable: false);

  /// Pending jobs whose backoff window has elapsed at [now], in
  /// deterministic execution order. Pure — does not touch disk. Per-entity
  /// serialization / job-ordering is the sync manager's job, not this one.
  List<SyncJob> eligible(DateTime now) {
    final nowUtc = now.toUtc();
    return _jobs.where((j) => j.isEligible(nowUtc)).toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Restore
  // ---------------------------------------------------------------------------

  /// Loads `queue.json` and `sync_state.json` from disk. Resets any
  /// surviving `inProgress` job to `pending`, clamps a far-future
  /// [SyncJob.nextAttemptAt] back to now, tolerates a corrupt/missing file
  /// (quarantining anything unparseable), and re-persists the normalized
  /// queue so the reset is durable.
  Future<void> restore() async {
    final dir = await _dir();
    final now = _clock();
    final horizon = now.add(_schedulingHorizon);

    _jobs.clear();
    final rawJobs = await _readJson(_queueFile(dir), 'queue');
    if (rawJobs is List) {
      for (final entry in rawJobs) {
        if (entry is! Map) continue;
        SyncJob job;
        try {
          job = SyncJob.fromJson(Map<String, dynamic>.from(entry));
        } catch (e) {
          _log('skipping unreadable job (${e.runtimeType})');
          continue;
        }
        if (job.status == SyncJobStatus.inProgress) {
          job = job.copyWith(status: SyncJobStatus.pending);
        }
        if (job.nextAttemptAt.isAfter(horizon)) {
          job = job.copyWith(nextAttemptAt: now);
        }
        _jobs.add(job);
      }
    }
    _sort();
    SyncJob.primeSequence(_jobs);

    final rawState = await _readJson(_stateFile(dir), 'sync_state');
    _state = SyncState.fromJson(
      rawState is Map ? Map<String, dynamic>.from(rawState) : const {},
    );

    _restored = true;

    // Make the inProgress->pending reset / clamp durable even if the app is
    // killed again before the queue is next mutated.
    await _persistQueue(dir);
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  /// Adds [job], applying the approved coalescing rules, then persists.
  ///
  /// Returns the job that represents the work afterwards:
  ///  * the same [job] when it was added as-is,
  ///  * an existing job that was **refreshed in place** (same id/position,
  ///    reset to `pending` with `attempts = 0` and the backoff cleared),
  ///  * `null` when the job was **discarded** because a `pending` /
  ///    `inProgress` `DELETE_BATCH` for the same batch already supersedes
  ///    it.
  Future<SyncJob?> enqueue(SyncJob job) async {
    final result = _applyEnqueue(job);
    await _persistQueue();
    return result;
  }

  SyncJob? _applyEnqueue(SyncJob job) {
    // 1. A DELETE_BATCH already in flight for this batch wins: drop any
    //    later batch/scan/image push for it.
    if (job.isBatchContentPush && _hasActiveBatchDelete(job.batchId)) {
      return null;
    }

    // 2. A new DELETE_BATCH cancels every not-yet-running content push for
    //    that batch (an in-progress one is left to finish — the idempotent
    //    delete cleans up after it).
    if (job.type == SyncJobType.deleteBatch && job.batchId != null) {
      _jobs.removeWhere((j) =>
          j.isBatchContentPush &&
          j.batchId == job.batchId &&
          j.status != SyncJobStatus.inProgress);
    }

    // 3. Coalesce by dedupeKey.
    final sameKey = _jobs.where((j) => j.dedupeKey == job.dedupeKey).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final refreshable = sameKey
        .where((j) => j.status != SyncJobStatus.inProgress)
        .toList(growable: false);

    if (refreshable.isNotEmpty) {
      // Refresh the earliest matching job in place; drop any duplicates so
      // one dedupeKey never has more than one non-inProgress job.
      final keep = refreshable.first;
      for (final dup in refreshable.skip(1)) {
        _jobs.removeWhere((j) => j.id == dup.id);
      }
      final refreshed = keep.copyWith(
        status: SyncJobStatus.pending,
        attempts: 0,
        nextAttemptAt: _clock(),
        clearLastErrorCode: true,
      );
      _replace(refreshed);
      return refreshed;
    }

    // Only an in-progress job (or nothing) matches this key: add the
    // newcomer as a follow-up so the newer local state is not lost.
    _jobs.add(job);
    _sort();
    return job;
  }

  /// Removes the job with [id] (e.g. once it has synced) and persists.
  /// Returns whether a job was actually removed.
  Future<bool> remove(String id) async {
    final before = _jobs.length;
    _jobs.removeWhere((j) => j.id == id);
    final removed = _jobs.length != before;
    if (removed) await _persistQueue();
    return removed;
  }

  /// Replaces the stored job sharing [SyncJob.id] with [job] (status /
  /// attempts / backoff updates from the processor) and persists. Returns
  /// whether a matching job was found.
  Future<bool> update(SyncJob job) async {
    final index = _jobs.indexWhere((j) => j.id == job.id);
    if (index < 0) return false;
    _jobs[index] = job;
    _sort();
    await _persistQueue();
    return true;
  }

  /// Drops every not-yet-running batch/scan/image push for [batchId] (used
  /// when a batch is deleted locally, before the `DELETE_BATCH` /
  /// `DELETE_STORAGE_PREFIX` jobs are enqueued). In-progress jobs are left
  /// to finish. Returns the number of jobs removed.
  Future<int> cancelPushesForBatch(String batchId) async {
    final before = _jobs.length;
    _jobs.removeWhere((j) =>
        j.isBatchContentPush &&
        j.batchId == batchId &&
        j.status != SyncJobStatus.inProgress);
    final removed = before - _jobs.length;
    if (removed > 0) await _persistQueue();
    return removed;
  }

  /// Writes both the queue and the sync-state files.
  Future<void> flush() async {
    final dir = await _dir();
    await _persistQueue(dir);
    await _persistState(dir);
  }

  /// Persists just the sync-state ledger (after a caller mutates [state]).
  Future<void> saveState() => _persistState();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  bool _hasActiveBatchDelete(String? batchId) {
    if (batchId == null) return false;
    return _jobs.any((j) =>
        j.type == SyncJobType.deleteBatch &&
        j.batchId == batchId &&
        (j.status == SyncJobStatus.pending ||
            j.status == SyncJobStatus.inProgress));
  }

  void _replace(SyncJob job) {
    final index = _jobs.indexWhere((j) => j.id == job.id);
    if (index >= 0) {
      _jobs[index] = job;
    } else {
      _jobs.add(job);
    }
    _sort();
  }

  void _sort() => _jobs.sort((a, b) => a.id.compareTo(b.id));

  Future<Directory> _dir() async {
    if (_dirCache != null) return _dirCache!;
    final base = rootOverride ?? await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_folderName');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _dirCache = dir;
    return dir;
  }

  File _queueFile(Directory dir) => File('${dir.path}/$_queueFileName');

  File _stateFile(Directory dir) => File('${dir.path}/$_stateFileName');

  /// Reads and JSON-decodes [file], preferring the committed file but
  /// falling back to a leftover `*.tmp` from an interrupted write.
  /// Anything that will not parse is quarantined (renamed to
  /// `*.corrupt-<millis>`) and treated as absent — a bad file on disk must
  /// never take down the queue.
  Future<Object?> _readJson(File file, String label) async {
    for (final candidate in [file, File('${file.path}$_tmpSuffix')]) {
      if (!candidate.existsSync()) continue;
      try {
        final raw = await candidate.readAsString();
        if (raw.trim().isEmpty) return null;
        return jsonDecode(raw);
      } catch (e) {
        _log('corrupt $label file (${e.runtimeType})');
        _quarantine(candidate);
      }
    }
    return null;
  }

  void _quarantine(File file) {
    try {
      final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
      file.renameSync('${file.path}.corrupt-$stamp');
    } catch (_) {
      // Best effort only; if we cannot move it aside we still carry on
      // with an empty queue.
    }
  }

  Future<void> _persistQueue([Directory? dir]) async {
    final target = _queueFile(dir ?? await _dir());
    final encoded = const JsonEncoder.withIndent('  ')
        .convert(_jobs.map((j) => j.toJson()).toList());
    await _atomicWrite(target, encoded);
  }

  Future<void> _persistState([Directory? dir]) async {
    final target = _stateFile(dir ?? await _dir());
    final encoded = const JsonEncoder.withIndent('  ').convert(_state.toJson());
    await _atomicWrite(target, encoded);
  }

  /// Temp-file + flush + atomic rename, matching `LocalBatchRepository`'s
  /// safe-write intent. On platforms whose `rename` refuses to clobber an
  /// existing file (Windows), fall back to delete-then-rename; [restore]
  /// can still recover from the `*.tmp` file if a crash lands in that
  /// window.
  Future<void> _atomicWrite(File target, String contents) async {
    final tmp = File('${target.path}$_tmpSuffix');
    await tmp.writeAsString(contents, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      if (target.existsSync()) target.deleteSync();
      await tmp.rename(target.path);
    }
  }

  void _log(String message) {
    // Mirrors LocalBatchRepository's tolerance for a bad file on disk.
    // ignore: avoid_print
    print('SyncQueue: $message');
  }
}

/// The durable "what have we already pushed?" ledger stored beside the job
/// queue in `sync_state.json`. It holds only identifiers, timestamps and
/// flags — never row data.
///
/// Keys:
///  * `batch:<batchId>`          -> `{ lastPushedUpdatedAt }`
///  * `scan:<batchId>:<scanId>`  -> `{ originalUploaded, rectifiedUploaded }`
///  * `answerKey:<examCode>`     -> `{ lastPushedVersion, lastPushedUpdatedAt }`
///
/// All timestamps are serialized as UTC ISO-8601.
class SyncState {
  SyncState([Map<String, dynamic>? raw]) : _raw = raw ?? <String, dynamic>{};

  factory SyncState.fromJson(Map<String, dynamic> json) =>
      SyncState(Map<String, dynamic>.from(json));

  final Map<String, dynamic> _raw;

  static String batchKey(String batchId) => 'batch:$batchId';

  static String scanKey(String batchId, String scanId) =>
      'scan:$batchId:$scanId';

  static String answerKeyKey(String examCode) => 'answerKey:$examCode';

  Map<String, dynamic>? _entry(String key) {
    final value = _raw[key];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }

  // --- batch ---------------------------------------------------------------

  DateTime? batchLastPushedUpdatedAt(String batchId) =>
      _parseUtc(_entry(batchKey(batchId))?['lastPushedUpdatedAt']);

  void setBatchPushed(String batchId, DateTime lastPushedUpdatedAt) {
    _raw[batchKey(batchId)] = {
      'lastPushedUpdatedAt': lastPushedUpdatedAt.toUtc().toIso8601String(),
    };
  }

  // --- scan ---------------------------------------------------------------

  bool scanOriginalUploaded(String batchId, String scanId) =>
      _entry(scanKey(batchId, scanId))?['originalUploaded'] == true;

  bool scanRectifiedUploaded(String batchId, String scanId) =>
      _entry(scanKey(batchId, scanId))?['rectifiedUploaded'] == true;

  void setScanUploaded(
    String batchId,
    String scanId, {
    bool? original,
    bool? rectified,
  }) {
    final key = scanKey(batchId, scanId);
    final entry = _entry(key) ?? <String, dynamic>{};
    entry['originalUploaded'] = original ?? (entry['originalUploaded'] == true);
    entry['rectifiedUploaded'] =
        rectified ?? (entry['rectifiedUploaded'] == true);
    _raw[key] = entry;
  }

  // --- answer key -------------------------------------------------------

  int? answerKeyLastPushedVersion(String examCode) {
    final value = _entry(answerKeyKey(examCode))?['lastPushedVersion'];
    return value is num ? value.toInt() : null;
  }

  DateTime? answerKeyLastPushedUpdatedAt(String examCode) =>
      _parseUtc(_entry(answerKeyKey(examCode))?['lastPushedUpdatedAt']);

  void setAnswerKeyPushed(
    String examCode, {
    required int version,
    required DateTime updatedAt,
  }) {
    _raw[answerKeyKey(examCode)] = {
      'lastPushedVersion': version,
      'lastPushedUpdatedAt': updatedAt.toUtc().toIso8601String(),
    };
  }

  // --- shared ---------------------------------------------------------

  /// Drops one key outright.
  void forget(String key) => _raw.remove(key);

  /// Drops the batch entry and every `scan:<batchId>:*` entry (used when a
  /// batch is deleted).
  void forgetBatch(String batchId) {
    final scanPrefix = 'scan:$batchId:';
    _raw.removeWhere(
      (key, _) => key == batchKey(batchId) || key.startsWith(scanPrefix),
    );
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_raw);
}

DateTime? _parseUtc(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw)?.toUtc();
}
