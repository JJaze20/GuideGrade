import 'sync_job.dart';

/// Plain-English meaning of the sanitized error code a failed sync job
/// recorded ([SyncJob.lastErrorCode]), or null for a code this doesn't know.
/// The codes are already free of names, tokens and payloads, so they are safe
/// to show. These are explanations of what the cloud said, not fixes — most of
/// them are rules that live in the Supabase project, outside this app.
String? syncFailureMeaning(String? code) {
  switch (code) {
    case '42501':
      return 'the cloud refused the write (its permission rules)';
    case '23503':
      return 'its batch is not in the cloud yet, so the sheet cannot be saved there';
    case '23514':
      return 'a cloud database rule rejected the student name/ID combination';
    case '23505':
      return 'the cloud already has a conflicting copy';
    case '23502':
    case '22P02':
    case '400':
    case '422':
      return 'the cloud rejected the data as invalid';
    case 'PGRST301':
    case '401':
      return 'the cloud sign-in is not accepted — sign out and back in';
    case 'network':
      return 'no connection to the cloud';
    case 'unknown':
      return 'an unrecognised error (from an older attempt)';
  }
  return null;
}

/// One line per distinct error among [failedJobs], most common first, e.g.
/// `42501 ×4 — the cloud refused the write (its permission rules)`.
List<String> summarizeSyncFailures(Iterable<SyncJob> failedJobs) {
  final counts = <String, int>{};
  for (final job in failedJobs) {
    final code = (job.lastErrorCode ?? '').isEmpty ? 'unknown' : job.lastErrorCode!;
    counts[code] = (counts[code] ?? 0) + 1;
  }
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return [
    for (final e in entries)
      '${e.key} ×${e.value}'
          '${syncFailureMeaning(e.key) == null ? '' : ' — ${syncFailureMeaning(e.key)}'}',
  ];
}
