import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/local_batch.dart';
import '../services/local_batch_repository.dart';
import '../services/local_storage_service.dart';
import 'sync_client.dart';
import 'sync_job.dart';
import 'sync_outcome.dart';
import 'sync_queue.dart' show SyncState;

/// The signed-in Firebase identity, as far as the sync client needs it.
///
/// Kept abstract so this file has no `firebase_auth` dependency and stays
/// unit-testable; the sync manager (a later phase) supplies the real
/// implementation.
abstract class SyncIdentity {
  /// Firebase UID of the signed-in guidance user, or null when signed out.
  String? get uid;

  /// Firebase `displayName`, or null.
  String? get displayName;

  /// Forces a fresh Firebase ID token so the next Supabase request carries
  /// a new JWT (called once after a 401 / PGRST301). Returns whether a
  /// refresh actually happened.
  Future<bool> refreshToken();
}

/// Which kind of Storage call a guarded block is making — decides how a
/// `404` is treated.
enum StorageOp { read, write, delete, list }

/// What [SupabaseSyncClient.decideAnswerKeyPush] concluded a `pushAnswerKey`
/// attempt should do, given the current cloud row and the job's [meta].
enum AnswerKeyAction {
  /// Write the local answers to the cloud at [AnswerKeyDecision.version].
  upsert,

  /// The cloud already holds exactly these answers under a version this
  /// device has never recorded — take the cloud version/timestamp as the
  /// new local baseline and write nothing.
  adopt,

  /// Refuse: the cloud has moved in a way the caller must resolve first.
  conflict,
}

/// The pure outcome of [SupabaseSyncClient.decideAnswerKeyPush] — no I/O,
/// no PII. Only ever one of: upsert (with the target [version] and the
/// [baselineUpdatedAt] to stamp), adopt (same fields, but taken from the
/// cloud row), or conflict (with a sanitized [conflictCode]).
class AnswerKeyDecision {
  AnswerKeyDecision.upsert({
    required this.version,
    required this.baselineUpdatedAt,
  })  : action = AnswerKeyAction.upsert,
        conflictCode = null;

  AnswerKeyDecision.adopt({
    required this.version,
    required this.baselineUpdatedAt,
  })  : action = AnswerKeyAction.adopt,
        conflictCode = null;

  const AnswerKeyDecision.conflict(this.conflictCode)
      : action = AnswerKeyAction.conflict,
        version = null,
        baselineUpdatedAt = null;

  final AnswerKeyAction action;

  /// The version to write / adopt. Null only for [AnswerKeyAction.conflict].
  final int? version;

  /// The `updated_at` to stamp on the row / record as the baseline. Null
  /// only for [AnswerKeyAction.conflict].
  final DateTime? baselineUpdatedAt;

  /// Sanitized conflict code. Set only for [AnswerKeyAction.conflict].
  final String? conflictCode;

  bool get isUpsert => action == AnswerKeyAction.upsert;
  bool get isAdopt => action == AnswerKeyAction.adopt;
  bool get isConflict => action == AnswerKeyAction.conflict;
}

/// The **only** class in `lib/core/sync` that talks to
/// `Supabase.instance.client`. Every method:
///
///  * re-reads the current local state from [LocalBatchRepository] /
///    [LocalStorageService] and builds the request payload *now*, so a
///    stale queued job can never push old data;
///  * returns a [SyncOutcome] with a sanitized short code — never a raw
///    exception, token, key, row snapshot or PII;
///  * treats "the local entity is gone" as an idempotent success.
///
/// It performs no retries or backoff of its own beyond a single
/// token-refresh retry on an auth error; scheduling is the sync manager's
/// job.
class SupabaseSyncClient implements SyncClient {
  SupabaseSyncClient({
    required this.batches,
    required this.localStorage,
    required this.identity,
    required SyncState Function() getSyncState,
    SupabaseClient? client,
  })  : _syncStateGetter = getSyncState,
        _client = client ?? Supabase.instance.client;

  final LocalBatchRepository batches;
  final LocalStorageService localStorage;
  final SyncIdentity identity;
  final SupabaseClient _client;

  final SyncState Function() _syncStateGetter;

  /// The queue's *current* [SyncState], resolved on every access. This is
  /// never cached in a field, so a `SyncQueue.restore()` that swaps
  /// `queue.state` (before, during, or after restore) is always reflected
  /// and the client can never read or mutate a stale reference. The single
  /// source of truth stays the queue's own [SyncState] — nothing is
  /// duplicated here.
  SyncState get syncState => _syncStateGetter();

  /// Private Storage bucket that holds the scanned sheet images.
  static const String storageBucket = 'scanned-sheets';

  static const int _batchSchemaVersion = 1;
  static const int _scanSchemaVersion = 1;
  static const int _answerKeySchemaVersion = 1;

  static const int _listPageSize = 100;
  static const int _removeChunkSize = 100;

  // ---------------------------------------------------------------------------
  // Pure helpers (static + no I/O -> unit-testable without a client)
  // ---------------------------------------------------------------------------

  /// Storage object key for a scan's original captured photo.
  static String originalImageKey(String batchId, String scanId) =>
      'batches/$batchId/scans/$scanId/original.jpg';

  /// Storage object key for a scan's perspective-corrected overlay photo.
  static String rectifiedImageKey(String batchId, String scanId) =>
      'batches/$batchId/scans/$scanId/rectified.jpg';

  /// Storage prefix that contains everything for one batch.
  static String batchStoragePrefix(String batchId) => 'batches/$batchId/';

  /// The one timestamp serialization the whole sync layer uses: UTC,
  /// ISO-8601, trailing `Z`.
  static String isoUtc(DateTime value) => value.toUtc().toIso8601String();

  static String? _isoOrNull(DateTime? value) =>
      value == null ? null : isoUtc(value);

  /// The `answer_keys` row payload. Exposed for tests: `answers` must be
  /// the app's flat `"Section|Item" -> "Choice"` map verbatim (no nesting).
  static Map<String, dynamic> answerKeyRow({
    required String examCode,
    required Map<String, String> answers,
    required int version,
    required String? updatedByUid,
    required String? updatedByName,
    required DateTime updatedAt,
  }) =>
      {
        'exam_code': examCode,
        'answers': Map<String, String>.from(answers),
        'version': version,
        'updated_by_uid': updatedByUid,
        'updated_by_name': updatedByName,
        'updated_at': isoUtc(updatedAt),
        'schema_version': _answerKeySchemaVersion,
      };

  /// Parse a raw `answer_keys` row (as returned by `.maybeSingle()`) into a
  /// [CloudAnswerKeyRead]. A null row -> [CloudAnswerKeyRead.absent]. Never
  /// reads `updated_by_uid` or any auth column — only the four fields the
  /// resolution UI needs.
  static CloudAnswerKeyRead parseCloudAnswerKeyRow(Map<String, dynamic>? row) {
    if (row == null) return const CloudAnswerKeyRead.absent();
    return CloudAnswerKeyRead.found(
      version: (row['version'] as num?)?.toInt() ?? 0,
      answers: _asStringMap(row['answers']),
      updatedByName: row['updated_by_name'] as String?,
      updatedAt: _isoOrNullFromRaw(row['updated_at']),
    );
  }

  /// Decide what a `pushAnswerKey` should do. Pure: no I/O, no clock unless
  /// [now] is omitted, no PII. Inputs are the local answers, the job [meta],
  /// this device's last-pushed version, and the current cloud row's version
  /// / answers / `updated_at` (all null when there is no cloud row).
  ///
  ///  * **Force** (`meta['force'] == 'true'`): no cloud row ->
  ///    `conflict('answer_key_missing')`; cloud version != the confirmed
  ///    `meta['expectedCloudVersion']` -> `conflict('answer_key_changed')`;
  ///    otherwise upsert at `cloudVersion + 1`.
  ///  * **No cloud row**: first push, upsert at version 1.
  ///  * **Cloud row, never pushed from here** (`lastPushedVersion == null`):
  ///    identical answers -> adopt the cloud version + timestamp as the
  ///    baseline (no write); different answers ->
  ///    `conflict('answer_key_changed')`.
  ///  * **Cloud advanced past our baseline** -> `conflict('answer_key_changed')`.
  ///  * **Otherwise** upsert at `cloudVersion + 1`.
  static AnswerKeyDecision decideAnswerKeyPush({
    required Map<String, String> localAnswers,
    required Map<String, String> meta,
    required int? lastPushedVersion,
    required int? cloudVersion,
    required Map<String, String>? cloudAnswers,
    required DateTime? cloudUpdatedAt,
    DateTime? now,
  }) {
    final resolvedNow = (now ?? DateTime.now()).toUtc();

    if (meta['force'] == 'true') {
      if (cloudVersion == null) {
        return const AnswerKeyDecision.conflict('answer_key_missing');
      }
      final expected = int.tryParse(meta['expectedCloudVersion'] ?? '');
      if (expected == null || cloudVersion != expected) {
        return const AnswerKeyDecision.conflict('answer_key_changed');
      }
      return AnswerKeyDecision.upsert(
        version: cloudVersion + 1,
        baselineUpdatedAt: resolvedNow,
      );
    }

    if (cloudVersion == null) {
      return AnswerKeyDecision.upsert(version: 1, baselineUpdatedAt: resolvedNow);
    }

    if (lastPushedVersion == null) {
      if (_mapsEqual(localAnswers, cloudAnswers ?? const {})) {
        return AnswerKeyDecision.adopt(
          version: cloudVersion,
          baselineUpdatedAt: (cloudUpdatedAt ?? resolvedNow).toUtc(),
        );
      }
      return const AnswerKeyDecision.conflict('answer_key_changed');
    }

    if (cloudVersion > lastPushedVersion) {
      return const AnswerKeyDecision.conflict('answer_key_changed');
    }

    return AnswerKeyDecision.upsert(
      version: cloudVersion + 1,
      baselineUpdatedAt: resolvedNow,
    );
  }

  /// A JSON object coerced to a flat `String -> String` map (the shape of
  /// `answer_keys.answers`). Anything that is not a map -> `{}`.
  static Map<String, String> _asStringMap(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
  }

  /// A raw `updated_at` (String or DateTime) normalized to the sync layer's
  /// one timestamp format, or null when it is neither / unparseable.
  static String? _isoOrNullFromRaw(Object? raw) {
    final parsed = _dateOrNull(raw);
    return parsed == null ? null : isoUtc(parsed);
  }

  static DateTime? _dateOrNull(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    if (raw is! String) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  /// Blank-after-trim (including null) -> null; otherwise the original
  /// string, untrimmed. See the `examinee_number`/`first_name`/`last_name`
  /// comment in [pushScan] for why this matters.
  static String? _blankToNull(String? value) =>
      (value == null || value.trim().isEmpty) ? null : value;

  static bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// The examinee tag-audit columns for a `scans` upsert, or an **empty
  /// map** for a normal push.
  ///
  /// A normal `PUSH_SCAN` (addScan / rescan / result / reconcile) carries
  /// no recognized `operation`, so this returns `{}` and the four columns
  /// are simply absent from the upsert map — an `ON CONFLICT DO UPDATE`
  /// then leaves whatever tag audit the cloud row already has untouched.
  ///
  /// For `operation == "examinee_tag" | "examinee_clear"` the columns are
  /// written, but tagged-vs-cleared is taken from [isTagged] — the CURRENT
  /// local scan — never from the label: a job stamped `examinee_tag` whose
  /// scan has since been cleared locally is written as a clear.
  /// [tsIso] is the operation time (from `meta["opAt"]`, already parsed to
  /// a UTC ISO-8601 string with a fallback).
  static Map<String, dynamic> examineeAuditColumns({
    required Map<String, String> meta,
    required bool isTagged,
    required String? identityUid,
    required String? identityDisplayName,
    DateTime? now,
  }) {
    final operation = meta['operation'];
    if (operation != 'examinee_tag' && operation != 'examinee_clear') {
      return const {};
    }
    final tsIso = isoUtc(
      DateTime.tryParse(meta['opAt'] ?? '')?.toUtc() ??
          (now ?? DateTime.now()).toUtc(),
    );
    if (isTagged) {
      return {
        'tagged_by_uid': identityUid,
        'tagged_by_name': identityDisplayName,
        'tagged_at': tsIso,
        'examinee_updated_at': tsIso,
      };
    }
    return {
      'tagged_by_uid': null,
      'tagged_by_name': null,
      'tagged_at': null,
      'examinee_updated_at': tsIso,
    };
  }

  /// Deterministic, sanitized classification of a PostgREST error `code`.
  /// `401` / `PGRST301` only reach here after the guard's one
  /// refresh-and-retry, so a still-failing auth error is permanent; a
  /// `42501` is always permanent too.
  static SyncOutcome classifyPostgrestCode(String? rawCode) {
    final code = _sanitizeCode(rawCode);
    switch (code) {
      case '42501':
        return const SyncOutcome.permanent('42501');
      case '22P02':
        return const SyncOutcome.permanent('22P02');
      case '23502':
        return const SyncOutcome.permanent('23502');
      case '23505':
        return const SyncOutcome.permanent('23505');
      case '23514':
        return const SyncOutcome.permanent('23514');
      case '429':
        return const SyncOutcome.transient('429');
      case '401':
      case 'PGRST301':
        // Still auth-failing after the guard's one refresh + retry.
        return const SyncOutcome.permanent('PGRST301');
      case '400':
      case '422':
        return SyncOutcome.permanent(code);
      case 'PGRST000':
      case 'PGRST001':
      case 'PGRST002':
      case 'PGRST003':
        return const SyncOutcome.transient('5xx');
    }
    if (RegExp(r'^5\d\d$').hasMatch(code)) {
      return const SyncOutcome.transient('5xx');
    }
    if (RegExp(r'^4\d\d$').hasMatch(code)) {
      return SyncOutcome.permanent(code);
    }
    // SQLSTATE-shaped (5 alphanumerics, e.g. 23503 FK, 22001 truncation):
    // a data/constraint error that will not fix itself.
    if (RegExp(r'^[0-9A-Z]{5}$').hasMatch(code)) {
      return SyncOutcome.permanent(code);
    }
    // Other PGRSTxxx: structural (missing column, bad schema cache).
    if (RegExp(r'^PGRST\d{3}$').hasMatch(code)) {
      return SyncOutcome.permanent(code);
    }
    // Unrecognized -> retry rather than dead-end on a classifier gap.
    return const SyncOutcome.transient('unknown');
  }

  /// Deterministic, sanitized classification of a Storage error
  /// `statusCode`, given what the call was trying to do.
  static SyncOutcome classifyStorageStatus(String? rawStatus, StorageOp op) {
    final status = _sanitizeCode(rawStatus);
    switch (status) {
      case '403':
        return const SyncOutcome.permanent('storage_403');
      case '400':
        return const SyncOutcome.permanent('storage_400');
      case '413':
        return const SyncOutcome.permanent('storage_413');
      case '429':
        return const SyncOutcome.transient('429');
      case '404':
        // Missing object: a no-op success for read / delete / prefix list;
        // unexpected for a write.
        return op == StorageOp.write
            ? const SyncOutcome.permanent('storage_404')
            : const SyncOutcome.success();
      case '401':
      case 'PGRST301':
        // Still auth-failing after the guard's one refresh + retry.
        return const SyncOutcome.permanent('storage_401');
    }
    if (RegExp(r'^5\d\d$').hasMatch(status)) {
      return const SyncOutcome.transient('5xx');
    }
    if (RegExp(r'^4\d\d$').hasMatch(status)) {
      return SyncOutcome.permanent('storage_$status');
    }
    return const SyncOutcome.transient('storage_unknown');
  }

  /// Classification for an exception that is neither a known
  /// PostgREST/Storage error nor a transport failure (`TimeoutException` /
  /// `SocketException`) — i.e. a bug or an unforeseen error type. Not
  /// retried, and the raw error is never surfaced.
  static SyncOutcome classifyUnexpectedError(Object error) =>
      const SyncOutcome.permanent('unknown');

  static String _sanitizeCode(String? raw) {
    if (raw == null) return 'unknown';
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
    if (cleaned.isEmpty) return 'unknown';
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  // ---------------------------------------------------------------------------
  // B. pushBatch
  // ---------------------------------------------------------------------------

  /// Upserts the `batches` row from the current local batch. No-op success
  /// if the batch no longer exists locally. `created_by_uid` empty ->
  /// permanent (`WITH CHECK` would reject it forever).
  @override
  Future<SyncOutcome> pushBatch(String batchId) async {
    final batch = await batches.getBatchById(batchId);
    if (batch == null) return const SyncOutcome.success();

    if (batch.createdByUid.trim().isEmpty) {
      return const SyncOutcome.permanent('empty_created_by');
    }

    // The immutable columns (id, batch_code, exam_code, created_by_uid,
    // created_by_name, created_at) are re-sent with their *unchanged* local
    // values — LocalBatch.copyWith never mutates them — so the
    // merge-duplicates upsert does not actually alter them; only the
    // mutable columns below can change.
    final row = <String, dynamic>{
      'id': batch.id,
      'batch_code': batch.batchCode,
      'exam_code': batch.examCode,
      'exam_title': batch.examTitle,
      'description': batch.description,
      'expected_count': batch.expectedCount,
      'status': batch.status,
      'created_by_uid': batch.createdByUid,
      'created_by_name': batch.createdByName,
      'created_at': isoUtc(batch.createdAt),
      'updated_at': isoUtc(batch.updatedAt),
      'schema_version': _batchSchemaVersion,
    };

    return _guardPostgrest(() async {
      await _client.from('batches').upsert(row, onConflict: 'id');
      syncState.setBatchPushed(batch.id, batch.updatedAt);
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // C. pushScan
  // ---------------------------------------------------------------------------

  /// Upserts the `scans` row (conflict target `batch_id,id`) from the
  /// current local scan. No-op success if the batch or scan is gone. Result
  /// columns are null when the scan is ungraded; examinee identity columns
  /// are null when untagged; `middle_name` and the dup-override columns are
  /// always null/default because the app does not track them.
  ///
  /// The four tag-audit columns (`tagged_by_uid` / `tagged_by_name` /
  /// `tagged_at` / `examinee_updated_at`) are written **only** when [meta]
  /// carries `operation == "examinee_tag" | "examinee_clear"` (a
  /// tag/clear-triggered push); for every other push they are omitted from
  /// the upsert so an update never overwrites existing cloud tag audit.
  /// See [examineeAuditColumns].
  @override
  Future<SyncOutcome> pushScan(
    String batchId,
    String scanId, {
    Map<String, String> meta = const {},
  }) async {
    final batch = await batches.getBatchById(batchId);
    if (batch == null) return const SyncOutcome.success();

    final scan = _findScan(batch, scanId);
    if (scan == null) return const SyncOutcome.success();

    final result = scan.result;
    final examinee = scan.examinee;
    final hasRectified = scan.rectifiedImageFileName != null;

    final row = <String, dynamic>{
      'id': scan.id,
      'batch_id': batch.id,
      'captured_at': isoUtc(scan.capturedAt),
      'exam_code': batch.examCode,
      'decoded': scan.decoded.toJson(),

      // result (null as a group when ungraded)
      'raw_score': result?.rawScore,
      'total_graded': result?.totalGraded,
      'total_items': result?.totalItems,
      'score_percentage': result?.percentage,
      'result_status': result?.status,
      'scanned_at': _isoOrNull(result?.scannedAt),
      'processed_by_uid': result?.processedByUid,
      'processed_by_name': result?.processedByName,

      // examinee identity (null as a group when untagged). Blank-after-trim
      // strings are sent as null, not "" -- ExamineeInfo.isEmpty only
      // clears the whole tag when EVERY field is blank (see
      // LocalBatchRepository.setScanExaminee), so a tag can legitimately
      // have a name but no examinee number yet (e.g. an OCR-suggested name,
      // or staff hasn't entered the number). Sending "" for that column
      // trips the cloud schema's CHECK constraint (SQLSTATE 23514) and
      // permanently fails this scan's push -- null does not. The tag-audit
      // columns are added below, and ONLY for a tag/clear-triggered push.
      'first_name': _blankToNull(examinee?.firstName),
      'last_name': _blankToNull(examinee?.lastName),
      'examinee_number': _blankToNull(examinee?.examineeNumber),
      'middle_name': null, // not modelled by the app

      // duplicate-number override — not tracked by the app
      'dup_override': false,
      'dup_override_reason': null,
      'dup_override_by_uid': null,
      'dup_override_at': null,

      // images: paths are the Storage keys; the *_uploaded flags reflect
      // what has actually been uploaded so far (PATCH_IMAGE_STATUS later
      // reconciles them) — never regress a true flag back to false.
      'image_path': originalImageKey(batch.id, scan.id),
      'image_uploaded': syncState.scanOriginalUploaded(batch.id, scan.id),
      'rectified_image_path':
          hasRectified ? rectifiedImageKey(batch.id, scan.id) : null,
      'rectified_image_uploaded':
          hasRectified && syncState.scanRectifiedUploaded(batch.id, scan.id),

      'created_at': isoUtc(scan.capturedAt),
      'updated_at': isoUtc(batch.updatedAt), // scans have no own vector
      'schema_version': _scanSchemaVersion,
    };

    // Tag-audit columns: written only for a tag/clear-triggered push, with
    // tagged-vs-cleared taken from the CURRENT local scan (not the label).
    row.addAll(examineeAuditColumns(
      meta: meta,
      isTagged: examinee != null && !examinee.isEmpty,
      identityUid: identity.uid,
      identityDisplayName: identity.displayName,
    ));

    return _guardPostgrest(() async {
      await _client.from('scans').upsert(row, onConflict: 'batch_id,id');
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // D. uploadImage
  // ---------------------------------------------------------------------------

  /// Uploads (or, for a now-absent rectified image, deletes) one scan image
  /// to Storage using a deterministic object key. Does **not** touch the
  /// `scans` row — [patchImageStatus] owns the `*_uploaded` columns. On
  /// success it records the upload in [SyncState] (the caller persists it).
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) async {
    final batchId = job.batchId;
    final scanId = job.scanId;
    final variant = job.meta['variant'];
    if (batchId == null ||
        scanId == null ||
        (variant != 'original' && variant != 'rectified')) {
      return const SyncOutcome.permanent('bad_job');
    }

    final batch = await batches.getBatchById(batchId);
    if (batch == null) return const SyncOutcome.success();
    final scan = _findScan(batch, scanId);
    if (scan == null) return const SyncOutcome.success();

    if (variant == 'original') {
      final file = await batches.resolveScanImage(batchId, scan);
      if (!file.existsSync()) {
        // Scan row still exists locally but its bytes are gone — not
        // recoverable, so stop retrying.
        return const SyncOutcome.permanent('local_file_missing');
      }
      final bytes = await file.readAsBytes();
      return _guardStorage(StorageOp.write, () async {
        await _client.storage.from(storageBucket).uploadBinary(
              originalImageKey(batchId, scanId),
              bytes,
              fileOptions:
                  const FileOptions(upsert: true, contentType: 'image/jpeg'),
            );
        syncState.setScanUploaded(batchId, scanId, original: true);
        return const SyncOutcome.success();
      });
    }

    // variant == 'rectified'
    final rectified = await batches.resolveScanRectifiedImage(batchId, scan);
    if (rectified == null || !rectified.existsSync()) {
      // The local rescan dropped the rectified overlay: make the cloud
      // match by removing any existing object. 404 counts as done.
      return _guardStorage(StorageOp.delete, () async {
        await _client.storage
            .from(storageBucket)
            .remove([rectifiedImageKey(batchId, scanId)]);
        syncState.setScanUploaded(batchId, scanId, rectified: false);
        return const SyncOutcome.success();
      });
    }
    final bytes = await rectified.readAsBytes();
    return _guardStorage(StorageOp.write, () async {
      await _client.storage.from(storageBucket).uploadBinary(
            rectifiedImageKey(batchId, scanId),
            bytes,
            fileOptions:
                const FileOptions(upsert: true, contentType: 'image/jpeg'),
          );
      syncState.setScanUploaded(batchId, scanId, rectified: true);
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // E. patchImageStatus
  // ---------------------------------------------------------------------------

  /// Sets only `image_uploaded`, `rectified_image_uploaded` and
  /// `updated_at` on the `scans` row, reading the upload flags from
  /// [SyncState]. A PostgREST update matching no rows is not an error, so a
  /// missing cloud row is a no-op success.
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) async {
    final batch = await batches.getBatchById(batchId);
    if (batch == null) return const SyncOutcome.success();
    if (_findScan(batch, scanId) == null) return const SyncOutcome.success();

    final patch = <String, dynamic>{
      'image_uploaded': syncState.scanOriginalUploaded(batchId, scanId),
      'rectified_image_uploaded':
          syncState.scanRectifiedUploaded(batchId, scanId),
      // No local timestamp for "flags flipped" — wall-clock now, in UTC.
      'updated_at': isoUtc(DateTime.now()),
    };

    return _guardPostgrest(() async {
      await _client
          .from('scans')
          .update(patch)
          .eq('batch_id', batchId)
          .eq('id', scanId);
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // F. pushAnswerKey
  // ---------------------------------------------------------------------------

  /// Read-only fetch of the current cloud `answer_keys` row for [examCode],
  /// used by the answer-key conflict-resolution flow. Selects only
  /// `version, answers, updated_by_name, updated_at` — never
  /// `updated_by_uid`, an email or a token. A missing row is
  /// [CloudAnswerKeyRead.absent] (not an error); a PostgREST / transport
  /// failure is [CloudAnswerKeyRead.failed] with a sanitized [SyncOutcome].
  /// Mirrors [_guardPostgrest]'s single token-refresh retry on a 401.
  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    var refreshed = false;
    while (true) {
      try {
        final row = await _client
            .from('answer_keys')
            .select('version, answers, updated_by_name, updated_at')
            .eq('exam_code', examCode)
            .maybeSingle();
        return parseCloudAnswerKeyRow(row);
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudAnswerKeyRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudAnswerKeyRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudAnswerKeyRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudAnswerKeyRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Upserts the `answer_keys` row (conflict target `exam_code`) from the
  /// current local answer key, storing `answers` as the app's flat map
  /// verbatim. Reads the current cloud row first and delegates the
  /// safe/unsafe decision to [decideAnswerKeyPush]:
  ///
  ///  * a first push (no cloud row) writes version 1;
  ///  * a cloud row this device has never recorded is **adopted** as the
  ///    baseline when the answers already match, and is otherwise a
  ///    `conflict('answer_key_changed')` — it never blind-overwrites;
  ///  * a cloud row that advanced past our baseline is a
  ///    `conflict('answer_key_changed')`;
  ///  * [meta] `{"force":"true","expectedCloudVersion":"<n>"}` (from a
  ///    user-confirmed resolution) upserts only when the cloud is still at
  ///    version `n`, else `conflict('answer_key_changed')` /
  ///    `conflict('answer_key_missing')`.
  ///
  /// [SyncState] is advanced only on a successful adopt or upsert.
  @override
  Future<SyncOutcome> pushAnswerKey(
    String examCode, {
    Map<String, String> meta = const {},
  }) async {
    final keys = await localStorage.loadAnswerKeys();
    final key = keys[examCode];
    if (key == null) return const SyncOutcome.success();

    return _guardPostgrest(() async {
      final existing = await _client
          .from('answer_keys')
          .select('version, answers, updated_at')
          .eq('exam_code', examCode)
          .maybeSingle();

      final decision = decideAnswerKeyPush(
        localAnswers: key.correctChoices,
        meta: meta,
        lastPushedVersion: syncState.answerKeyLastPushedVersion(examCode),
        cloudVersion: existing == null
            ? null
            : (existing['version'] as num?)?.toInt() ?? 0,
        cloudAnswers:
            existing == null ? null : _asStringMap(existing['answers']),
        cloudUpdatedAt:
            existing == null ? null : _dateOrNull(existing['updated_at']),
      );

      switch (decision.action) {
        case AnswerKeyAction.conflict:
          return SyncOutcome.conflict(decision.conflictCode!);
        case AnswerKeyAction.adopt:
          syncState.setAnswerKeyPushed(
            examCode,
            version: decision.version!,
            updatedAt: decision.baselineUpdatedAt!,
          );
          return const SyncOutcome.success();
        case AnswerKeyAction.upsert:
          final row = answerKeyRow(
            examCode: examCode,
            answers: key.correctChoices,
            version: decision.version!,
            updatedByUid: identity.uid,
            updatedByName: identity.displayName,
            updatedAt: decision.baselineUpdatedAt!,
          );
          await _client
              .from('answer_keys')
              .upsert(row, onConflict: 'exam_code');
          syncState.setAnswerKeyPushed(
            examCode,
            version: decision.version!,
            updatedAt: decision.baselineUpdatedAt!,
          );
          return const SyncOutcome.success();
      }
    });
  }

  // ---------------------------------------------------------------------------
  // G. deleteBatch
  // ---------------------------------------------------------------------------

  /// Deletes the `batches` row. Zero rows affected is still success. Scans
  /// are removed by the DB cascade and the `batch_deleted` audit row is
  /// written by the DB trigger — this never touches `scans` or
  /// `guidance_activity`.
  @override
  Future<SyncOutcome> deleteBatch(String batchId) {
    return _guardPostgrest(() async {
      await _client.from('batches').delete().eq('id', batchId);
      syncState.forgetBatch(batchId);
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // H. deleteStoragePrefix
  // ---------------------------------------------------------------------------

  /// Recursively lists every object under `batches/<batchId>/` and removes
  /// them in chunks. An empty prefix is success; a not-found during removal
  /// is success; a mid-way transport failure is transient and a retry
  /// removes whatever is left.
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) {
    return _guardStorage(StorageOp.delete, () async {
      final keys = await _listAllKeys(batchStoragePrefix(batchId));
      for (var i = 0; i < keys.length; i += _removeChunkSize) {
        final chunk = keys.sublist(
          i,
          math.min(i + _removeChunkSize, keys.length),
        );
        await _client.storage.from(storageBucket).remove(chunk);
      }
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  LocalScan? _findScan(LocalBatch batch, String scanId) {
    for (final scan in batch.scans) {
      if (scan.id == scanId) return scan;
    }
    return null;
  }

  /// Depth-first walk of a Storage prefix (Supabase `list` is one level;
  /// folder pseudo-entries have a null `id`).
  Future<List<String>> _listAllKeys(String prefix) async {
    final normalizedRoot =
        prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix;
    final out = <String>[];
    final pending = <String>[normalizedRoot];

    while (pending.isNotEmpty) {
      final dir = pending.removeLast();
      var offset = 0;
      while (true) {
        final page = await _client.storage.from(storageBucket).list(
              path: dir,
              searchOptions:
                  SearchOptions(limit: _listPageSize, offset: offset),
            );
        for (final entry in page) {
          final fullPath = '$dir/${entry.name}';
          if (entry.id == null) {
            pending.add(fullPath); // folder -> recurse
          } else {
            out.add(fullPath);
          }
        }
        if (page.length < _listPageSize) break;
        offset += _listPageSize;
      }
    }
    return out;
  }

  Future<SyncOutcome> _guardPostgrest(
    Future<SyncOutcome> Function() body,
  ) async {
    var refreshed = false;
    while (true) {
      try {
        return await body();
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return classifyPostgrestCode(code);
      } on TimeoutException {
        return const SyncOutcome.transient('network');
      } on SocketException {
        return const SyncOutcome.transient('network');
      } catch (e) {
        _logUnclassified(e);
        return classifyUnexpectedError(e);
      }
    }
  }

  Future<SyncOutcome> _guardStorage(
    StorageOp op,
    Future<SyncOutcome> Function() body,
  ) async {
    var refreshed = false;
    while (true) {
      try {
        return await body();
      } on StorageException catch (e) {
        final status = _sanitizeCode(e.statusCode);
        if ((status == '401' || status == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return classifyStorageStatus(status, op);
      } on TimeoutException {
        return const SyncOutcome.transient('network');
      } on SocketException {
        return const SyncOutcome.transient('network');
      } catch (e) {
        _logUnclassified(e);
        return classifyUnexpectedError(e);
      }
    }
  }

  Future<bool> _safeRefresh() async {
    try {
      return await identity.refreshToken();
    } catch (_) {
      return false;
    }
  }

  void _logUnclassified(Object error) {
    // Type only — the message may embed a payload, token or PII.
    // ignore: avoid_print
    print('SupabaseSyncClient: unclassified ${error.runtimeType}');
  }
}
