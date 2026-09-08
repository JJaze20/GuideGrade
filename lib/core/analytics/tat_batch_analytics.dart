// Pure, dependency-free descriptive analytics for one TAT batch.
//
// This is a CORE helper: no Flutter, no Firebase, no Supabase, no file /
// SharedPreferences / network / BuildContext / AppState access. It reads
// the already-persisted models and computes numbers; it never mutates the
// source batch or its scans.
//
// The official TAT percentage (`tatTotal / 160 * 100`) and the course
// eligibility outcome are NOT re-derived here — they come from
// [tatPercentage] / [tatEligibility] / [TatEligibility] in
// lib/core/omr/tat_result.dart. `LocalScanResult.percentage` and
// `LocalBatch.averagePercentage` are legacy generic values and are
// deliberately never read.
//
// Only "analyzable" TAT records feed the score statistics — see
// [TatBatchAnalytics._isAnalyzable]. Legacy graded TAT scans with no
// per-test breakdown, and records whose persisted TAT fields are missing
// or out of range, are excluded from the score analytics (but still
// counted in [TatBatchAnalytics.totalExaminees] /
// [TatBatchAnalytics.gradedExaminees]) and surfaced through
// [TatBatchAnalytics.excludedGradedCount]. Persisted values are consumed
// exactly as stored: no score is recomputed, clamped, repaired, or
// checked for `tatTotal == test1 + test2 + test3` consistency.

import '../../models/local_batch.dart';
import '../omr/tat_result.dart';

/// Maximum score for TAT Test 1 (`correct * 2`, 30 items).
const int _tatTest1Max = 60;

/// Maximum score for TAT Test 2 (`max(0, correct - wrong)`, 80 items).
const int _tatTest2Max = 80;

/// Maximum score for TAT Test 3 (`max(0, correct - wrong)`, 20 items).
const int _tatTest3Max = 20;

/// Maximum combined TAT total (`60 + 80 + 20`).
const int _tatTotalMax = 160;

/// The three sub-tests of the TAT, used by
/// [TatBatchAnalytics.strongestTestByPercent] /
/// [TatBatchAnalytics.weakestTestByPercent].
enum TatTestKey { test1, test2, test3 }

/// Fixed 20-point bands for [TatBatchAnalytics.totalScoreDistribution] over
/// the 0..160 TAT total. Type-safe keys rather than arbitrary strings.
/// Bands `0–19` … `120–139` are width 20; the final band is `140–160`
/// (inclusive of the maximum 160).
///
/// These are a plain histogram of the total score. The `48 / 160` (30%)
/// eligibility cutoff does NOT move a band edge — eligibility stays a
/// separate two-bucket analysis in
/// [TatBatchAnalytics.eligibilityDistribution].
enum TatTotalBand {
  band0to19(0, 19, '0–19'),
  band20to39(20, 39, '20–39'),
  band40to59(40, 59, '40–59'),
  band60to79(60, 79, '60–79'),
  band80to99(80, 99, '80–99'),
  band100to119(100, 119, '100–119'),
  band120to139(120, 139, '120–139'),
  band140to160(140, 160, '140–160');

  const TatTotalBand(this.minScore, this.maxScore, this.label);

  /// Inclusive lower bound of the band.
  final int minScore;

  /// Inclusive upper bound of the band.
  final int maxScore;

  /// Human-readable range, e.g. `"20–39"`.
  final String label;

  /// The band a TAT total falls into, or `null` when the score is outside
  /// the valid `0..160` range (corrupt data — a real TAT total is always
  /// `0..160`).
  static TatTotalBand? forScore(int score) {
    for (final band in values) {
      if (score >= band.minScore && score <= band.maxScore) return band;
    }
    return null;
  }
}

/// Quarter-of-maximum bands for the per-test distributions
/// ([TatBatchAnalytics.test1Distribution] etc.). Because the three tests
/// have different maximums (60 / 80 / 20), an absolute band width can't
/// serve all three; normalising to percent-of-max gives every test the
/// same four-segment shape a UI can render identically.
///
/// Bucketing is deterministic integer arithmetic: `score * 100 ~/
/// maxPossible` (floored to a whole percent), then matched against the
/// inclusive `[min, max]` percent range of each band — no floating-point
/// boundary ambiguity.
enum TatTestQuartile {
  q0to24(0, 24, '0–24%'),
  q25to49(25, 49, '25–49%'),
  q50to74(50, 74, '50–74%'),
  q75to100(75, 100, '75–100%');

  const TatTestQuartile(this.minPercent, this.maxPercent, this.label);

  /// Inclusive lower bound, as a whole percent of the test maximum.
  final int minPercent;

  /// Inclusive upper bound, as a whole percent of the test maximum.
  final int maxPercent;

  /// Human-readable range, e.g. `"25–49%"`.
  final String label;

  /// The quartile [score] out of [maxPossible] falls into, using the
  /// floored integer percent-of-max `score * 100 ~/ maxPossible`. Returns
  /// `null` when the inputs are out of range (`maxPossible <= 0`, a
  /// negative score, or a score above `maxPossible`).
  static TatTestQuartile? forScore(int score, int maxPossible) {
    if (maxPossible <= 0 || score < 0 || score > maxPossible) return null;
    final percent = score * 100 ~/ maxPossible;
    for (final quartile in values) {
      if (percent >= quartile.minPercent && percent <= quartile.maxPercent) {
        return quartile;
      }
    }
    return null;
  }
}

/// Descriptive statistics for one TAT sub-test across the analyzable
/// examinees of a batch. Immutable. All of [average], [highest], [lowest],
/// [median] and [averagePercentOfMax] are `null` when [scoreCount] is `0`
/// (empty / all-ungraded / all-excluded batch).
///
/// [averagePercentOfMax] is `average / maxPossible * 100` — an
/// **informational** per-test figure, NOT the official TAT percentage
/// (only the 0..160 total has an official percentage, via [tatPercentage]).
class TatTestSummary {
  const TatTestSummary({
    required this.maxPossible,
    required this.scoreCount,
    required this.average,
    required this.highest,
    required this.lowest,
    required this.median,
    required this.averagePercentOfMax,
  });

  /// Maximum possible score for this test (60 / 80 / 20).
  final int maxPossible;

  /// Number of analyzable examinees contributing to this summary. Equal to
  /// [TatBatchAnalytics.analyzableExaminees].
  final int scoreCount;

  /// Mean sub-test score, or `null` when [scoreCount] is `0`.
  final double? average;

  /// Highest sub-test score, or `null` when [scoreCount] is `0`.
  final int? highest;

  /// Lowest sub-test score, or `null` when [scoreCount] is `0`.
  final int? lowest;

  /// Median sub-test score (mean of the two middle values for an even
  /// count), or `null` when [scoreCount] is `0`.
  final double? median;

  /// [average] as a percent of [maxPossible], or `null` when [scoreCount]
  /// is `0`. Informational only — see the class doc.
  final double? averagePercentOfMax;
}

/// One analyzable TAT examinee's position in the batch ranking. Immutable;
/// carries enough to identify the examinee and show the result without
/// recomputing anything.
class TatRankedScorer {
  const TatRankedScorer({
    required this.rank,
    required this.scanId,
    required this.tatTotal,
    required this.percentage,
    required this.eligibility,
    this.examineeNumber,
    this.displayName,
  });

  /// Dense rank: highest TAT total is `1`, tied totals share a rank, and
  /// the next distinct total gets the next integer (no gaps).
  final int rank;

  /// [LocalScan.id] — the non-personal technical id of the scan.
  final String scanId;

  /// Combined TAT total, `0..160` (`LocalScanResult.tatTotal`).
  final int tatTotal;

  /// Official TAT percentage, `tatTotal / 160 * 100` via [tatPercentage].
  /// Non-null for any total in `0..160`.
  final double? percentage;

  /// Official TAT eligibility outcome via [tatEligibility]. Non-null for
  /// any total in `0..160`.
  final TatEligibility? eligibility;

  /// [ExamineeInfo.examineeNumber] when a non-blank tag exists, else `null`
  /// (untagged, or an OCR-suggested name with no number yet).
  final String? examineeNumber;

  /// [ExamineeInfo.displayName] when the scan carries an examinee, else
  /// `null`. May be `"Unnamed"` when an examinee object exists but is
  /// blank.
  final String? displayName;
}

/// Descriptive analytics for one TAT batch.
///
/// [totalExaminees] counts every scan. [gradedExaminees] counts scans
/// whose `result.status == 'Graded'`. [analyzableExaminees] is the subset
/// of graded scans that also carry a valid per-test TAT breakdown (see
/// [_isAnalyzable]); only those feed the averages, min/max, median,
/// percentages, distributions, ranking and top scorers. A fully-zero
/// analyzable record is a valid data point and is included.
/// [excludedGradedCount] (`gradedExaminees - analyzableExaminees`) is the
/// count of graded scans dropped from the score analytics — legacy
/// records without a breakdown plus any with missing / out-of-range TAT
/// fields.
class TatBatchAnalytics {
  TatBatchAnalytics._({
    required this.totalExaminees,
    required this.gradedExaminees,
    required this.analyzableExaminees,
    required this.excludedGradedCount,
    required this.averageTatTotal,
    required this.highestTatTotal,
    required this.lowestTatTotal,
    required this.medianTatTotal,
    required this.averageTatPercentage,
    required this.highestTatPercentage,
    required this.lowestTatPercentage,
    required this.medianTatPercentage,
    required this.test1,
    required this.test2,
    required this.test3,
    required this.strongestTestByPercent,
    required this.weakestTestByPercent,
    required Map<TatEligibility, int> eligibilityDistribution,
    required Map<TatTotalBand, int> totalScoreDistribution,
    required Map<TatTestQuartile, int> test1Distribution,
    required Map<TatTestQuartile, int> test2Distribution,
    required Map<TatTestQuartile, int> test3Distribution,
    required List<TatRankedScorer> rankedScorers,
  })  : eligibilityDistribution = Map.unmodifiable(eligibilityDistribution),
        totalScoreDistribution = Map.unmodifiable(totalScoreDistribution),
        test1Distribution = Map.unmodifiable(test1Distribution),
        test2Distribution = Map.unmodifiable(test2Distribution),
        test3Distribution = Map.unmodifiable(test3Distribution),
        rankedScorers = List.unmodifiable(rankedScorers);

  // --- overview --------------------------------------------------------

  /// Every scan in the batch (graded, ungraded, legacy, malformed).
  final int totalExaminees;

  /// Scans where `scan.result?.isGraded == true`.
  final int gradedExaminees;

  /// Graded scans that also carry a valid per-test TAT breakdown — the
  /// records that feed every score statistic below.
  final int analyzableExaminees;

  /// `gradedExaminees - analyzableExaminees`: graded scans dropped from
  /// the score analytics (legacy, or missing / out-of-range TAT fields).
  final int excludedGradedCount;

  /// `totalExaminees - gradedExaminees`.
  int get ungradedExaminees => totalExaminees - gradedExaminees;

  // --- TAT total summary (analyzable records only) --------------------

  /// Mean TAT total (`0..160`), or `null` when no records are analyzable.
  final double? averageTatTotal;

  /// Highest analyzable TAT total, or `null` when none are analyzable.
  final int? highestTatTotal;

  /// Lowest analyzable TAT total, or `null` when none are analyzable.
  final int? lowestTatTotal;

  /// Median TAT total (mean of the two middle values for an even count),
  /// or `null` when no records are analyzable.
  final double? medianTatTotal;

  /// Mean of the official `tatPercentage(tatTotal)` over analyzable
  /// records, or `null` when none are analyzable. Never derived from
  /// `LocalScanResult.percentage` or `LocalBatch.averagePercentage`.
  final double? averageTatPercentage;

  /// Official percentage of the [highestTatTotal], or `null`.
  final double? highestTatPercentage;

  /// Official percentage of the [lowestTatTotal], or `null`.
  final double? lowestTatPercentage;

  /// Median of the official per-record percentages (mean of the two
  /// middle values for an even count), or `null`.
  final double? medianTatPercentage;

  // --- per-test summaries -------------------------------------------------

  /// TAT Test 1 statistics (max 60), from the persisted
  /// `LocalScanResult.tatTest1Score`.
  final TatTestSummary test1;

  /// TAT Test 2 statistics (max 80), from the persisted
  /// `LocalScanResult.tatTest2Score`.
  final TatTestSummary test2;

  /// TAT Test 3 statistics (max 20), from the persisted
  /// `LocalScanResult.tatTest3Score`.
  final TatTestSummary test3;

  /// The sub-test with the highest [TatTestSummary.averagePercentOfMax],
  /// or `null` when no records are analyzable. Ties resolve to the lowest
  /// [TatTestKey] ordinal (`test1` before `test2` before `test3`).
  final TatTestKey? strongestTestByPercent;

  /// The sub-test with the lowest [TatTestSummary.averagePercentOfMax], or
  /// `null` when no records are analyzable. Ties resolve to the lowest
  /// [TatTestKey] ordinal.
  final TatTestKey? weakestTestByPercent;

  // --- eligibility ------------------------------------------------------

  /// Count of analyzable records per official [TatEligibility] outcome.
  /// Contains both keys (one possibly `0`) when there is >= 1 analyzable
  /// record; an empty map when there are none.
  final Map<TatEligibility, int> eligibilityDistribution;

  /// Analyzable records that met the TAT requirement (`tatTotal >= 48`).
  int get meetsRequirementCount =>
      eligibilityDistribution[TatEligibility.meetsRequirement] ?? 0;

  /// Analyzable records that did not meet the TAT requirement
  /// (`tatTotal <= 47`).
  int get doesNotMeetRequirementCount =>
      eligibilityDistribution[TatEligibility.doesNotMeetRequirement] ?? 0;

  /// `meetsRequirementCount / analyzableExaminees * 100`, or `null` when
  /// there are no analyzable records.
  double? get meetsRequirementRate => analyzableExaminees == 0
      ? null
      : meetsRequirementCount / analyzableExaminees * 100;

  // --- distributions --------------------------------------------------

  /// Count of analyzable records per fixed [TatTotalBand]. Contains all
  /// eight keys (some possibly `0`) when there is >= 1 analyzable record;
  /// an empty map when there are none.
  final Map<TatTotalBand, int> totalScoreDistribution;

  /// Count of analyzable records per [TatTestQuartile] for Test 1. All
  /// four keys present (some possibly `0`) when there is >= 1 analyzable
  /// record; empty otherwise.
  final Map<TatTestQuartile, int> test1Distribution;

  /// Per-[TatTestQuartile] counts for Test 2. Same empty-state contract as
  /// [test1Distribution].
  final Map<TatTestQuartile, int> test2Distribution;

  /// Per-[TatTestQuartile] counts for Test 3. Same empty-state contract as
  /// [test1Distribution].
  final Map<TatTestQuartile, int> test3Distribution;

  // --- ranking --------------------------------------------------------

  /// Every analyzable examinee, dense-ranked, highest TAT total first,
  /// with a deterministic tie order (total desc, then examinee number asc
  /// with blanks last, then scan id asc). Only the total affects [rank].
  final List<TatRankedScorer> rankedScorers;

  /// The top scorers by dense rank, **including every tie at the cutoff**.
  ///
  /// `limit` is a number of distinct ranks: e.g. for TAT totals
  /// `140, 140, 120, 100` (dense ranks `1, 1, 2, 3`),
  /// `topScorers(limit: 2)` returns both `140`s and the `120`.
  /// `limit <= 0` returns an empty list.
  List<TatRankedScorer> topScorers({int limit = 5}) {
    if (limit <= 0 || rankedScorers.isEmpty) return const [];
    return List.unmodifiable(
      rankedScorers.where((scorer) => scorer.rank <= limit),
    );
  }

  // --- construction ----------------------------------------------------

  /// Analytics for a TAT [batch]. Throws [ArgumentError] if the batch is
  /// not a TAT batch — a non-TAT batch is never silently analysed.
  factory TatBatchAnalytics.fromBatch(LocalBatch batch) {
    if (batch.examCode != 'TAT') {
      throw ArgumentError('TatBatchAnalytics requires a TAT batch');
    }
    return TatBatchAnalytics.fromScans(batch.scans);
  }

  /// Analytics for an arbitrary collection of [scans] assumed to belong to
  /// a TAT batch. Pure — the input is only read.
  factory TatBatchAnalytics.fromScans(Iterable<LocalScan> scans) {
    final all = scans.toList(growable: false);
    final graded = all
        .where((scan) => scan.result?.isGraded == true)
        .toList(growable: false);
    final analyzable =
        graded.where(_isAnalyzable).toList(growable: false);

    final totals = analyzable
        .map((scan) => scan.result!.tatTotal!)
        .toList(growable: false)
      ..sort();
    final test1Scores = analyzable
        .map((scan) => scan.result!.tatTest1Score!)
        .toList(growable: false)
      ..sort();
    final test2Scores = analyzable
        .map((scan) => scan.result!.tatTest2Score!)
        .toList(growable: false)
      ..sort();
    final test3Scores = analyzable
        .map((scan) => scan.result!.tatTest3Score!)
        .toList(growable: false)
      ..sort();

    double? averageTatTotal;
    int? highestTatTotal;
    int? lowestTatTotal;
    double? medianTatTotal;
    double? averageTatPercentage;
    double? highestTatPercentage;
    double? lowestTatPercentage;
    double? medianTatPercentage;
    final eligibilityDistribution = <TatEligibility, int>{};
    final totalScoreDistribution = <TatTotalBand, int>{};
    final test1Distribution = <TatTestQuartile, int>{};
    final test2Distribution = <TatTestQuartile, int>{};
    final test3Distribution = <TatTestQuartile, int>{};

    if (totals.isNotEmpty) {
      final n = totals.length;
      final sum = totals.fold<int>(0, (acc, s) => acc + s);
      averageTatTotal = sum / n;
      lowestTatTotal = totals.first;
      highestTatTotal = totals.last;
      medianTatTotal = n.isOdd
          ? totals[n ~/ 2].toDouble()
          : (totals[n ~/ 2 - 1] + totals[n ~/ 2]) / 2;

      // Every analyzable total is in 0..160, so tatPercentage never
      // returns null here and this list stays the same length as totals.
      // It is also already sorted (tatPercentage is monotonic in total).
      final percentages = totals
          .map(tatPercentage)
          .whereType<double>()
          .toList(growable: false);
      if (percentages.isNotEmpty) {
        final pn = percentages.length;
        averageTatPercentage =
            percentages.fold<double>(0, (acc, p) => acc + p) / pn;
        lowestTatPercentage = percentages.first;
        highestTatPercentage = percentages.last;
        medianTatPercentage = pn.isOdd
            ? percentages[pn ~/ 2]
            : (percentages[pn ~/ 2 - 1] + percentages[pn ~/ 2]) / 2;
      }

      for (final outcome in TatEligibility.values) {
        eligibilityDistribution[outcome] = 0;
      }
      for (final band in TatTotalBand.values) {
        totalScoreDistribution[band] = 0;
      }
      for (final quartile in TatTestQuartile.values) {
        test1Distribution[quartile] = 0;
        test2Distribution[quartile] = 0;
        test3Distribution[quartile] = 0;
      }

      for (final total in totals) {
        final outcome = tatEligibility(total);
        if (outcome != null) {
          eligibilityDistribution[outcome] =
              eligibilityDistribution[outcome]! + 1;
        }
        final band = TatTotalBand.forScore(total);
        if (band != null) {
          totalScoreDistribution[band] = totalScoreDistribution[band]! + 1;
        }
      }
      _fillQuartiles(test1Scores, _tatTest1Max, test1Distribution);
      _fillQuartiles(test2Scores, _tatTest2Max, test2Distribution);
      _fillQuartiles(test3Scores, _tatTest3Max, test3Distribution);
    }

    final test1 = _summarise(test1Scores, _tatTest1Max);
    final test2 = _summarise(test2Scores, _tatTest2Max);
    final test3 = _summarise(test3Scores, _tatTest3Max);
    final (strongest, weakest) = _strongestWeakest(test1, test2, test3);

    return TatBatchAnalytics._(
      totalExaminees: all.length,
      gradedExaminees: graded.length,
      analyzableExaminees: analyzable.length,
      excludedGradedCount: graded.length - analyzable.length,
      averageTatTotal: averageTatTotal,
      highestTatTotal: highestTatTotal,
      lowestTatTotal: lowestTatTotal,
      medianTatTotal: medianTatTotal,
      averageTatPercentage: averageTatPercentage,
      highestTatPercentage: highestTatPercentage,
      lowestTatPercentage: lowestTatPercentage,
      medianTatPercentage: medianTatPercentage,
      test1: test1,
      test2: test2,
      test3: test3,
      strongestTestByPercent: strongest,
      weakestTestByPercent: weakest,
      eligibilityDistribution: eligibilityDistribution,
      totalScoreDistribution: totalScoreDistribution,
      test1Distribution: test1Distribution,
      test2Distribution: test2Distribution,
      test3Distribution: test3Distribution,
      rankedScorers: _rankScorers(analyzable),
    );
  }

  // --- analyzable-record gate ----------------------------------------

  /// Whether [scan] is a graded TAT result whose persisted per-test
  /// breakdown is present and in range. No score is recomputed or
  /// repaired, and `tatTotal == test1 + test2 + test3` is deliberately
  /// NOT checked.
  static bool _isAnalyzable(LocalScan scan) {
    final result = scan.result;
    if (result == null || !result.isGraded || !result.hasTatBreakdown) {
      return false;
    }
    final t1 = result.tatTest1Score;
    final t2 = result.tatTest2Score;
    final t3 = result.tatTest3Score;
    final total = result.tatTotal;
    if (t1 == null || t1 < 0 || t1 > _tatTest1Max) return false;
    if (t2 == null || t2 < 0 || t2 > _tatTest2Max) return false;
    if (t3 == null || t3 < 0 || t3 > _tatTest3Max) return false;
    if (total == null || total < 0 || total > _tatTotalMax) return false;
    return true;
  }

  // --- summaries -----------------------------------------------------

  static TatTestSummary _summarise(List<int> sortedScores, int maxPossible) {
    if (sortedScores.isEmpty) {
      return TatTestSummary(
        maxPossible: maxPossible,
        scoreCount: 0,
        average: null,
        highest: null,
        lowest: null,
        median: null,
        averagePercentOfMax: null,
      );
    }
    final n = sortedScores.length;
    final sum = sortedScores.fold<int>(0, (acc, s) => acc + s);
    final average = sum / n;
    final median = n.isOdd
        ? sortedScores[n ~/ 2].toDouble()
        : (sortedScores[n ~/ 2 - 1] + sortedScores[n ~/ 2]) / 2;
    return TatTestSummary(
      maxPossible: maxPossible,
      scoreCount: n,
      average: average,
      highest: sortedScores.last,
      lowest: sortedScores.first,
      median: median,
      averagePercentOfMax: average / maxPossible * 100,
    );
  }

  static void _fillQuartiles(
    List<int> scores,
    int maxPossible,
    Map<TatTestQuartile, int> into,
  ) {
    for (final score in scores) {
      final quartile = TatTestQuartile.forScore(score, maxPossible);
      if (quartile != null) into[quartile] = into[quartile]! + 1;
    }
  }

  static (TatTestKey?, TatTestKey?) _strongestWeakest(
    TatTestSummary test1,
    TatTestSummary test2,
    TatTestSummary test3,
  ) {
    final entries = <(TatTestKey, double)>[
      if (test1.averagePercentOfMax != null)
        (TatTestKey.test1, test1.averagePercentOfMax!),
      if (test2.averagePercentOfMax != null)
        (TatTestKey.test2, test2.averagePercentOfMax!),
      if (test3.averagePercentOfMax != null)
        (TatTestKey.test3, test3.averagePercentOfMax!),
    ];
    if (entries.isEmpty) return (null, null);

    var strongest = entries.first.$1;
    var strongestPct = entries.first.$2;
    var weakest = entries.first.$1;
    var weakestPct = entries.first.$2;
    for (final (key, pct) in entries.skip(1)) {
      // Strict comparisons only, so an earlier (lower-ordinal) test keeps
      // the title on a tie.
      if (pct > strongestPct) {
        strongest = key;
        strongestPct = pct;
      }
      if (pct < weakestPct) {
        weakest = key;
        weakestPct = pct;
      }
    }
    return (strongest, weakest);
  }

  // --- ranking -----------------------------------------------------------

  static List<TatRankedScorer> _rankScorers(List<LocalScan> analyzable) {
    if (analyzable.isEmpty) return const [];

    final ordered = [...analyzable]..sort((a, b) {
        final byScore =
            b.result!.tatTotal!.compareTo(a.result!.tatTotal!); // desc
        if (byScore != 0) return byScore;
        final an = _examineeNumberOf(a) ?? '';
        final bn = _examineeNumberOf(b) ?? '';
        if (an.isEmpty != bn.isEmpty) return an.isEmpty ? 1 : -1; // blanks last
        final byNumber = an.compareTo(bn);
        if (byNumber != 0) return byNumber;
        return a.id.compareTo(b.id);
      });

    final result = <TatRankedScorer>[];
    var rank = 0;
    int? previousTotal;
    for (final scan in ordered) {
      final total = scan.result!.tatTotal!;
      if (total != previousTotal) {
        rank += 1; // dense: next distinct total -> next rank
        previousTotal = total;
      }
      result.add(
        TatRankedScorer(
          rank: rank,
          scanId: scan.id,
          tatTotal: total,
          percentage: tatPercentage(total),
          eligibility: tatEligibility(total),
          examineeNumber: _examineeNumberOf(scan),
          displayName: scan.examinee?.displayName,
        ),
      );
    }
    return result;
  }

  static String? _examineeNumberOf(LocalScan scan) {
    final number = scan.examinee?.examineeNumber.trim();
    return (number == null || number.isEmpty) ? null : number;
  }
}
