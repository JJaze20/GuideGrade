import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/analytics/at_batch_analytics.dart';
import '../../../core/analytics/qtm_batch_analytics.dart';
import '../../../core/analytics/tat_batch_analytics.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/omr/qtm_result.dart' show qtmPercentage;
import '../../../core/omr/tat_result.dart';
import '../../../core/services/local_batch_repository.dart';
import '../../../core/services/local_storage_service.dart';
import '../../../core/sync/cloud_batch_mapper.dart';
import '../../../core/sync/supabase_sync_client.dart';
import '../../../core/sync/sync_client.dart';
import '../../../core/sync/sync_outcome.dart';
import '../../../core/sync/sync_queue.dart' show SyncState;
import '../../../models/answer_key.dart';
import '../../../models/local_batch.dart';
import '../../../models/examinee_record.dart';
import '../../../core/omr/admission_category.dart';
import '../../../core/omr/qtm_result.dart' show qtmEligibility, QtmEligibility;
import 'guidance_web_examinee_records_service.dart'
    show examineeRecordFromCloudRow;

/// Thrown by [GuidanceWebAnalyticsService] on any failure. Carries only an
/// already-sanitized, user-safe message.
class GuidanceWebAnalyticsException implements Exception {
  GuidanceWebAnalyticsException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// More batches match the selected filters than one "All Batches" load may
/// analyze. Nothing is loaded and nothing is partially analyzed.
class AnalyticsTooManyBatchesException extends GuidanceWebAnalyticsException {
  AnalyticsTooManyBatchesException(this.count)
    : super(
        'Analytics cannot load all selected batches at once. Please narrow '
        'the selection by choosing a specific batch, exam type, or batch status.',
      );

  /// How many batches matched the filters.
  final int count;
}

/// Web Archive filter for Analytics. "Archived" means a `batch_archives`
/// marker exists — never `batches.status`.
enum AnalyticsBatchStatus { all, current, archived }

/// The batch list plus the Web Archive markers, loaded once per Analytics
/// session. [archivedBatchIds] is `null` when the markers could not be read:
/// archive status is then UNKNOWN (never guessed as "nothing archived"), so
/// only [AnalyticsBatchStatus.all] may be used.
class AnalyticsCatalog {
  const AnalyticsCatalog({
    required this.batches,
    required this.archivedBatchIds,
  });

  final List<LocalBatch> batches;
  final Set<String>? archivedBatchIds;

  bool get archiveFilterAvailable => archivedBatchIds != null;

  /// Batches of [examCode] matching [status], newest first.
  List<LocalBatch> batchesFor({
    required String examCode,
    required AnalyticsBatchStatus status,
  }) {
    final archived = archivedBatchIds;
    if (status != AnalyticsBatchStatus.all && archived == null) {
      throw GuidanceWebAnalyticsException(
        'Archive filtering is temporarily unavailable.',
      );
    }
    final out = [
      for (final b in batches)
        if (b.examCode == examCode &&
            switch (status) {
              AnalyticsBatchStatus.all => true,
              AnalyticsBatchStatus.current => !archived!.contains(b.id),
              AnalyticsBatchStatus.archived => archived!.contains(b.id),
            })
          b,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }
}

/// Overall TAT statistics computed from each scan's STORED `raw_score` — the
/// authoritative recorded TAT total — using only the existing public TAT
/// rules ([tatPercentage], [tatEligibility], [TatTotalBand.forScore]).
///
/// This exists because [TatBatchAnalytics] derives its totals from the
/// per-test breakdown (which needs an Answer Key); the recorded total must
/// stay available, and authoritative, without one. Pure: no I/O.
class TatOverallStats {
  TatOverallStats._({
    required this.totalExaminees,
    required this.gradedExaminees,
    required this.analyzableExaminees,
    required this.averageTotal,
    required this.highestTotal,
    required this.lowestTotal,
    required this.medianTotal,
    required this.averagePercentage,
    required this.highestPercentage,
    required this.lowestPercentage,
    required this.medianPercentage,
    required this.eligibilityDistribution,
    required this.totalScoreDistribution,
  });

  final int totalExaminees;
  final int gradedExaminees;

  /// Graded scans whose stored `raw_score` is a valid TAT total (0..160).
  final int analyzableExaminees;

  int get ungradedExaminees => totalExaminees - gradedExaminees;

  /// Graded scans dropped because their stored total is outside 0..160.
  int get excludedGradedCount => gradedExaminees - analyzableExaminees;

  final double? averageTotal;
  final int? highestTotal;
  final int? lowestTotal;
  final double? medianTotal;
  final double? averagePercentage;
  final double? highestPercentage;
  final double? lowestPercentage;
  final double? medianPercentage;
  final Map<TatEligibility, int> eligibilityDistribution;
  final Map<TatTotalBand, int> totalScoreDistribution;

  factory TatOverallStats.fromScans(Iterable<LocalScan> scans) {
    final all = scans.toList(growable: false);
    final graded = all.where((s) => s.result?.isGraded == true).toList();
    final totals = <int>[
      for (final s in graded)
        if (tatPercentage(s.result!.rawScore) != null) s.result!.rawScore,
    ]..sort();

    double? avg, med, avgPct, medPct, hiPct, loPct;
    int? hi, lo;
    final eligibility = <TatEligibility, int>{};
    final bands = <TatTotalBand, int>{};

    if (totals.isNotEmpty) {
      final n = totals.length;
      avg = totals.fold<int>(0, (a, b) => a + b) / n;
      lo = totals.first;
      hi = totals.last;
      med = n.isOdd
          ? totals[n ~/ 2].toDouble()
          : (totals[n ~/ 2 - 1] + totals[n ~/ 2]) / 2;

      // Every total is 0..160 here, so tatPercentage is never null, and the
      // list stays sorted because the percentage is monotonic in the total.
      final pcts = totals.map(tatPercentage).whereType<double>().toList();
      avgPct = pcts.fold<double>(0, (a, b) => a + b) / pcts.length;
      loPct = pcts.first;
      hiPct = pcts.last;
      final pn = pcts.length;
      medPct = pn.isOdd
          ? pcts[pn ~/ 2]
          : (pcts[pn ~/ 2 - 1] + pcts[pn ~/ 2]) / 2;

      for (final e in TatEligibility.values) {
        eligibility[e] = 0;
      }
      for (final b in TatTotalBand.values) {
        bands[b] = 0;
      }
      for (final total in totals) {
        final e = tatEligibility(total);
        if (e != null) eligibility[e] = eligibility[e]! + 1;
        final b = TatTotalBand.forScore(total);
        if (b != null) bands[b] = bands[b]! + 1;
      }
    }

    return TatOverallStats._(
      totalExaminees: all.length,
      gradedExaminees: graded.length,
      analyzableExaminees: totals.length,
      averageTotal: avg,
      highestTotal: hi,
      lowestTotal: lo,
      medianTotal: med,
      averagePercentage: avgPct,
      highestPercentage: hiPct,
      lowestPercentage: loPct,
      medianPercentage: medPct,
      eligibilityDistribution: Map.unmodifiable(eligibility),
      totalScoreDistribution: Map.unmodifiable(bands),
    );
  }
}

/// Provenance of the current Supabase TAT Answer Key (existing columns:
/// `version`, `updated_at`, `updated_by_name`).
class TatAnswerKeyInfo {
  const TatAnswerKeyInfo({this.version, this.updatedAt, this.updatedByName});

  final int? version;
  final DateTime? updatedAt;
  final String? updatedByName;
}

enum TatDetailStatus {
  /// Key present and complete: per-test analytics are available.
  available,

  /// No `answer_keys` row for TAT.
  keyMissing,

  /// A row exists but does not cover every TAT template item.
  keyIncomplete,

  /// The key could not be read (sanitized failure).
  keyUnavailable,
}

/// One scan whose recomputed (current-key) TAT total differs from its
/// stored `raw_score`. Diagnostic only — the stored score stays official.
class TatKeyDrift {
  const TatKeyDrift({
    required this.scanId,
    required this.batchCode,
    required this.recordedTotal,
    required this.currentKeyTotal,
  });

  final String scanId;
  final String batchCode;
  final int recordedTotal;
  final int currentKeyTotal;
}

/// The Answer-Key-dependent part of TAT Analytics.
class TatDetail {
  const TatDetail({
    required this.status,
    this.keyInfo,
    this.analytics,
    this.drifts = const [],
  });

  final TatDetailStatus status;
  final TatAnswerKeyInfo? keyInfo;

  /// Per-test analytics via [TatBatchAnalytics.fromScans]; non-null only when
  /// [status] is [TatDetailStatus.available].
  final TatBatchAnalytics? analytics;
  final List<TatKeyDrift> drifts;
}

/// A batch whose scan retrieval did not match its exact scan count, so it is
/// excluded from every aggregate.
class IncompleteBatch {
  const IncompleteBatch({
    required this.batch,
    required this.expectedScans,
    required this.retrievedScans,
  });

  final LocalBatch batch;
  final int expectedScans;
  final int retrievedScans;
}

/// A resolved official result from the exact snapshot used by the aggregates.
class AnalyticsExamineeResult {
  const AnalyticsExamineeResult({
    required this.scan,
    required this.examinee,
    required this.batchCode,
  });
  final LocalScan scan;
  final ExamineeRecord examinee;
  final String batchCode;
  int get score => scan.result!.rawScore;
}

class AnalyticsTopScorer {
  const AnalyticsTopScorer({required this.rank, required this.result});
  final int rank;
  final AnalyticsExamineeResult result;
}

/// Competition ranking of canonical examinees, using their highest eligible
/// result in the selected scope. Cut off by rank, never by number of rows.
List<AnalyticsTopScorer> rankAnalyticsExaminees(
  Iterable<AnalyticsExamineeResult> eligible, {
  int maxRank = 10,
}) {
  final best = <String, AnalyticsExamineeResult>{};
  for (final candidate in eligible) {
    final previous = best[candidate.examinee.id];
    if (previous == null ||
        candidate.score > previous.score ||
        (candidate.score == previous.score &&
            candidate.scan.id.compareTo(previous.scan.id) < 0)) {
      best[candidate.examinee.id] = candidate;
    }
  }
  final sorted = best.values.toList()
    ..sort((a, b) {
      final scoreOrder = b.score.compareTo(a.score);
      if (scoreOrder != 0) return scoreOrder;
      final nameOrder = a.examinee.displayName.compareTo(
        b.examinee.displayName,
      );
      return nameOrder != 0
          ? nameOrder
          : a.examinee.id.compareTo(b.examinee.id);
    });
  final ranked = <AnalyticsTopScorer>[];
  var rank = 0;
  int? previousScore;
  for (var i = 0; i < sorted.length; i++) {
    final result = sorted[i];
    if (result.score != previousScore) rank = i + 1;
    if (rank > maxRank) break;
    ranked.add(AnalyticsTopScorer(rank: rank, result: result));
    previousScore = result.score;
  }
  return List.unmodifiable(ranked);
}

class AnalyticsDistributionGroup {
  AnalyticsDistributionGroup(
    this.label,
    Iterable<AnalyticsExamineeResult> results,
  ) : results = List.unmodifiable(results);
  final String label;
  final List<AnalyticsExamineeResult> results;

  /// One display row per canonical identity, preserving all counted results.
  Map<String, List<AnalyticsExamineeResult>> get byExaminee {
    final grouped = <String, List<AnalyticsExamineeResult>>{};
    for (final result in results) {
      (grouped[result.examinee.id] ??= []).add(result);
    }
    return grouped;
  }
}

/// The outcome of one Analytics load.
class AnalyticsResult {
  const AnalyticsResult({
    required this.examCode,
    required this.selectedBatches,
    required this.analyzedBatches,
    required this.incompleteBatches,
    this.distributionResults = const [],
    this.at,
    this.qtm,
    this.tatOverall,
    this.tatDetail,
    this.allActiveAttemptsArchived = false,
  });

  final String examCode;

  /// Every batch the filters selected.
  final List<LocalBatch> selectedBatches;

  /// The complete batches that feed the statistics.
  final List<LocalBatch> analyzedBatches;
  final List<IncompleteBatch> incompleteBatches;

  final List<AnalyticsExamineeResult> distributionResults;

  List<AnalyticsDistributionGroup> distributionGroups(String section) {
    // Reuse the analytics helpers' own eligible scan IDs, including AT's
    // complete-answer-key requirement, rather than defining a second filter.
    final eligibleIds = examCode == 'AT'
        ? at?.rankedScorers.map((s) => s.scanId).toSet() ?? <String>{}
        : examCode == 'QTM'
        ? qtm?.rankedScorers.map((s) => s.scanId).toSet() ?? <String>{}
        : null;
    final eligible = distributionResults
        .where(
          (r) => eligibleIds != null
              ? eligibleIds.contains(r.scan.id)
              : r.scan.result?.isGraded == true &&
                    tatPercentage(r.score) != null,
        )
        .toList();
    AnalyticsDistributionGroup group(
      String label,
      bool Function(int) matches,
    ) => AnalyticsDistributionGroup(
      label,
      eligible.where((r) => matches(r.score)),
    );
    if (section == 'Score Distribution') {
      return switch (examCode) {
        'AT' => [
          for (final band in AtScoreBand.values)
            group(
              '${band.categoryName} (${band.label})',
              (score) => AtScoreBand.forRawScore(score) == band,
            ),
        ],
        'QTM' => [
          for (final band in QtmScoreBand.values)
            group(
              band.label,
              (score) => QtmScoreBand.forRawScore(score) == band,
            ),
        ],
        _ => [
          for (final band in TatTotalBand.values)
            group(band.label, (score) => TatTotalBand.forScore(score) == band),
        ],
      };
    }
    if (section == 'Category Distribution' && examCode == 'AT') {
      return [
        for (final category in AdmissionCategory.values)
          group(
            category.name.toUpperCase(),
            (score) => admissionCategory(score) == category,
          ),
      ];
    }
    if (section == 'Eligibility Distribution' && examCode == 'QTM') {
      return [
        for (final eligibility in QtmEligibility.values)
          group(switch (eligibility) {
            QtmEligibility.allCoursesIncludingBscs =>
              'Qualifies for all courses, including BSCS (18+)',
            QtmEligibility.allCoursesExceptBscs =>
              'Qualifies for all courses except BSCS (15–17)',
            QtmEligibility.notEligible => 'Does not qualify (below 15)',
          }, (score) => qtmEligibility(score) == eligibility),
      ];
    }
    return [
      for (final eligibility in TatEligibility.values)
        group(
          eligibility == TatEligibility.meetsRequirement
              ? 'Meets requirement (48 or above)'
              : 'Does not meet requirement (47 or below)',
          (score) => tatEligibility(score) == eligibility,
        ),
    ];
  }

  List<AnalyticsTopScorer> get topScorers => rankAnalyticsExaminees(
    distributionGroups('Score Distribution').expand((group) => group.results),
  );

  final AtBatchAnalytics? at;
  final QtmBatchAnalytics? qtm;
  final TatOverallStats? tatOverall;
  final TatDetail? tatDetail;

  /// Applicant Retake Management (additive): true when [analyzedBatches] is
  /// non-empty (every selected batch's scans were fully retrieved) but
  /// EVERY one of those scans is an archived retake attempt, so there is
  /// nothing active left to analyze. [at]/[qtm]/[tatOverall]/[tatDetail]
  /// are all null in this case -- deliberately never computed as an
  /// all-zero result, which would look like a real (if unusually poor)
  /// outcome rather than "nothing active to show". Completeness itself is
  /// unaffected: these batches are still physically complete and still
  /// appear in [analyzedBatches].
  final bool allActiveAttemptsArchived;

  bool get hasData => analyzedBatches.isNotEmpty;
}

/// Whether [key] covers EVERY item of the TAT template (`omrTemplates['TAT']`
/// — each section name + item number) with a non-empty correct choice.
bool isTatAnswerKeyComplete(AnswerKey key) {
  final template = omrTemplates['TAT'];
  if (template == null) return false;
  for (final section in template.sections) {
    for (var item = 1; item <= section.itemCount; item++) {
      final choice = key.choiceFor(section.name, item);
      if (choice == null || choice.trim().isEmpty) return false;
    }
  }
  return true;
}

class _BatchScans {
  _BatchScans(this.rows, this.expected);
  final List<CloudScanRow> rows;
  final int expected;
}

/// Read-only Supabase access for the Guidance Council Web Analytics page.
///
/// Stored scan results stay authoritative. The current TAT Answer Key is
/// used ONLY for the TAT per-test breakdown (through the existing
/// `mapCloudScan(row, answerKey:)` pipeline) and never overwrites a recorded
/// score. Nothing here writes, archives, or modifies anything: it only calls
/// `readCloudBatches`, `readBatchArchives`, `readScanCounts`,
/// `readCloudScans`, `readCloudExaminees` and `readAnswerKey`.
///
/// Web Archive status comes from `batch_archives` markers only — never
/// `batches.status`.
///
/// Official-result filter: every AT/QTM/TAT aggregate is computed from
/// scans whose `examinee_id` resolves to a real `examinees` row only (see
/// [_officialRowsOnly]) -- the same official-identity rule
/// [GuidanceWebResultsService.loadResultsForBatch] applies to Results, so
/// this page's totals/graded-ungraded counts/score distributions/averages
/// never count an unlinked or dangling-`examinee_id` scan.
class GuidanceWebAnalyticsService {
  GuidanceWebAnalyticsService({SyncClient? client})
    : _client = client ?? _buildDefaultClient();

  final SyncClient _client;

  /// Most batches one "All Batches" load may analyze.
  static const int maxBatches = 30;

  /// Most scan requests in flight at once.
  static const int maxConcurrency = 4;

  /// Per-batch scans for this Analytics session (in memory only).
  ///
  /// Known, intentional limitation: this caches the raw `CloudScanRow`s,
  /// `examinee_id` included, so linking/unlinking a scan via Examinee
  /// Records (Link to Existing, Confirm & Create, Remove Link) while its
  /// batch is already cached here does NOT retroactively change that
  /// batch's eligibility in [analyze] -- the stale link state is used until
  /// [clearCache] (the existing "Refresh" action) forces a fresh read. This
  /// is the same staleness this cache already has for any other kind of
  /// change (a rescan, a manual score correction) and is treated as
  /// acceptable for the same reason: Analytics is an explicit, session-long
  /// view a Guidance Council member opens and refreshes deliberately, not a
  /// live feed.
  ///
  /// Deliberately NOT automatically invalidated from Examinee Records'
  /// link/unlink/create actions. Considered and rejected:
  ///  * This class and [GuidanceWebExamineeRecordsService] (where those
  ///    actions actually live) have no dependency on each other today and
  ///    are intentionally decoupled -- Analytics doesn't need to know
  ///    Examinee Records exists, or vice versa. A direct call from one into
  ///    the other, or a shared event bus/notifier the way a small part of
  ///    [AppState] does for [GuidancePositions], would be new coupling
  ///    between two services that currently have no reason to know about
  ///    each other, purely to shave off a cache-refresh click.
  ///  * It is largely unnecessary in this app's actual navigation shell
  ///    (`GuidanceWebHomeScreen._buildBody()`): the sidebar swaps the whole
  ///    body widget per destination with no `IndexedStack`/keep-alive
  ///    anywhere in `lib/features/guidance_web/` (confirmed by inspection),
  ///    so this service instance -- and this very cache -- is disposed the
  ///    moment the Guidance Council member navigates to Examinee Records to
  ///    link/unlink/create anything, and a brand-new instance with an empty
  ///    cache is built the next time they open Analytics. The only linking
  ///    actions in this app live in `guidance_web_examinee_records_view.dart`
  ///    / `guidance_web_examinee_detail_view.dart`, neither reachable while
  ///    Analytics itself stays mounted, so the realistic staleness window is
  ///    already far narrower than "cache never clears" -- it is bounded to
  ///    one open Analytics session that never navigates away.
  ///  * The one remaining case the existing Refresh action still covers --
  ///    a second person linking a scan in a different browser session while
  ///    this one's Analytics stays open on the same batch -- is an ordinary,
  ///    already-accepted limitation of any cached read view without a live
  ///    sync channel, not something unique to this cache.
  final Map<String, _BatchScans> _cache = {};

  static SyncClient _buildDefaultClient() {
    return SupabaseSyncClient(
      batches: LocalBatchRepository(),
      localStorage: LocalStorageService(),
      identity: _WebSyncIdentity(),
      getSyncState: () => SyncState(),
    );
  }

  /// Drops every cached batch so the next load re-reads from Supabase.
  void clearCache() => _cache.clear();

  /// Loads the batch list and the Web Archive markers. A failed marker read
  /// is NOT fatal: it yields a catalog whose archive status is unknown.
  Future<AnalyticsCatalog> loadCatalog() async {
    final batchesRead = await _client.readCloudBatches();
    if (!batchesRead.isSuccess) {
      throw GuidanceWebAnalyticsException(_readMessage(batchesRead.error));
    }
    final archivesRead = await _client.readBatchArchives();
    return AnalyticsCatalog(
      batches: batchesRead.batches.map(mapCloudBatch).toList(),
      archivedBatchIds: archivesRead.isSuccess
          ? {for (final a in archivesRead.archives) a.batchId}
          : null,
    );
  }

  /// Analyzes [examCode] batches matching [status]: every matching batch
  /// when [batch] is null (at most [maxBatches]), otherwise just [batch].
  Future<AnalyticsResult> analyze({
    required AnalyticsCatalog catalog,
    required String examCode,
    required AnalyticsBatchStatus status,
    LocalBatch? batch,
    void Function(int loaded, int total)? onProgress,
  }) async {
    if (examCode != 'AT' && examCode != 'QTM' && examCode != 'TAT') {
      throw GuidanceWebAnalyticsException('Unsupported exam type.');
    }

    final List<LocalBatch> selected;
    if (batch != null) {
      selected = [batch];
    } else {
      selected = catalog.batchesFor(examCode: examCode, status: status);
      if (selected.length > maxBatches) {
        throw AnalyticsTooManyBatchesException(selected.length);
      }
    }
    if (selected.isEmpty) {
      return AnalyticsResult(
        examCode: examCode,
        selectedBatches: const [],
        analyzedBatches: const [],
        incompleteBatches: const [],
      );
    }

    await _ensureLoaded(selected, onProgress);

    final complete = <LocalBatch>[];
    final incomplete = <IncompleteBatch>[];
    final activeRows = <CloudScanRow>[];
    var archivedExcludedCount = 0;
    for (final b in selected) {
      final data = _cache[b.id]!;
      // Completeness is a sync signal (did every physical scan row
      // arrive), independent of Applicant Retake Management -- an
      // archived attempt still counts as "retrieved" here, so archiving
      // one never makes an otherwise-fully-synced batch look incomplete.
      if (data.rows.length == data.expected) {
        complete.add(b);
        // The aggregate itself excludes an archived retake attempt (the
        // previous attempt of an approved, archived retake) by default,
        // so it always reflects the current attempt, never a superseded
        // one. QTM scans are never archived, so this never changes QTM's
        // own numbers; a batch with no retake activity is unaffected.
        final active = data.rows.where((r) => !r.isArchivedAttempt).toList();
        archivedExcludedCount += data.rows.length - active.length;
        activeRows.addAll(active);
      } else {
        incomplete.add(
          IncompleteBatch(
            batch: b,
            expectedScans: data.expected,
            retrievedScans: data.rows.length,
          ),
        );
      }
    }

    if (complete.isEmpty) {
      return AnalyticsResult(
        examCode: examCode,
        selectedBatches: selected,
        analyzedBatches: const [],
        incompleteBatches: incomplete,
      );
    }

    // Physically complete, but every scan in those batches is an archived
    // retake attempt -- nothing active is left to analyze. Reported as its
    // own state rather than computing an all-zero AT/QTM/TAT result, which
    // would look like a genuine (if unusually poor) outcome instead of
    // "no active attempts". [lib/core/analytics/*] is never called here.
    if (activeRows.isEmpty && archivedExcludedCount > 0) {
      return AnalyticsResult(
        examCode: examCode,
        selectedBatches: selected,
        analyzedBatches: complete,
        incompleteBatches: incomplete,
        allActiveAttemptsArchived: true,
      );
    }

    // Official-result filter: a scan counts toward Analytics only when its
    // `examinee_id` resolves to a real `examinees` row -- the exact same
    // rule [GuidanceWebResultsService.loadResultsForBatch] applies to
    // Results. `examinee_id IS NULL` (never linked) and a dangling
    // `examinee_id` (row missing/RLS-hidden) are both excluded the same
    // way; OCR/staff-tagged scan identity is never used as a fallback.
    // Skipped entirely when there is nothing active to resolve, so an
    // empty/fully-archived batch never makes an extra request.
    final official = activeRows.isEmpty
        ? (const <CloudScanRow>[], const <String, ExamineeRecord>{})
        : await _officialRowsOnly(activeRows);
    final rows = official.$1;
    final codes = {for (final b in complete) b.id: b.batchCode};
    final distributionResults = List<AnalyticsExamineeResult>.unmodifiable([
      for (final row in rows)
        AnalyticsExamineeResult(
          scan: mapCloudScan(row),
          examinee: official.$2[row.examineeId]!,
          batchCode: codes[row.batchId] ?? row.batchId,
        ),
    ]);

    switch (examCode) {
      case 'AT':
        return AnalyticsResult(
          examCode: examCode,
          selectedBatches: selected,
          analyzedBatches: complete,
          incompleteBatches: incomplete,
          distributionResults: distributionResults,
          at: AtBatchAnalytics.fromScans(rows.map((r) => mapCloudScan(r))),
        );
      case 'QTM':
        return AnalyticsResult(
          examCode: examCode,
          selectedBatches: selected,
          analyzedBatches: complete,
          incompleteBatches: incomplete,
          distributionResults: distributionResults,
          qtm: QtmBatchAnalytics.fromScans(rows.map((r) => mapCloudScan(r))),
        );
      default:
        final tat = await _analyzeTat(rows, complete);
        return AnalyticsResult(
          examCode: examCode,
          selectedBatches: selected,
          analyzedBatches: complete,
          incompleteBatches: incomplete,
          distributionResults: distributionResults,
          tatOverall: tat.$1,
          tatDetail: tat.$2,
        );
    }
  }

  /// Loads scans for every batch in [selected] that is not cached yet: one
  /// exact-count read for the uncached batches, then their scans with at most
  /// [maxConcurrency] requests in flight.
  Future<void> _ensureLoaded(
    List<LocalBatch> selected,
    void Function(int loaded, int total)? onProgress,
  ) async {
    final missing = [
      for (final b in selected)
        if (!_cache.containsKey(b.id)) b,
    ];
    var loaded = selected.length - missing.length;
    onProgress?.call(loaded, selected.length);
    if (missing.isEmpty) return;

    final countsRead = await _client.readScanCounts([
      for (final b in missing) b.id,
    ]);
    if (!countsRead.isSuccess) {
      throw GuidanceWebAnalyticsException(_readMessage(countsRead.error));
    }

    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= missing.length) return;
        final b = missing[i];
        final read = await _client.readCloudScans(b.id);
        if (!read.isSuccess) {
          throw GuidanceWebAnalyticsException(_readMessage(read.error));
        }
        // A batch with no verifiable count is treated as incomplete (-1 can
        // never equal a retrieved length).
        _cache[b.id] = _BatchScans(read.scans, countsRead.counts[b.id] ?? -1);
        loaded++;
        onProgress?.call(loaded, selected.length);
      }
    }

    await Future.wait([
      for (var w = 0; w < math.min(maxConcurrency, missing.length); w++)
        worker(),
    ]);
  }

  /// Narrows [rows] to an official result: `examinee_id` set AND resolving
  /// to an existing `examinees` row -- identical to [GuidanceWebResultsService
  /// .loadResultsForBatch]'s own filter, kept in sync by applying the same
  /// two-step shape (collect linked scan ids, then check each against a
  /// fresh `readCloudExaminees` read) rather than sharing a helper across
  /// the two services, which would be a larger refactor than this fix calls
  /// for. A dangling `examinee_id` is excluded exactly like a null one.
  Future<(List<CloudScanRow>, Map<String, ExamineeRecord>)> _officialRowsOnly(
    List<CloudScanRow> rows,
  ) async {
    final examineeIdByScanId = <String, String>{
      for (final row in rows)
        if (row.examineeId != null && row.examineeId!.isNotEmpty)
          row.id: row.examineeId!,
    };
    if (examineeIdByScanId.isEmpty) {
      return (const <CloudScanRow>[], const <String, ExamineeRecord>{});
    }

    final examinees = await _client.readCloudExaminees();
    if (!examinees.isSuccess) {
      throw GuidanceWebAnalyticsException(_readMessage(examinees.error));
    }
    final records = {
      for (final e in examinees.examinees) e.id: examineeRecordFromCloudRow(e),
    };

    return (
      [
        for (final row in rows)
          if (records.containsKey(examineeIdByScanId[row.id])) row,
      ],
      records,
    );
  }

  /// TAT: overall statistics from stored `raw_score` (always), plus the
  /// Answer-Key-dependent detail. Exactly ONE `readAnswerKey('TAT')` per load.
  Future<(TatOverallStats, TatDetail)> _analyzeTat(
    List<CloudScanRow> rows,
    List<LocalBatch> batches,
  ) async {
    final read = await _client.readAnswerKey('TAT');
    AnswerKey? usableKey;
    TatDetailStatus status;
    TatAnswerKeyInfo? info;

    if (read.error != null) {
      status = TatDetailStatus.keyUnavailable;
    } else if (!read.exists) {
      status = TatDetailStatus.keyMissing;
    } else {
      info = TatAnswerKeyInfo(
        version: read.version,
        updatedAt: read.updatedAt == null
            ? null
            : DateTime.tryParse(read.updatedAt!),
        updatedByName: read.updatedByName,
      );
      final key = AnswerKey(
        examCode: 'TAT',
        correctChoices: read.answers ?? const {},
      );
      if (isTatAnswerKeyComplete(key)) {
        usableKey = key;
        status = TatDetailStatus.available;
      } else {
        status = TatDetailStatus.keyIncomplete;
      }
    }

    // The key is passed only when it is complete; otherwise scans map with no
    // breakdown, and the stored raw_score still drives the overall stats.
    final codes = {for (final b in batches) b.id: b.batchCode};
    final mapped = [
      for (final r in rows)
        (row: r, scan: mapCloudScan(r, answerKey: usableKey)),
    ];
    final overall = TatOverallStats.fromScans(mapped.map((m) => m.scan));

    if (status != TatDetailStatus.available) {
      return (overall, TatDetail(status: status, keyInfo: info));
    }

    final drifts = <TatKeyDrift>[];
    for (final m in mapped) {
      final result = m.scan.result;
      if (result == null || !result.isGraded || !result.hasTatBreakdown)
        continue;
      final recomputed = result.tatTotal!;
      if (recomputed != result.rawScore) {
        drifts.add(
          TatKeyDrift(
            scanId: m.scan.id,
            batchCode: codes[m.row.batchId] ?? m.row.batchId,
            recordedTotal: result.rawScore,
            currentKeyTotal: recomputed,
          ),
        );
      }
    }

    return (
      overall,
      TatDetail(
        status: status,
        keyInfo: info,
        // Drifting scans stay in the per-test summaries (the current key is
        // the only source of a breakdown); the warning says so.
        analytics: TatBatchAnalytics.fromScans(mapped.map((m) => m.scan)),
        drifts: drifts,
      ),
    );
  }

  /// QTM percentage for display of a stored raw score (existing rule).
  static double? qtmPercentOf(int? rawScore) =>
      rawScore == null ? null : qtmPercentage(rawScore);

  String _readMessage(SyncOutcome? outcome) {
    if (outcome != null && outcome.isTransient) {
      return 'Could not reach Supabase. Check your connection and try again.';
    }
    return 'Could not load Analytics data. Please try again.';
  }
}

/// Same as the private identity in the other Guidance Web services.
class _WebSyncIdentity implements SyncIdentity {
  @override
  String? get uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  String? get displayName => FirebaseAuth.instance.currentUser?.displayName;

  @override
  Future<bool> refreshToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await user.getIdToken(true);
    return true;
  }
}
