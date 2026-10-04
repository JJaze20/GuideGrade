/// Mobile's read-time/display-time canonical Examinee overlay.
///
/// Mirrors `GuidanceWebResultsService.loadResultsForBatch`'s own
/// `examinee_id` -> `examinees` resolution (collect every linked scan's
/// `examinee_id`, then ONE bulk [SyncClient.readCloudExaminees] call, then
/// match in memory) -- the same pattern, reusing the exact same
/// [SyncClient.readCloudScans]/[SyncClient.readCloudExaminees] methods Web
/// already relies on, so there is only one implementation of "how a scan's
/// canonical identity is resolved" in the whole app.
///
/// Deliberately NEVER persisted into [LocalScan]/[ExamineeInfo]: the result
/// is held only in a caller's in-memory `State`, for exactly as long as a
/// screen is open. `CloudRestoreService`/`LocalBatchRepository` are
/// insert-only for scans (an already-downloaded local scan's own fields are
/// never overwritten by a restore), so a persisted copy of the canonical
/// name/id could never be kept fresh for a scan the device already has --
/// a live, re-resolved-on-every-open lookup sidesteps that limitation
/// entirely, exactly as the Web Results page already does by re-fetching on
/// every page load.
library;

import '../../models/examinee_record.dart';
import 'sync_client.dart';

/// Every scan in [batchId] whose `examinee_id` resolves to a real,
/// findable `examinees` row, as a `scanId -> ExamineeRecord` map -- the
/// exact same resolution rule as `WebBatchResults.linkedExamineeByScanId`:
/// a null `examinee_id` (never linked) has no entry, and a dangling link
/// (the `examinees` row can't be found -- deleted/RLS-hidden/stale) has no
/// entry either, indistinguishable from "never linked" by design. The
/// scan's own OCR/tagged [LocalScan.examinee] is never read or used as a
/// fallback here -- that fallback is the caller's responsibility, exactly
/// as `guidance_web_results_view.dart`'s own `_displayName` keeps it.
///
/// Best-effort only: returns an empty map on ANY failure -- offline,
/// network error, or an RLS permission denial for a session that isn't
/// `guidance_council` (an expected, silent case, never surfaced as an
/// error; see `0001_create_examinees.sql`'s `examinees_select_guidance`
/// policy). Never throws -- a canonical-identity nicety must never be able
/// to break the screen that's showing it, the same posture
/// `CloudRestoreService.restoreImageIfMissing` already takes for images.
Future<Map<String, ExamineeRecord>> resolveLinkedExaminees(
  SyncClient client,
  String batchId,
) async {
  try {
    final scansRead = await client.readCloudScans(batchId);
    if (!scansRead.isSuccess) return const {};

    final examineeIdByScanId = <String, String>{
      for (final row in scansRead.scans)
        if (row.examineeId != null && row.examineeId!.isNotEmpty) row.id: row.examineeId!,
    };
    if (examineeIdByScanId.isEmpty) return const {};

    final examineesRead = await client.readCloudExaminees();
    if (!examineesRead.isSuccess) return const {};

    final byId = {
      for (final row in examineesRead.examinees) row.id: _toExamineeRecord(row),
    };

    return {
      for (final entry in examineeIdByScanId.entries)
        if (byId[entry.value] != null) entry.key: byId[entry.value]!,
    };
  } catch (_) {
    return const {};
  }
}

/// Field-for-field the same mapping as
/// `guidance_web_examinee_records_service.dart`'s `examineeRecordFromCloudRow`
/// -- duplicated (rather than imported) so this core/sync file has no
/// dependency on a `features/guidance_web` file, the same layering every
/// other file in `lib/core/sync/` already keeps.
ExamineeRecord _toExamineeRecord(CloudExamineeRow row) => ExamineeRecord(
      id: row.id,
      temporaryExamineeId: row.temporaryExamineeId,
      officialStudentId: row.officialStudentId,
      firstName: row.firstName,
      middleName: row.middleName,
      lastName: row.lastName,
      birthDate: row.birthDate,
      lastAttendedSchool: row.lastAttendedSchool,
      status: row.status,
      archivedAt: row.archivedAt,
      archivedByUid: row.archivedByUid,
      createdAt: row.createdAt,
      createdByUid: row.createdByUid,
      updatedAt: row.updatedAt,
      updatedByUid: row.updatedByUid,
    );
