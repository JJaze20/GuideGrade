import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/local_batch.dart';
import '../services/local_batch_repository.dart';
import '../services/local_storage_service.dart';
import 'admin_scan_restore_client.dart';
import 'retake_client.dart';
import 'scan_cloud_extensions.dart';
import 'scan_delete_client.dart';
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
class SupabaseSyncClient
    implements SyncClient, RetakeClient, ScanDeleteClient, AdminScanRestoreClient {
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

  /// The `uploadImage` job variants that upload one of a scan's optional
  /// handwritten-name crops (see [LocalScan.nameCropLastFileName] and its two
  /// siblings). Each is also the crop's Storage file name (plus `.jpg`).
  static const String variantNameLast = 'name_last';
  static const String variantNameFirst = 'name_first';
  static const String variantNameMiddle = 'name_mi';

  /// Every name-crop variant, in Last / First / MI order.
  static const List<String> nameCropVariants = [
    variantNameLast,
    variantNameFirst,
    variantNameMiddle,
  ];

  /// Storage object key for one name crop of a scan, e.g.
  /// `batches/<batch>/scans/<scan>/name_last.jpg`. Same folder and
  /// `batches/` first segment as the original / rectified photos, so the
  /// bucket's existing access rules apply to it unchanged.
  static String nameCropImageKey(
    String batchId,
    String scanId,
    String variant,
  ) {
    if (!nameCropVariants.contains(variant)) {
      throw ArgumentError.value(variant, 'variant', 'not a name-crop variant');
    }
    return 'batches/$batchId/scans/$scanId/$variant.jpg';
  }

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

  /// True only for a **complete** local tag — first name, last name and
  /// examinee number all non-blank ([ExamineeInfo.isComplete]). A null,
  /// empty, or partial tag (e.g. an OCR-suggested name with no number yet)
  /// is not "tagged" as far as the cloud is concerned.
  static bool examineeTagged(ExamineeInfo? examinee) =>
      examinee != null && examinee.isComplete;

  /// The `scans` identity columns (`first_name` / `middle_name` /
  /// `last_name` / `examinee_number`) for [examinee].
  ///
  /// Each field is sent INDEPENDENTLY -- an available value, or SQL NULL
  /// when unavailable -- never a fake placeholder like `"UNKNOWN"`. This
  /// supports the automatic-identity feature: [examinee] is expected to
  /// always carry a generated `examineeNumber` for any scan created after
  /// that feature shipped (see `AppState.buildAutoExaminee` /
  /// `resolveRescanExaminee`), with `firstName`/`middleName`/`lastName`
  /// independently blank whenever on-device OCR couldn't read that field.
  /// [examinee] itself can still be null (a scan pushed before this
  /// feature existed, or one whose tag was explicitly cleared), in which
  /// case all four columns are null.
  ///
  /// ============================================================
  /// DEPLOYMENT DEPENDENCY -- READ BEFORE RELYING ON THIS IN PRODUCTION
  /// ============================================================
  /// The cloud `scans` table has historically enforced an
  /// `examinee_all_or_nothing` CHECK constraint requiring `first_name`,
  /// `last_name`, and `examinee_number` to be either ALL NULL or ALL NOT
  /// NULL (see this function's git history / the accompanying
  /// investigation report). Sending a generated, always-non-null
  /// `examinee_number` alongside a null `first_name`/`last_name` --
  /// which now happens ROUTINELY BY DESIGN whenever OCR only partially
  /// reads a name, or fails to read one at all -- violates that
  /// constraint (SQLSTATE `23514`) and PERMANENTLY FAILS THE ENTIRE
  /// SCAN'S PUSH (the whole row -- score included, since it's one
  /// `.upsert()` -- not just the identity columns). This constraint MUST
  /// be relaxed on the Supabase side (to no longer require the trio
  /// together -- `examinee_number` should be independently always-valid
  /// on its own) before this code path is exercised against production
  /// data. No schema change has been made from this codebase -- that is
  /// a deliberate, separate, out-of-band decision for whoever administers
  /// the Supabase project.
  static Map<String, dynamic> scanIdentityColumns(ExamineeInfo? examinee) {
    if (examinee == null) {
      return const {
        'first_name': null,
        'middle_name': null,
        'last_name': null,
        'examinee_number': null,
      };
    }
    return {
      'first_name': _blankToNull(examinee.firstName),
      'middle_name': _blankToNull(examinee.middleName),
      'last_name': _blankToNull(examinee.lastName),
      'examinee_number': _blankToNull(examinee.examineeNumber),
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

  /// A one-line, secret-safe summary of a [SocketException] for `adb logcat`:
  /// the exception runtime type, its `message`, the platform `osError`
  /// (`errorCode` + `message`), and the target `address` / `port` when the
  /// exception carries them. This is exactly what is needed on a physical
  /// device to tell apart a DNS/host-lookup failure, a refused connection,
  /// an unreachable network, and a reset — none of which produce a
  /// PostgREST error to classify.
  ///
  /// It NEVER carries a Supabase URL, an API key, a Firebase ID token, an
  /// `Authorization` header, a request body, or PII: [_redactSensitive]
  /// masks any `*.supabase.co` host and any token-shaped blob that an OS
  /// string might contain. The numeric `osError` code and the `port`
  /// (usually 443) are the diagnostic essentials and are never sensitive.
  static String describeSocketException(SocketException e) {
    final os = e.osError;
    final addr = e.address;
    return '${e.runtimeType}'
        ' message="${_redactSensitive(e.message)}"'
        ' osErrorCode=${os?.errorCode}'
        ' osErrorMessage=${os == null ? 'null' : '"${_redactSensitive(os.message)}"'}'
        ' address=${addr == null ? 'null' : '"${_redactSensitive(addr.address)}"'}'
        ' port=${e.port ?? 'null'}';
  }

  /// Masks a `<sub>.supabase.co` host and any token-shaped blob (a JWT
  /// `eyJ…`, an `sb_…` / `sbp_…` key, or a long base64url run) so a string
  /// lifted from an OS-level error can never leak the project ref or a
  /// credential. Everything else is left intact.
  static String _redactSensitive(String input) {
    return input
        .replaceAll(
          RegExp(r'[A-Za-z0-9-]+\.supabase\.co', caseSensitive: false),
          '<supabase-host>',
        )
        .replaceAll(RegExp(r'eyJ[A-Za-z0-9_=-]{10,}'), '<redacted>')
        .replaceAll(RegExp(r'\bsbp?_[A-Za-z0-9_-]{10,}'), '<redacted>')
        .replaceAll(RegExp(r'[A-Za-z0-9_-]{40,}'), '<redacted>');
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

    // Manual corrections and the optional student details have no cloud
    // columns (see ScanCloudExtensions), so they ride in `decoded`. Read the
    // row's current `decoded` first so the correction history is merged, not
    // overwritten: a push must never erase an entry another device already
    // recorded. A failed read is classified like any other Postgrest error,
    // so the job retries (or fails visibly) instead of pushing blind.
    Map<String, dynamic>? cloudDecoded;
    final readOutcome = await _guardPostgrest(() async {
      final existing = await _client
          .from('scans')
          .select('decoded')
          .eq('batch_id', batch.id)
          .eq('id', scan.id)
          .maybeSingle();
      final d = existing?['decoded'];
      if (d is Map<String, dynamic>) cloudDecoded = d;
      return const SyncOutcome.success();
    });
    if (!readOutcome.isSuccess) return readOutcome;

    final row = <String, dynamic>{
      'id': scan.id,
      'batch_id': batch.id,
      'captured_at': isoUtc(scan.capturedAt),
      'exam_code': batch.examCode,
      'decoded': ScanCloudExtensions.decodedForCloud(scan, cloudDecoded: cloudDecoded),

      // result (null as a group when ungraded)
      'raw_score': result?.rawScore,
      'total_graded': result?.totalGraded,
      'total_items': result?.totalItems,
      'score_percentage': result?.percentage,
      'result_status': result?.status,
      'scanned_at': _isoOrNull(result?.scannedAt),
      'processed_by_uid': result?.processedByUid,
      'processed_by_name': result?.processedByName,

      // examinee identity -- each of first/middle/last/examinee_number sent
      // independently (available value or null), never all-or-nothing. See
      // [scanIdentityColumns]'s doc comment for the DB constraint this
      // depends on. The tag-audit columns are added below, ONLY for a
      // tag/clear-triggered push.
      ...scanIdentityColumns(examinee),

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
      isTagged: examineeTagged(examinee),
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
        (variant != 'original' &&
            variant != 'rectified' &&
            !nameCropVariants.contains(variant))) {
      return const SyncOutcome.permanent('bad_job');
    }

    final batch = await batches.getBatchById(batchId);
    if (batch == null) return const SyncOutcome.success();
    final scan = _findScan(batch, scanId);
    if (scan == null) return const SyncOutcome.success();

    if (variant == 'original') {
      // resolveScanImage now hands back already-decrypted bytes (see
      // LocalBatchRepository's doc comment) rather than a File — the
      // upload itself is still plaintext bytes over Supabase's own
      // TLS-protected API, same as before; only the *local* copy is
      // encrypted at rest.
      final bytes = await batches.resolveScanImage(batchId, scan);
      if (bytes == null) {
        // Scan row still exists locally but its bytes are gone — not
        // recoverable, so stop retrying.
        return const SyncOutcome.permanent('local_file_missing');
      }
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

    if (nameCropVariants.contains(variant)) {
      // Optional handwritten-name crop. The local copy is the source of truth
      // (already the JPEG cropNameFields produced -- uploaded as-is, never
      // re-encoded). No local crop (an older scan, a sheet whose crop failed,
      // or one that was deleted) means there is nothing to upload: a no-op
      // success, never a fake object and never a scan-level failure. Unlike
      // the photos there is no *_uploaded flag to record.
      final cropBytes = switch (variant) {
        variantNameLast => await batches.resolveScanNameCropLast(batchId, scan),
        variantNameFirst => await batches.resolveScanNameCropFirst(batchId, scan),
        _ => await batches.resolveScanNameCropMiddle(batchId, scan),
      };
      if (cropBytes == null) return const SyncOutcome.success();
      return _guardStorage(StorageOp.write, () async {
        await _client.storage.from(storageBucket).uploadBinary(
              nameCropImageKey(batchId, scanId, variant!),
              cropBytes,
              fileOptions:
                  const FileOptions(upsert: true, contentType: 'image/jpeg'),
            );
        return const SyncOutcome.success();
      });
    }

    // variant == 'rectified'
    final bytes = await batches.resolveScanRectifiedImage(batchId, scan);
    if (bytes == null) {
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
  // F2. readCloudBatches / readCloudScans -- additive cloud retrieval reads.
  // Never called by SyncManager; used only by CloudRestoreService. Mirror
  // readAnswerKey's guard/retry shape exactly.
  // ---------------------------------------------------------------------------

  /// Parses one raw `batches` row (as returned by `.select()`) into a
  /// [CloudBatchRow].
  static CloudBatchRow parseCloudBatchRow(Map<String, dynamic> row) =>
      CloudBatchRow(
        id: row['id'] as String,
        batchCode: row['batch_code'] as String? ?? '',
        examCode: row['exam_code'] as String? ?? '',
        examTitle: row['exam_title'] as String? ?? '',
        description: row['description'] as String? ?? '',
        expectedCount: (row['expected_count'] as num?)?.toInt() ?? 0,
        status: row['status'] as String? ?? 'Draft',
        createdByUid: row['created_by_uid'] as String? ?? '',
        createdByName: row['created_by_name'] as String? ?? 'Unknown',
        createdAt: _dateOrNull(row['created_at']) ?? DateTime.now().toUtc(),
        updatedAt: _dateOrNull(row['updated_at']) ?? DateTime.now().toUtc(),
      );

  /// Parses one raw `scans` row (as returned by `.select()`) into a
  /// [CloudScanRow]. Deliberately never reads `score_percentage` (see
  /// [CloudScanRow]'s doc comment).
  static CloudScanRow parseCloudScanRow(Map<String, dynamic> row) =>
      CloudScanRow(
        id: row['id'] as String,
        batchId: row['batch_id'] as String? ?? '',
        examCode: row['exam_code'] as String? ?? '',
        capturedAt: _dateOrNull(row['captured_at']) ?? DateTime.now().toUtc(),
        decoded: row['decoded'] is Map
            ? Map<String, dynamic>.from(row['decoded'] as Map)
            : const {},
        rawScore: (row['raw_score'] as num?)?.toInt(),
        totalGraded: (row['total_graded'] as num?)?.toInt(),
        totalItems: (row['total_items'] as num?)?.toInt(),
        resultStatus: row['result_status'] as String?,
        scannedAt: _dateOrNull(row['scanned_at']),
        processedByUid: row['processed_by_uid'] as String?,
        processedByName: row['processed_by_name'] as String?,
        firstName: row['first_name'] as String?,
        lastName: row['last_name'] as String?,
        middleName: row['middle_name'] as String?,
        examineeNumber: row['examinee_number'] as String?,
        examineeId: row['examinee_id'] as String?,
        imagePath: row['image_path'] as String?,
        rectifiedImagePath: row['rectified_image_path'] as String?,
        imageUploaded: row['image_uploaded'] == true,
        rectifiedImageUploaded: row['rectified_image_uploaded'] == true,
        attemptNo: (row['attempt_no'] as num?)?.toInt() ?? 1,
        attemptStatus: row['attempt_status'] as String? ?? 'active',
        archivedAt: _dateOrNull(row['archived_at']),
        archivedByUid: row['archived_by_uid'] as String?,
        archivedByName: row['archived_by_name'] as String?,
        archiveReason: row['archive_reason'] as String?,
      );

  /// Read-only, metadata-only fetch of every cloud `batches` row visible
  /// under the current RLS policy. Mirrors [readAnswerKey]'s single
  /// token-refresh-then-retry guard. Never mutates [syncState] or the
  /// job queue -- this is a pure read.
  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    var refreshed = false;
    while (true) {
      try {
        final rows = await _client.from('batches').select(
              'id, batch_code, exam_code, exam_title, description, '
              'expected_count, status, created_by_uid, created_by_name, '
              'created_at, updated_at',
            );
        return CloudBatchesRead.found(
          rows.map((r) => parseCloudBatchRow(r)).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudBatchesRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudBatchesRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudBatchesRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudBatchesRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Read-only fetch of the cloud `scans` rows for [batchId]. Mirrors
  /// [readAnswerKey]'s guard. Never mutates [syncState] or the job queue.
  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    var refreshed = false;
    while (true) {
      try {
        final rows = await _client
            .from('scans')
            .select(
              'id, batch_id, exam_code, captured_at, decoded, raw_score, '
              'total_graded, total_items, result_status, scanned_at, '
              'processed_by_uid, processed_by_name, first_name, last_name, '
              'middle_name, examinee_number, examinee_id, image_path, '
              'image_uploaded, rectified_image_path, rectified_image_uploaded, '
              'attempt_no, attempt_status, archived_at, archived_by_uid, '
              'archived_by_name, archive_reason',
            )
            .eq('batch_id', batchId);
        return CloudScansRead.found(
          rows.map((r) => parseCloudScanRow(r)).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudScansRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudScansRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudScansRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudScansRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // F2b. Examinee Records -- additive cloud reads/writes for the canonical
  // `examinees` table and `scans.examinee_id`. Never called by SyncManager;
  // used only by GuidanceWebExamineeRecordsService. Mirrors readCloudBatches/
  // readCloudScans's exact guard/retry shape.
  // ---------------------------------------------------------------------------

  static const List<String> _examineeColumns = [
    'id',
    'temporary_examinee_id',
    'official_student_id',
    'first_name',
    'middle_name',
    'last_name',
    'birth_date',
    'last_attended_school',
    'status',
    'archived_at',
    'archived_by_uid',
    'created_at',
    'created_by_uid',
    'updated_at',
    'updated_by_uid',
  ];

  /// Parses one raw `examinees` row (as returned by `.select()`) into a
  /// [CloudExamineeRow].
  static CloudExamineeRow parseCloudExamineeRow(Map<String, dynamic> row) =>
      CloudExamineeRow(
        id: row['id'] as String,
        temporaryExamineeId: row['temporary_examinee_id'] as String? ?? '',
        officialStudentId: row['official_student_id'] as String?,
        firstName: row['first_name'] as String? ?? '',
        middleName: row['middle_name'] as String?,
        lastName: row['last_name'] as String? ?? '',
        birthDate: _dateOrNull(row['birth_date']),
        lastAttendedSchool: row['last_attended_school'] as String?,
        status: row['status'] as String? ?? 'active',
        archivedAt: _dateOrNull(row['archived_at']),
        archivedByUid: row['archived_by_uid'] as String?,
        createdAt: _dateOrNull(row['created_at']) ?? DateTime.now().toUtc(),
        createdByUid: row['created_by_uid'] as String? ?? '',
        updatedAt: _dateOrNull(row['updated_at']) ?? DateTime.now().toUtc(),
        updatedByUid: row['updated_by_uid'] as String? ?? '',
      );

  /// Read-only fetch of every cloud `examinees` row visible under RLS.
  @override
  Future<CloudExamineesRead> readCloudExaminees() async {
    var refreshed = false;
    while (true) {
      try {
        final rows = await _client
            .from('examinees')
            .select(_examineeColumns.join(', '));
        return CloudExamineesRead.found(
          rows.map((r) => parseCloudExamineeRow(r)).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudExamineesRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudExamineesRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudExamineesRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudExamineesRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Every cloud `scans` row linked to [examineeId], across ALL batches.
  /// Mirrors [readCloudScans] exactly, filtered by `examinee_id` instead of
  /// `batch_id`.
  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) async {
    var refreshed = false;
    while (true) {
      try {
        final rows = await _client
            .from('scans')
            .select(
              'id, batch_id, exam_code, captured_at, decoded, raw_score, '
              'total_graded, total_items, result_status, scanned_at, '
              'processed_by_uid, processed_by_name, first_name, last_name, '
              'middle_name, examinee_number, image_path, image_uploaded, '
              'rectified_image_path, rectified_image_uploaded, attempt_no, '
              'attempt_status, archived_at, archived_by_uid, archived_by_name, '
              'archive_reason',
            )
            .eq('examinee_id', examineeId);
        return CloudScansRead.found(
          rows.map((r) => parseCloudScanRow(r)).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudScansRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudScansRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudScansRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudScansRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Every cloud `scans` row with `examinee_id IS NULL`, across ALL
  /// batches -- the "Unlinked Scans" queue. Mirrors [readCloudScans]/
  /// [readCloudScansForExaminee] exactly, filtered by `examinee_id is null`
  /// instead. Read-only, does no matching of its own.
  @override
  Future<CloudScansRead> readUnlinkedScans() async {
    var refreshed = false;
    while (true) {
      try {
        final rows = await _client
            .from('scans')
            .select(
              'id, batch_id, exam_code, captured_at, decoded, raw_score, '
              'total_graded, total_items, result_status, scanned_at, '
              'processed_by_uid, processed_by_name, first_name, last_name, '
              'middle_name, examinee_number, image_path, image_uploaded, '
              'rectified_image_path, rectified_image_uploaded, attempt_no, '
              'attempt_status, archived_at, archived_by_uid, archived_by_name, '
              'archive_reason',
            )
            .isFilter('examinee_id', null);
        return CloudScansRead.found(
          rows.map((r) => parseCloudScanRow(r)).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudScansRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudScansRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudScansRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudScansRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Atomically creates a new `examinees` row and links [scanId] (in
  /// [batchId]) to it via the `create_examinee_from_scan` Postgres function
  /// (see `0004_create_examinee_from_scan_function.sql`) — a single
  /// database transaction, never two separate client calls. There is no
  /// "create a blank examinee" method anywhere on this client: every
  /// examinee must originate from a specific scan.
  ///
  /// `temporary_examinee_id` is never sent -- the column has a PostgreSQL
  /// sequence-backed `DEFAULT` (see `0001_create_examinees.sql`), so the
  /// database assigns it atomically on insert; two concurrent creates can
  /// never race to the same value the way a client-generated
  /// timestamp+counter could, and it is never copied from the scan's own
  /// `examinee_number`. No method on this client can ever change it
  /// afterward, and the database enforces that independently too (see
  /// `0001_create_examinees.sql`'s trigger).
  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    var refreshed = false;
    while (true) {
      try {
        final result = await _client.rpc('create_examinee_from_scan', params: {
          'p_batch_id': batchId,
          'p_scan_id': scanId,
          'p_first_name': firstName,
          'p_middle_name': middleName ?? '',
          'p_last_name': lastName,
        });
        final row = result is List
            ? Map<String, dynamic>.from(result.first as Map)
            : Map<String, dynamic>.from(result as Map);
        return CloudExamineeWrite.success(parseCloudExamineeRow(row));
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudExamineeWrite.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudExamineeWrite.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudExamineeWrite.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudExamineeWrite.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Updates only the editable canonical fields — name-only, for correcting
  /// an OCR misread. Deliberately has no `temporaryExamineeId`/`status`/
  /// `archived*`/`birthDate`/`lastAttendedSchool`/`officialStudentId`
  /// parameter -- this method cannot touch any of them even if a caller
  /// wanted it to (those columns are simply absent from the `update()` map
  /// below, so Postgres leaves their existing values untouched). Returns
  /// the row as it now stands in the database, so the caller never has to
  /// reconstruct `updated_at`/`updated_by_uid` itself.
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) async {
    var refreshed = false;
    while (true) {
      try {
        final updated = await _client.from('examinees').update({
          'first_name': firstName,
          'middle_name': middleName,
          'last_name': lastName,
          'updated_at': isoUtc(DateTime.now()),
          'updated_by_uid': identity.uid ?? '',
        }).eq('id', id).select(_examineeColumns.join(', ')).single();
        return CloudExamineeWrite.success(parseCloudExamineeRow(updated));
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudExamineeWrite.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudExamineeWrite.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudExamineeWrite.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudExamineeWrite.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Archives ([archived] = true) or restores ([archived] = false) an
  /// examinee -- a `status` flip only. Never deletes the row, never touches
  /// any linked scan/result. Returns the row as it now stands in the
  /// database.
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) async {
    var refreshed = false;
    while (true) {
      try {
        final now = isoUtc(DateTime.now());
        final updated = await _client.from('examinees').update({
          'status': archived ? 'archived' : 'active',
          'archived_at': archived ? now : null,
          'archived_by_uid': archived ? (identity.uid ?? '') : null,
          'updated_at': now,
          'updated_by_uid': identity.uid ?? '',
        }).eq('id', id).select(_examineeColumns.join(', ')).single();
        return CloudExamineeWrite.success(parseCloudExamineeRow(updated));
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudExamineeWrite.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudExamineeWrite.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudExamineeWrite.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudExamineeWrite.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Links one scan to [examineeId] -- ONLY if the scan is still unlinked at
  /// the moment of the update (`examinee_id IS NULL`). Conceptually:
  /// `UPDATE scans SET examinee_id = ? WHERE batch_id = ? AND id = ? AND
  /// examinee_id IS NULL`. `.select('id')` reads back the rows actually
  /// changed and exactly one is required, so a scan that another session
  /// already linked (or one that is missing / hidden by RLS) is never
  /// overwritten and never reported as success -- it yields
  /// [SyncOutcome.conflict] `scan_already_linked`. Only `examinee_id` is
  /// written. No matching/suggestion logic here -- the caller has already
  /// confirmed this exact link. Clearing a link is [unlinkScanFromExaminee].
  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) {
    return _guardPostgrest(() async {
      final changed = await _client
          .from('scans')
          .update({'examinee_id': examineeId})
          .eq('batch_id', batchId)
          .eq('id', scanId)
          .isFilter('examinee_id', null)
          .select('id');
      if (changed.length != 1) {
        return const SyncOutcome.conflict('scan_already_linked');
      }
      return const SyncOutcome.success();
    });
  }

  /// Removes ONLY the scan/examinee link: `examinee_id = NULL`, guarded by
  /// `batch_id` + `id` + the CURRENT `examinee_id`. `.select('id')` returns
  /// the rows actually changed so zero rows can never masquerade as success
  /// (an update matching nothing is not an error to PostgREST). Never
  /// deletes anything and never sends any column but `examinee_id`.
  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) {
    return _guardPostgrest(() async {
      final changed = await _client
          .from('scans')
          .update({'examinee_id': null})
          .eq('batch_id', batchId)
          .eq('id', scanId)
          .eq('examinee_id', examineeId)
          .select('id');
      if (changed.length != 1) {
        return const SyncOutcome.conflict('scan_not_linked_to_examinee');
      }
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // Applicant Retake Management (`exam_retake_requests`, see
  // retake_client.dart). Every write below calls a SECURITY DEFINER database
  // function -- never a plain insert/update on `exam_retake_requests` or the
  // `scans` attempt columns (both are blocked for direct client mutation).
  // The actor's uid/name are resolved from [identity], exactly like
  // [archiveBatch] resolves the Web Archive's actor -- never a caller-
  // supplied parameter, so a request/review/archive can never be attributed
  // to anyone other than the signed-in Guidance Council user.
  // ---------------------------------------------------------------------------

  static const List<String> _retakeRequestColumns = [
    'id',
    'examinee_id',
    'exam_code',
    'previous_scan_batch_id',
    'previous_scan_id',
    'reason',
    'status',
    'requested_by_uid',
    'requested_by_name',
    'requested_at',
    'reviewed_by_uid',
    'reviewed_by_name',
    'reviewed_at',
    'review_note',
    'eligible_on',
    'created_at',
    'updated_at',
  ];

  /// Parses one raw `exam_retake_requests` row (as returned by
  /// `.select()`) into a [CloudRetakeRequestRow].
  static CloudRetakeRequestRow parseCloudRetakeRequestRow(Map<String, dynamic> row) =>
      CloudRetakeRequestRow(
        id: row['id'] as String,
        examineeId: row['examinee_id'] as String? ?? '',
        examCode: row['exam_code'] as String? ?? '',
        previousScanBatchId: row['previous_scan_batch_id'] as String?,
        previousScanId: row['previous_scan_id'] as String?,
        reason: row['reason'] as String? ?? '',
        status: row['status'] as String? ?? 'PENDING',
        requestedByUid: row['requested_by_uid'] as String?,
        requestedByName: row['requested_by_name'] as String?,
        requestedAt: _dateOrNull(row['requested_at']) ?? DateTime.now().toUtc(),
        reviewedByUid: row['reviewed_by_uid'] as String?,
        reviewedByName: row['reviewed_by_name'] as String?,
        reviewedAt: _dateOrNull(row['reviewed_at']),
        reviewNote: row['review_note'] as String?,
        eligibleOn: _dateOrNull(row['eligible_on']),
        createdAt: _dateOrNull(row['created_at']) ?? DateTime.now().toUtc(),
        updatedAt: _dateOrNull(row['updated_at']) ?? DateTime.now().toUtc(),
      );

  /// Read-only fetch of every `exam_retake_requests` row for
  /// [examineeId]/[examCode], newest first -- Guidance Council RLS grants
  /// SELECT on this table directly (only INSERT/UPDATE are function-only).
  @override
  Future<CloudRetakeRequestsRead> readRetakeRequests({
    required String examineeId,
    required String examCode,
  }) async {
    var refreshed = false;
    while (true) {
      try {
        final rows = await _client
            .from('exam_retake_requests')
            .select(_retakeRequestColumns.join(', '))
            .eq('examinee_id', examineeId)
            .eq('exam_code', examCode)
            .order('created_at', ascending: false);
        return CloudRetakeRequestsRead.found(
          rows.map((r) => parseCloudRetakeRequestRow(r)).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudRetakeRequestsRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudRetakeRequestsRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudRetakeRequestsRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudRetakeRequestsRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Creates a PENDING retake request via the `create_exam_retake_request`
  /// RPC. The database is the sole judge of eligibility (attempt count, an
  /// already-open request, ...) -- this never pre-validates that itself, and
  /// never inserts into `exam_retake_requests` directly.
  @override
  Future<SyncOutcome> createRetakeRequest({
    required String examineeId,
    required String examCode,
    required String reason,
  }) {
    final uid = identity.uid;
    if (uid == null || uid.isEmpty) {
      return Future.value(const SyncOutcome.permanent('no_uid'));
    }
    final name = identity.displayName?.trim();
    return _guardPostgrest(() async {
      await _client.rpc('create_exam_retake_request', params: {
        'p_examinee_id': examineeId,
        'p_exam_code': examCode,
        'p_reason': reason,
        'p_requested_by_uid': uid,
        'p_requested_by_name': (name == null || name.isEmpty) ? null : name,
      });
      return const SyncOutcome.success();
    });
  }

  /// Approves or rejects [requestId] via the `review_exam_retake_request`
  /// RPC (`p_action` is the literal 'APPROVE'/'REJECT' that function
  /// accepts). Never updates `exam_retake_requests.status` directly -- the
  /// database blocks that independently.
  @override
  Future<SyncOutcome> reviewRetakeRequest({
    required String requestId,
    required bool approve,
    String? reviewNote,
  }) {
    final uid = identity.uid;
    if (uid == null || uid.isEmpty) {
      return Future.value(const SyncOutcome.permanent('no_uid'));
    }
    final name = identity.displayName?.trim();
    return _guardPostgrest(() async {
      await _client.rpc('review_exam_retake_request', params: {
        'p_request_id': requestId,
        'p_action': approve ? 'APPROVE' : 'REJECT',
        'p_reviewer_uid': uid,
        'p_reviewer_name': (name == null || name.isEmpty) ? null : name,
        'p_review_note': reviewNote,
      });
      return const SyncOutcome.success();
    });
  }

  /// Archives the previous attempt behind an APPROVED [requestId] via the
  /// `archive_approved_retake_attempt` RPC. Never deletes the scan, its
  /// batch, or its examinee link, and never updates `scans.attempt_status`
  /// directly -- the database blocks that independently.
  @override
  Future<SyncOutcome> archiveRetakeAttempt({
    required String requestId,
    required String archiveReason,
  }) {
    final uid = identity.uid;
    if (uid == null || uid.isEmpty) {
      return Future.value(const SyncOutcome.permanent('no_uid'));
    }
    final name = identity.displayName?.trim();
    return _guardPostgrest(() async {
      await _client.rpc('archive_approved_retake_attempt', params: {
        'p_request_id': requestId,
        'p_archived_by_uid': uid,
        'p_archived_by_name': (name == null || name.isEmpty) ? null : name,
        'p_archive_reason': archiveReason,
      });
      return const SyncOutcome.success();
    });
  }

  // ---------------------------------------------------------------------------
  // Guidance Council WEB Archive (`batch_archives`, see
  // 0007_create_batch_archives.sql). Independent of the mobile app: nothing
  // here reads or writes `batches`, and there is no restore/unarchive.
  // ---------------------------------------------------------------------------

  /// Parses one raw `batch_archives` row into a [CloudBatchArchiveRow].
  static CloudBatchArchiveRow parseCloudBatchArchiveRow(Map<String, dynamic> row) =>
      CloudBatchArchiveRow(
        batchId: row['batch_id'] as String,
        archivedAt: _dateOrNull(row['archived_at']) ?? DateTime.now().toUtc(),
        archivedByUid: row['archived_by_uid'] as String? ?? '',
        archivedByName: row['archived_by_name'] as String?,
        reason: row['reason'] as String?,
      );

  /// Read-only fetch of every `batch_archives` marker visible under RLS.
  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async {
    var refreshed = false;
    while (true) {
      try {
        final rows = await _client.from('batch_archives').select(
              'batch_id, archived_at, archived_by_uid, archived_by_name, reason',
            );
        return CloudBatchArchivesRead.found(
          rows.map((r) => parseCloudBatchArchiveRow(r)).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudBatchArchivesRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudBatchArchivesRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudBatchArchivesRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudBatchArchivesRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Creates the archive marker: a single INSERT into `batch_archives`
  /// (`batch_id`, the signed-in actor's uid/name, optional reason;
  /// `archived_at` is the column default). It never writes `batches` or
  /// `scans`. A batch that already has a marker fails with a permanent
  /// `23505`; the database's insert policy also rejects a batch that is not
  /// Completed (42501). No update/delete method exists — there is no restore.
  @override
  Future<SyncOutcome> archiveBatch({
    required String batchId,
    String? reason,
  }) {
    final uid = identity.uid;
    if (uid == null || uid.isEmpty) {
      return Future.value(const SyncOutcome.permanent('no_uid'));
    }
    final trimmedReason = reason?.trim();
    final name = identity.displayName?.trim();
    return _guardPostgrest(() async {
      await _client.from('batch_archives').insert({
        'batch_id': batchId,
        'archived_by_uid': uid,
        'archived_by_name': (name == null || name.isEmpty) ? null : name,
        'reason': (trimmedReason == null || trimmedReason.isEmpty) ? null : trimmedReason,
      });
      return const SyncOutcome.success();
    });
  }

  /// Exact scan count per batch (one small counted request per batch id —
  /// never a row dump, so PostgREST's row cap can't truncate a count).
  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) async {
    var refreshed = false;
    while (true) {
      try {
        final counts = <String, int>{};
        for (final id in batchIds) {
          final response = await _client
              .from('scans')
              .select('id')
              .eq('batch_id', id)
              .limit(1)
              .count(CountOption.exact);
          counts[id] = response.count;
        }
        return CloudScanCountsRead.found(counts);
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudScanCountsRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudScanCountsRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudScanCountsRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudScanCountsRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // F3. downloadScanImage -- additive cloud image retrieval. Never called by
  // SyncManager; used only by CloudRestoreService.restoreImageIfMissing,
  // which is solely responsible for encrypting the returned bytes before
  // any disk write -- this method never touches local storage.
  // ---------------------------------------------------------------------------

  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) async {
    final key = rectified
        ? rectifiedImageKey(batchId, scanId)
        : originalImageKey(batchId, scanId);
    var refreshed = false;
    while (true) {
      try {
        final bytes = await _client.storage.from(storageBucket).download(key);
        return CloudImageRead.found(bytes);
      } on StorageException catch (e) {
        final status = _sanitizeCode(e.statusCode);
        if (status == '404') return const CloudImageRead.absent();
        if ((status == '401' || status == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        _logGuard('storage error status=$status op=read (${e.runtimeType})');
        return CloudImageRead.failed(classifyStorageStatus(status, StorageOp.read));
      } on TimeoutException {
        return const CloudImageRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudImageRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudImageRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Downloads one handwritten-name crop image from the existing private
  /// `scanned-sheets` bucket using the same authenticated Storage contract as
  /// [downloadScanImage]. Missing crop objects are a normal absent state, not a
  /// database error.
  @override
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) async {
    if (!nameCropVariants.contains(variant)) {
      return const CloudImageRead.failed(SyncOutcome.permanent('bad_variant'));
    }

    final key = nameCropImageKey(batchId, scanId, variant);
    var refreshed = false;
    while (true) {
      try {
        final bytes = await _client.storage.from(storageBucket).download(key);
        return CloudImageRead.found(bytes);
      } on StorageException catch (e) {
        final status = _sanitizeCode(e.statusCode);
        if (status == '404') return const CloudImageRead.absent();
        if ((status == '401' || status == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        _logGuard(
          'storage error status=$status op=read crop (${e.runtimeType})',
        );
        return CloudImageRead.failed(
          classifyStorageStatus(status, StorageOp.read),
        );
      } on TimeoutException {
        return const CloudImageRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudImageRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudImageRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // G0. deleteScan
  // ---------------------------------------------------------------------------

  /// Deletes one `scans` row, then its original and rectified Storage
  /// objects. Row first: a failure after it leaves only unreferenced objects,
  /// and the job retries the (idempotent) whole thing. Zero rows / missing
  /// objects are success.
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) async {
    final rowOutcome = await _guardPostgrest(() async {
      await _client.from('scans').delete().eq('batch_id', batchId).eq('id', scanId);
      return const SyncOutcome.success();
    });
    if (!rowOutcome.isSuccess) return rowOutcome;
    final storageOutcome = await _guardStorage(StorageOp.delete, () async {
      await _client.storage.from(storageBucket).remove([
        originalImageKey(batchId, scanId),
        rectifiedImageKey(batchId, scanId),
      ]);
      return const SyncOutcome.success();
    });
    if (!storageOutcome.isSuccess) return storageOutcome;
    syncState.forget(SyncState.scanKey(batchId, scanId));
    return const SyncOutcome.success();
  }

  // ---------------------------------------------------------------------------
  // G0a. deleteUnlinkedScan (Guidance Council Web Console only -- see
  // ScanDeleteClient. Deliberately separate from deleteScan above, which is
  // only ever dispatched by SyncManager for the mobile Batch Archive.)
  // ---------------------------------------------------------------------------

  /// See [ScanDeleteClient.deleteUnlinkedScan]. The DELETE itself carries
  /// `.isFilter('examinee_id', null)` AND `.not('attempt_status', 'ilike',
  /// 'ARCHIVED')` so the database -- not the caller's already-displayed
  /// snapshot, and not a prior read -- is what decides at the moment of the
  /// write; `.select('id')` reports how many rows actually matched, so a
  /// zero-row no-op can never masquerade as success (mirrors
  /// [unlinkScanFromExaminee]'s same guard pattern). `ilike` without a `%`
  /// wildcard is an exact, case-insensitive match, so `not(... 'ilike',
  /// 'ARCHIVED')` excludes exactly the rows [CloudScanRow.isArchivedAttempt]
  /// would call archived -- the same rule, enforced one layer down, not a
  /// new one. A scan still referenced by `exam_retake_requests.previous_scan_id`
  /// (`ON DELETE RESTRICT`) surfaces here as a `23503` from Postgres, already
  /// handled generically by [classifyPostgrestCode] -- no special-casing
  /// needed. Row first, then Storage (original, rectified, and the three
  /// name-crop variants) -- same ordering/reasoning as [deleteScan].
  @override
  Future<SyncOutcome> deleteUnlinkedScan({
    required String batchId,
    required String scanId,
  }) async {
    final rowOutcome = await _guardPostgrest(() async {
      final deleted = await _client
          .from('scans')
          .delete()
          .eq('batch_id', batchId)
          .eq('id', scanId)
          .isFilter('examinee_id', null)
          .not('attempt_status', 'ilike', 'ARCHIVED')
          .select('id');
      if (deleted.length != 1) {
        return const SyncOutcome.conflict('scan_not_unlinked');
      }
      return const SyncOutcome.success();
    });
    if (!rowOutcome.isSuccess) return rowOutcome;
    final storageOutcome = await _guardStorage(StorageOp.delete, () async {
      await _client.storage.from(storageBucket).remove([
        originalImageKey(batchId, scanId),
        rectifiedImageKey(batchId, scanId),
        nameCropImageKey(batchId, scanId, variantNameLast),
        nameCropImageKey(batchId, scanId, variantNameFirst),
        nameCropImageKey(batchId, scanId, variantNameMiddle),
      ]);
      return const SyncOutcome.success();
    });
    if (!storageOutcome.isSuccess) {
      // The row is already permanently gone -- never return the raw Storage
      // failure verbatim here, or a caller further up (which no longer has
      // any way to know the row succeeded) would report this exactly like
      // a full failure. scanDeletedStorageIncompleteCode is the one signal
      // that lets the caller tell the two apart.
      return storageOutcome.isTransient
          ? const SyncOutcome.transient(scanDeletedStorageIncompleteCode)
          : const SyncOutcome.permanent(scanDeletedStorageIncompleteCode);
    }
    syncState.forget(SyncState.scanKey(batchId, scanId));
    return const SyncOutcome.success();
  }

  /// See [ScanDeleteClient.softDeleteUnlinkedScan]. Calls the
  /// `soft_delete_unlinked_scan` RPC exactly as declared in
  /// 0009_create_unlinked_scan_soft_delete.sql with its five `p_`-prefixed
  /// parameters -- every precondition (Guidance Council caller,
  /// `p_deleted_by_uid` matching the authenticated JWT `sub`, the scan
  /// existing/unlinked/not-archived/not-already-soft-deleted, a non-blank
  /// reason) is enforced by the RPC itself, never duplicated here. The
  /// RPC's own return row (batch_id, scan_id, deleted_at, retention_until)
  /// is not needed by this method's signature and is not parsed. Never
  /// touches Storage.
  @override
  Future<SyncOutcome> softDeleteUnlinkedScan({
    required String batchId,
    required String scanId,
    required String deletedByUid,
    String? deletedByName,
    required String deletionReason,
  }) {
    return _guardPostgrest(() async {
      await _client.rpc('soft_delete_unlinked_scan', params: {
        'p_batch_id': batchId,
        'p_scan_id': scanId,
        'p_deleted_by_uid': deletedByUid,
        'p_deleted_by_name': deletedByName,
        'p_deletion_reason': deletionReason,
      });
      return const SyncOutcome.success();
    });
  }

  /// Parses a timestamp field that the System Admin restore-management RPCs
  /// (`list_soft_deleted_unlinked_scans_for_admin`,
  /// `list_scan_restore_requests_for_admin`) guarantee is NOT NULL --
  /// unlike [_dateOrNull] (used throughout this file for genuinely
  /// nullable/optional timestamps), this NEVER substitutes a fabricated
  /// value such as `DateTime.now()` for a null, missing, empty, or
  /// unparseable value. A response that fails this check is almost
  /// certainly malformed in a way a System Admin reviewing a scan for
  /// restoration must not be shown as if it were real data -- so this
  /// throws instead, which the surrounding `try`/`catch` in
  /// [listDeletedScansForAdmin]/[listRestoreRequestsForAdmin] converts into
  /// a sanitized failed read (`classifyUnexpectedError`), never a crash and
  /// never a silently-invented date.
  static DateTime _requireAdminDate(Object? raw, String fieldName) {
    final parsed = _dateOrNull(raw);
    if (parsed == null) {
      throw FormatException(
        'Admin restore-management response is missing a valid "$fieldName" timestamp',
      );
    }
    return parsed;
  }

  /// Parses one raw `list_soft_deleted_unlinked_scans_for_admin` row into a
  /// [CloudAdminSoftDeletedScanRow].
  static CloudAdminSoftDeletedScanRow parseCloudAdminSoftDeletedScanRow(
    Map<String, dynamic> row,
  ) =>
      CloudAdminSoftDeletedScanRow(
        batchId: row['batch_id'] as String,
        scanId: row['scan_id'] as String,
        examCode: row['exam_code'] as String,
        deletedAt: _requireAdminDate(row['deleted_at'], 'deleted_at'),
        retentionUntil: _requireAdminDate(row['retention_until'], 'retention_until'),
        deletionReason: row['deletion_reason'] as String?,
        deletedByName: row['deleted_by_name'] as String?,
      );

  /// See [AdminScanRestoreClient.listDeletedScansForAdmin]. Calls the
  /// `list_soft_deleted_unlinked_scans_for_admin` RPC exactly as declared in
  /// 0009_create_unlinked_scan_soft_delete.sql -- no parameters,
  /// System-Admin-only (enforced by the RPC itself). Never calls the
  /// Guidance-Council-only `list_retained_soft_deleted_scans_for_guidance`
  /// (0011) -- a separate function, never referenced here.
  @override
  Future<CloudAdminSoftDeletedScansRead> listDeletedScansForAdmin() async {
    var refreshed = false;
    while (true) {
      try {
        final result = await _client.rpc('list_soft_deleted_unlinked_scans_for_admin');
        final rows = (result as List).map((r) => Map<String, dynamic>.from(r as Map));
        return CloudAdminSoftDeletedScansRead.found(
          rows.map(parseCloudAdminSoftDeletedScanRow).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudAdminSoftDeletedScansRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudAdminSoftDeletedScansRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudAdminSoftDeletedScansRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudAdminSoftDeletedScansRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// Parses one raw `list_scan_restore_requests_for_admin` row into a
  /// [CloudAdminRestoreRequestRow].
  static CloudAdminRestoreRequestRow parseCloudAdminRestoreRequestRow(
    Map<String, dynamic> row,
  ) =>
      CloudAdminRestoreRequestRow(
        requestId: row['request_id'] as String,
        batchId: row['batch_id'] as String,
        scanId: row['scan_id'] as String,
        examCode: row['exam_code'] as String,
        status: row['status'] as String,
        reason: row['reason'] as String,
        requestedByName: row['requested_by_name'] as String?,
        requestedAt: _requireAdminDate(row['requested_at'], 'requested_at'),
        reviewedByName: row['reviewed_by_name'] as String?,
        reviewedAt: _dateOrNull(row['reviewed_at']),
        reviewNote: row['review_note'] as String?,
      );

  /// See [AdminScanRestoreClient.listRestoreRequestsForAdmin]. Calls the
  /// `list_scan_restore_requests_for_admin` RPC exactly as declared in
  /// 0009_create_unlinked_scan_soft_delete.sql -- no parameters,
  /// System-Admin-only (enforced by the RPC itself). Never queries
  /// `scan_restore_requests` directly -- direct table access to it remains
  /// revoked for every role (0009), unchanged by this method.
  @override
  Future<CloudAdminRestoreRequestsRead> listRestoreRequestsForAdmin() async {
    var refreshed = false;
    while (true) {
      try {
        final result = await _client.rpc('list_scan_restore_requests_for_admin');
        final rows = (result as List).map((r) => Map<String, dynamic>.from(r as Map));
        return CloudAdminRestoreRequestsRead.found(
          rows.map(parseCloudAdminRestoreRequestRow).toList(),
        );
      } on PostgrestException catch (e) {
        final code = _sanitizeCode(e.code);
        if ((code == '401' || code == 'PGRST301') && !refreshed) {
          refreshed = true;
          if (await _safeRefresh()) continue;
        }
        return CloudAdminRestoreRequestsRead.failed(classifyPostgrestCode(code));
      } on TimeoutException {
        return const CloudAdminRestoreRequestsRead.failed(SyncOutcome.transient('network'));
      } on SocketException {
        return const CloudAdminRestoreRequestsRead.failed(SyncOutcome.transient('network'));
      } catch (e) {
        _logUnclassified(e);
        return CloudAdminRestoreRequestsRead.failed(classifyUnexpectedError(e));
      }
    }
  }

  /// See [AdminScanRestoreClient.reviewRestoreRequest]. Calls the EXISTING
  /// `review_scan_restore_request` RPC from
  /// 0009_create_unlinked_scan_soft_delete.sql with its five `p_`-prefixed
  /// parameters -- every precondition (System Admin caller,
  /// `p_reviewer_uid` matching the authenticated JWT `sub`, the request
  /// existing/still-PENDING, `p_action` being APPROVE/REJECT) is enforced by
  /// the RPC itself, never duplicated here. The RPC's own return row
  /// (request_id, status) is not needed by this method's signature and is
  /// not parsed -- the caller re-reads [listRestoreRequestsForAdmin]
  /// afterward, the same "re-read the truth from the database" convention
  /// [RetakeClient]'s write methods already use. This is explicitly NOT
  /// restoration -- see [restoreApprovedScan].
  @override
  Future<SyncOutcome> reviewRestoreRequest({
    required String requestId,
    required bool approve,
    required String reviewerUid,
    String? reviewerName,
    String? reviewNote,
  }) {
    return _guardPostgrest(() async {
      await _client.rpc('review_scan_restore_request', params: {
        'p_request_id': requestId,
        'p_action': approve ? 'APPROVE' : 'REJECT',
        'p_reviewer_uid': reviewerUid,
        'p_reviewer_name': reviewerName,
        'p_review_note': reviewNote,
      });
      return const SyncOutcome.success();
    });
  }

  /// See [AdminScanRestoreClient.restoreApprovedScan]. Calls the EXISTING
  /// `restore_soft_deleted_scan` RPC from
  /// 0009_create_unlinked_scan_soft_delete.sql with its three
  /// `p_`-prefixed parameters -- every precondition (System Admin caller,
  /// `p_reviewer_uid` matching the authenticated JWT `sub`, the request
  /// existing/still-APPROVED, the scan still within its retention window)
  /// is enforced by the RPC itself, never duplicated here. Never touches
  /// Storage -- the RPC itself only clears `scans`' soft-delete columns and
  /// flips the request to RESTORED.
  @override
  Future<SyncOutcome> restoreApprovedScan({
    required String requestId,
    required String reviewerUid,
    String? reviewerName,
  }) {
    return _guardPostgrest(() async {
      await _client.rpc('restore_soft_deleted_scan', params: {
        'p_request_id': requestId,
        'p_reviewer_uid': reviewerUid,
        'p_reviewer_name': reviewerName,
      });
      return const SyncOutcome.success();
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
        _logGuard('postgrest error code=$code (${e.runtimeType})');
        return classifyPostgrestCode(code);
      } on TimeoutException {
        _logGuard('postgrest transport error (TimeoutException)');
        return const SyncOutcome.transient('network');
      } on SocketException catch (e) {
        _logGuard('postgrest transport error: ${describeSocketException(e)}');
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
        _logGuard('storage error status=$status op=${op.name} (${e.runtimeType})');
        return classifyStorageStatus(status, op);
      } on TimeoutException {
        _logGuard('storage transport error op=${op.name} (TimeoutException)');
        return const SyncOutcome.transient('network');
      } on SocketException {
        _logGuard('storage transport error op=${op.name} (SocketException)');
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

  /// One-line trace of a caught + classified Supabase failure. Carries only
  /// the sanitized status/error code, the Storage op, and the exception
  /// runtimeType — never `e.message` (which can hold a row snapshot or
  /// hint), a token, a key, or a URL. Reaches `adb logcat` in release.
  void _logGuard(String detail) {
    // ignore: avoid_print
    print('SupabaseSyncClient: $detail');
  }
}
