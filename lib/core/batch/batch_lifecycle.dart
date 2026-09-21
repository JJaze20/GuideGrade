/// Batch status is DERIVED, never picked by hand. This file is the single
/// definition of the three states and the rules between them; the rest of the
/// app only asks it.
///
///  * **Draft** — one or more REQUIRED batch fields are missing or invalid
///    (see [BatchLifecycle.problems]).
///  * **Active** — every required field is valid and the changes have been
///    saved locally. This is also what any edit lands on: an edited batch is
///    re-evaluated as Active (complete) or Draft (incomplete) until its NEW
///    saved revision reaches the cloud.
///  * **Archived** — the cloud has confirmed that this exact saved revision
///    arrived (see [BatchLifecycle.isCloudConfirmed]). Upload progress, a
///    queued/started/partial/failed upload, and pending changes are NOT
///    lifecycle states: they live in the sync queue and never change the
///    status by themselves.
///
/// Required fields (from what the Create/Edit Batch forms actually enforce):
/// batch code (auto-generated, never blank), exam type (a known exam), and
/// expected sheet count (a whole number greater than zero). Description is
/// optional, and so is tagging students — an untagged scan never keeps an
/// otherwise-complete batch in Draft.
///
/// "Revision" here is the batch's `updatedAt`: every saved change moves it
/// forward (the local repository guarantees strictly increasing values), and
/// the sync ledger records the `updatedAt` of the state each push actually
/// carried. Comparing the two is what makes a delayed acknowledgement for an
/// older save unable to archive a newer, unsynced one.
library;

/// One thing wrong with a batch's required fields.
class BatchProblem {
  final String field;
  final String message;
  const BatchProblem(this.field, this.message);

  @override
  String toString() => '$field: $message';
}

class BatchLifecycle {
  const BatchLifecycle._();

  static const String draft = 'Draft';
  static const String active = 'Active';
  static const String archived = 'Archived';

  /// The exam codes a batch may be for. Kept here as data (not imported from
  /// the OMR templates) so these rules stay dependency-free; the app's fixed
  /// exam catalog is AT, QTM and TAT.
  static const Set<String> knownExamCodes = {'AT', 'QTM', 'TAT'};

  /// Everything wrong with the required fields; empty means complete.
  static List<BatchProblem> problems({
    required String batchCode,
    required String examCode,
    required int expectedCount,
    Set<String> examCodes = knownExamCodes,
  }) {
    return [
      if (batchCode.trim().isEmpty)
        const BatchProblem('Batch code', 'A batch code is required.'),
      if (examCode.trim().isEmpty)
        const BatchProblem('Exam type', 'Choose an exam type.')
      else if (!examCodes.contains(examCode.trim()))
        BatchProblem('Exam type', '“$examCode” is not a supported exam.'),
      if (expectedCount <= 0)
        const BatchProblem(
          'Expected sheets',
          'Enter a whole number greater than zero.',
        ),
    ];
  }

  /// The status a batch has right after a local save: Draft when its required
  /// fields have problems, otherwise Active. (Archived is only ever reached
  /// through [isCloudConfirmed], never by saving.)
  static String statusAfterSave(List<BatchProblem> problems) =>
      problems.isEmpty ? active : draft;

  /// Whether the cloud has confirmed the batch's CURRENT saved revision.
  ///
  /// All of these must hold:
  ///  * [cloudConfigured] — there is a cloud data plane at all. Without one
  ///    nothing can ever be confirmed (a local-only build never archives).
  ///  * [lastPushedUpdatedAt] is at or after [updatedAt] — the batch row that
  ///    reached the cloud was built from this revision (or a later one). A
  ///    push carrying an OLDER revision leaves it behind, so a delayed
  ///    acknowledgement cannot archive newer local changes.
  ///  * [outstandingJobs] is zero — no queued, running, retrying, blocked or
  ///    permanently-failed job remains for the batch. That covers the batch
  ///    row, every scan row (answers, corrections, student details, tags) and
  ///    the scan images the sync contract uploads, so a partial or failed
  ///    upload never counts.
  ///
  /// Name-crop images are NOT part of this: by the current sync contract they
  /// are never uploaded (they stay on the device), so nothing waits for them
  /// and nothing claims they reached the cloud.
  static bool isCloudConfirmed({
    required bool cloudConfigured,
    required DateTime updatedAt,
    required DateTime? lastPushedUpdatedAt,
    required int outstandingJobs,
  }) {
    if (!cloudConfigured) return false;
    if (outstandingJobs > 0) return false;
    if (lastPushedUpdatedAt == null) return false;
    return !lastPushedUpdatedAt.isBefore(updatedAt);
  }

  /// The next `updatedAt` for a save: the wall clock, but never equal to or
  /// behind the previous value, so two saves inside the same clock tick (or a
  /// clock that stepped backward) still produce distinct, increasing
  /// revisions.
  static DateTime nextRevision(DateTime previous, DateTime now) {
    final floor = previous.add(const Duration(milliseconds: 1));
    return now.isAfter(floor) ? now : floor;
  }
}
