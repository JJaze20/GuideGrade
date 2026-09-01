/// The result of attempting one cloud sync operation.
///
/// A [SyncOutcome] carries **sanitized short codes only** — never a raw
/// exception message, a JWT / Firebase token / credential / Supabase key, a
/// row snapshot, or examinee PII. The sync manager persists [code] verbatim
/// into `SyncJob.lastErrorCode`, so anything placed here is durable and
/// potentially user-visible.
enum SyncOutcomeKind {
  /// The operation applied, or there was nothing to do (idempotent no-op).
  success,

  /// A temporary failure (network, timeout, 429, 5xx, connection reset).
  /// The job should be retried with backoff.
  transient,

  /// A non-retryable failure (payload validation, RLS denial, bad type).
  /// The job should stop retrying until a fresh local mutation revives it.
  permanent,

  /// A newer version exists on the server; a human must decide how to
  /// resolve it. The job should stop and surface to the user.
  conflict,
}

class SyncOutcome {
  /// The operation succeeded, or there was nothing to sync.
  const SyncOutcome.success()
      : kind = SyncOutcomeKind.success,
        code = null;

  /// A retryable failure. [code] is a short sanitized token
  /// (e.g. `network`, `429`, `5xx`, `PGRST301`).
  const SyncOutcome.transient(this.code) : kind = SyncOutcomeKind.transient;

  /// A non-retryable failure. [code] is a short sanitized token
  /// (e.g. `42501`, `22P02`, `23505`, `storage_403`, `empty_created_by`).
  const SyncOutcome.permanent(this.code) : kind = SyncOutcomeKind.permanent;

  /// A server-side newer version blocks the write. [code] is a short
  /// sanitized token (e.g. `answer_key_changed`).
  const SyncOutcome.conflict(this.code) : kind = SyncOutcomeKind.conflict;

  final SyncOutcomeKind kind;

  /// Sanitized short code, or null for [SyncOutcomeKind.success].
  final String? code;

  bool get isSuccess => kind == SyncOutcomeKind.success;

  bool get isTransient => kind == SyncOutcomeKind.transient;

  bool get isPermanent => kind == SyncOutcomeKind.permanent;

  bool get isConflict => kind == SyncOutcomeKind.conflict;

  @override
  bool operator ==(Object other) =>
      other is SyncOutcome && other.kind == kind && other.code == code;

  @override
  int get hashCode => Object.hash(kind, code);

  @override
  String toString() =>
      'SyncOutcome(${kind.name}${code == null ? '' : ', $code'})';
}
