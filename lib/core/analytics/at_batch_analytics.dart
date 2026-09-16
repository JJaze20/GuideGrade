// Pure, dependency-free descriptive analytics for one Admission Test (AT)
// batch.
//
// This is a CORE helper: no Flutter, no Firebase, no Supabase, no file /
// SharedPreferences / network / BuildContext / AppState access. It reads
// the already-persisted models and computes numbers; it never mutates the
// source batch or its scans.
//
// The official Admission Test percentage is re-derived here as
// `rawScore / 72 * 100` — the same formula the scoring layer
// (`exam_score.dart`) and persistence use. `LocalScanResult.percentage`
// and `LocalBatch.averagePercentage` are deliberately never read, so a
// stale or wrong stored percentage can never reach these statistics even
// though `LocalScanResult.percentage` is otherwise authoritative for AT.
//
// The A / B / C / D bands and the intentional 55–57 "Unclassified" gap
// come from [admissionCategory] in lib/core/omr/admission_category.dart —
// they are NOT re-derived here, and the 55–57 gap is never merged into a
// neighbouring band.
//
// Cluster Analysis (Verbal / Nonverbal and the four sub-clusters printed
// on answer_sheets/AT.pdf page 2) is intentionally NOT implemented: the
// original answer sheet provides no item-number-to-cluster mapping and
// none may be inferred. Course-placement analytics are likewise out of
// scope for this layer.

import '../../models/local_batch.dart';
import '../omr/admission_category.dart';

/// The Admission Test's fixed item count — the maximum raw score and the
/// denominator of the official percentage.
const int _atMaxRawScore = 72;

/// The official Admission Test percentage for [rawScore]: `rawScore / 72 *
/// 100`, the exact formula the scoring and persistence layers use. Returns
/// `null` when [rawScore] is outside the valid `0..72` range (corrupt
/// data — a real AT raw score is always `0..72`). Never reads
/// `LocalScanResult.percentage`.
double? _atPercentage(int rawScore) {
  if (rawScore < 0 || rawScore > _atMaxRawScore) return null;
  return rawScore / _atMaxRawScore * 100;
}

/// Fixed, **admission-category-aligned** raw-score bands for
/// [AtBatchAnalytics.scoreDistribution].
///
/// Unlike an arbitrary statistical histogram, each band is exactly one
/// official Admission outcome, so the distribution reads directly as "how
/// many A / Unclassified / B / C / D". The `55–57` [unclassified] band is
/// kept separate from [a] and [b] and is never merged. Style mirrors
/// `QtmScoreBand` / `TatTotalBand`.
enum AtScoreBand {
  a(0, 54, 'A', '0–54'),
  unclassified(55, 57, 'Unclassified', '55–57'),
  b(58, 60, 'B', '58–60'),
  c(61, 64, 'C', '61–64'),
  d(65, 72, 'D', '65–72');

  const AtScoreBand(
    this.minRawScore,
    this.maxRawScore,
    this.categoryName,
    this.label,
  );

  /// Inclusive lower bound of the band.
  final int minRawScore;

  /// Inclusive upper bound of the band.
  final int maxRawScore;

  /// The official outcome this band represents: `'A'`, `'Unclassified'`,
  /// `'B'`, `'C'` or `'D'`.
  final String categoryName;

  /// Human-readable raw-score range, e.g. `'58–60'`.
  final String label;

  /// The band a raw score falls into, or `null` when the score is outside
  /// the valid `0..72` range (corrupt data — a real AT raw score is always
  /// `0..72`).
  static AtScoreBand? forRawScore(int rawScore) {
    for (final band in values) {
      if (rawScore >= band.minRawScore && rawScore <= band.maxRawScore) {
        return band;
      }
    }
    return null;
  }
}

/// One analyzable Admission Test examinee's position in the batch ranking.
/// Immutable; carries enough to identify the examinee and show the result
/// without recomputing anything.
class AtRankedScorer {
  const AtRankedScorer({
    required this.rank,
    required this.scanId,
    required this.rawScore,
    required this.percentage,
    required this.category,
    this.examineeNumber,
    this.displayName,
  });

  /// Dense rank: highest raw score is `1`, tied raw scores share a rank,
  /// and the next distinct raw score gets the next integer (no gaps).
  final int rank;

  /// [LocalScan.id] — the non-personal technical id of the scan.
  final String scanId;

  /// Correct-answer count, `0..72` (`LocalScanResult.rawScore`).
  final int rawScore;

  /// Official Admission percentage, `rawScore / 72 * 100` via
  /// [_atPercentage]. Non-null for any raw score in `0..72`; never
  /// `LocalScanResult.percentage`.
  final double? percentage;

  /// Official Admission category via [admissionCategory] — `null` for the
  /// intentional `55–57` gap (and for a corrupt out-of-range score).
  final AdmissionCategory? category;

  /// [ExamineeInfo.examineeNumber] when a non-blank tag exists, else `null`
  /// (untagged, or a name entered with no number yet).
  final String? examineeNumber;

  /// [ExamineeInfo.displayName] when the scan carries an examinee, else
  /// `null`. May be `'Unnamed'` when an examinee object exists but is
  /// blank.
  final String? displayName;
}

/// Descriptive analytics for one Admission Test (AT) batch.
///
/// Only **analyzable** scans feed the averages, min/max, median,
/// percentages, category distribution, score distribution, ranking and top
/// scorers. A scan is analyzable when its result is `Graded` **and** the
/// answer key covered the whole 72-item sheet
/// (`totalGraded == 72 && totalItems == 72`): a partial answer key would
/// deflate the raw score and therefore misclassify the admission category,
/// so partial-key results are still counted in [gradedExaminees] but are
/// excluded from every statistic and surfaced through
/// [excludedGradedCount]. Every scan — graded or not — is counted in
/// [totalExaminees]. A graded raw score of `0` is a valid analyzable data
/// point and is included.
class AtBatchAnalytics {
  AtBatchAnalytics._({
    required this.totalExaminees,
    required this.gradedExaminees,
    required this.analyzableExaminees,
    required this.excludedGradedCount,
    required this.averageRawScore,
    required this.highestRawScore,
    required this.lowestRawScore,
    required this.medianRawScore,
    required this.averagePercentage,
    required this.highestPercentage,
    required this.lowestPercentage,
    required this.medianPercentage,
    required this.unclassifiedCount,
    required Map<AdmissionCategory, int> categoryDistribution,
    required Map<AtScoreBand, int> scoreDistribution,
    required List<AtRankedScorer> rankedScorers,
  })  : categoryDistribution = Map.unmodifiable(categoryDistribution),
        scoreDistribution = Map.unmodifiable(scoreDistribution),
        rankedScorers = List.unmodifiable(rankedScorers);

  // --- overview ------------------------------------------------------

  /// Every scan in the batch (graded, ungraded, partial-key).
  final int totalExaminees;

  /// Scans where `scan.result?.isGraded == true`
  /// (`scan.result!.status == 'Graded'`).
  final int gradedExaminees;

  /// Graded scans whose answer key covered the whole sheet
  /// (`totalGraded == 72 && totalItems == 72`) — the records that feed
  /// every statistic below.
  final int analyzableExaminees;

  /// `gradedExaminees - analyzableExaminees`: graded scans dropped from the
  /// statistics because the answer key covered fewer than 72 items (or the
  /// sheet itemization was not 72).
  final int excludedGradedCount;

  /// `totalExaminees - gradedExaminees`.
  int get ungradedExaminees => totalExaminees - gradedExaminees;

  // --- score statistics (analyzable scans only) --------------------

  /// Mean raw score (`0..72`) over analyzable scans, or `null` when there
  /// are none.
  final double? averageRawScore;

  /// Highest analyzable raw score, or `null` when there are none.
  final int? highestRawScore;

  /// Lowest analyzable raw score, or `null` when there are none.
  final int? lowestRawScore;

  /// Median analyzable raw score (mean of the two middle values for an even
  /// count), or `null` when there are none.
  final double? medianRawScore;

  /// Mean of the official `rawScore / 72 * 100` over analyzable scans, or
  /// `null` when there are none. Never derived from
  /// `LocalScanResult.percentage` or `LocalBatch.averagePercentage`.
  final double? averagePercentage;

  /// Official percentage of the [highestRawScore], or `null`.
  final double? highestPercentage;

  /// Official percentage of the [lowestRawScore], or `null`.
  final double? lowestPercentage;

  /// Median of the official per-scan percentages (mean of the two middle
  /// values for an even count), or `null`.
  final double? medianPercentage;

  // --- admission categories ---------------------------------------

  /// Count of analyzable scans per official [AdmissionCategory]
  /// (`A`=0–54, `B`=58–60, `C`=61–64, `D`=65–72). Contains all four keys
  /// (some possibly `0`) when there is >= 1 analyzable scan; an empty map
  /// when there are none. The intentional `55–57` gap is **not** a key
  /// here — see [unclassifiedCount].
  final Map<AdmissionCategory, int> categoryDistribution;

  /// Count of analyzable scans in the intentional `55–57` gap — kept
  /// wholly separate from [categoryDistribution]. `0` when there are none.
  final int unclassifiedCount;

  /// Count of analyzable scans in [category] (`0` when absent).
  int categoryCount(AdmissionCategory category) =>
      categoryDistribution[category] ?? 0;

  /// `categoryCount(category) / analyzableExaminees * 100`, or `null` when
  /// there are no analyzable scans.
  double? categoryRate(AdmissionCategory category) => analyzableExaminees == 0
      ? null
      : categoryCount(category) / analyzableExaminees * 100;

  /// `unclassifiedCount / analyzableExaminees * 100`, or `null` when there
  /// are no analyzable scans.
  double? get unclassifiedRate => analyzableExaminees == 0
      ? null
      : unclassifiedCount / analyzableExaminees * 100;

  // --- score distribution --------------------------------------

  /// Count of analyzable scans per official category-aligned [AtScoreBand]
  /// (`0–54` / `55–57` / `58–60` / `61–64` / `65–72`). Contains all five
  /// keys (some possibly `0`) when there is >= 1 analyzable scan; an empty
  /// map when there are none.
  final Map<AtScoreBand, int> scoreDistribution;

  // --- ranking -----------------------------------------------------

  /// Every analyzable examinee, dense-ranked, highest raw score first, with
  /// a deterministic tie order (raw score desc, then examinee number asc
  /// with blanks last, then scan id asc). Only the raw score affects
  /// [AtRankedScorer.rank].
  final List<AtRankedScorer> rankedScorers;

  /// The top scorers by dense rank, **including every tie at the cutoff**.
  ///
  /// `limit` is a number of distinct ranks: e.g. for raw scores
  /// `72, 65, 65, 60` (dense ranks `1, 2, 2, 3`), `topScorers(limit: 2)`
  /// returns the `72` and both `65`s. `limit <= 0` returns an empty list.
  List<AtRankedScorer> topScorers({int limit = 5}) {
    if (limit <= 0 || rankedScorers.isEmpty) return const [];
    return List.unmodifiable(
      rankedScorers.where((scorer) => scorer.rank <= limit),
    );
  }

  // --- construction ----------------------------------------------

  /// Analytics for an Admission Test [batch]. Throws [ArgumentError] if the
  /// batch is not an AT batch — a non-AT batch is never silently analysed.
  factory AtBatchAnalytics.fromBatch(LocalBatch batch) {
    if (batch.examCode != 'AT') {
      throw ArgumentError('AtBatchAnalytics requires an AT batch');
    }
    return AtBatchAnalytics.fromScans(batch.scans);
  }

  /// Analytics for an arbitrary collection of [scans] assumed to belong to
  /// an AT batch. Pure — the input is only read.
  factory AtBatchAnalytics.fromScans(Iterable<LocalScan> scans) {
    final all = scans.toList(growable: false);
    final graded = all
        .where((scan) => scan.result?.isGraded == true)
        .toList(growable: false);
    final analyzable =
        graded.where(_isAnalyzable).toList(growable: false);

    final rawScores = analyzable
        .map((scan) => scan.result!.rawScore)
        .toList(growable: false)
      ..sort();

    double? averageRawScore;
    int? highestRawScore;
    int? lowestRawScore;
    double? medianRawScore;
    double? averagePercentage;
    double? highestPercentage;
    double? lowestPercentage;
    double? medianPercentage;
    var unclassifiedCount = 0;
    final categoryDistribution = <AdmissionCategory, int>{};
    final scoreDistribution = <AtScoreBand, int>{};

    if (rawScores.isNotEmpty) {
      final n = rawScores.length;
      final sum = rawScores.fold<int>(0, (acc, s) => acc + s);
      averageRawScore = sum / n;
      lowestRawScore = rawScores.first;
      highestRawScore = rawScores.last;
      medianRawScore = n.isOdd
          ? rawScores[n ~/ 2].toDouble()
          : (rawScores[n ~/ 2 - 1] + rawScores[n ~/ 2]) / 2;

      // Percentages are ALWAYS rawScore / 72 * 100 — never
      // LocalScanResult.percentage. _atPercentage is monotonic in the
      // sorted raw scores, so this list is already sorted too.
      final percentages = rawScores
          .map(_atPercentage)
          .whereType<double>()
          .toList(growable: false);
      if (percentages.isNotEmpty) {
        final pn = percentages.length;
        averagePercentage =
            percentages.fold<double>(0, (acc, p) => acc + p) / pn;
        lowestPercentage = percentages.first;
        highestPercentage = percentages.last;
        medianPercentage = pn.isOdd
            ? percentages[pn ~/ 2]
            : (percentages[pn ~/ 2 - 1] + percentages[pn ~/ 2]) / 2;
      }

      for (final category in AdmissionCategory.values) {
        categoryDistribution[category] = 0;
      }
      for (final band in AtScoreBand.values) {
        scoreDistribution[band] = 0;
      }

      for (final rawScore in rawScores) {
        final category = admissionCategory(rawScore);
        if (category != null) {
          categoryDistribution[category] =
              categoryDistribution[category]! + 1;
        } else if (rawScore >= AtScoreBand.unclassified.minRawScore &&
            rawScore <= AtScoreBand.unclassified.maxRawScore) {
          unclassifiedCount += 1;
        }
        final band = AtScoreBand.forRawScore(rawScore);
        if (band != null) {
          scoreDistribution[band] = scoreDistribution[band]! + 1;
        }
      }
    }

    return AtBatchAnalytics._(
      totalExaminees: all.length,
      gradedExaminees: graded.length,
      analyzableExaminees: analyzable.length,
      excludedGradedCount: graded.length - analyzable.length,
      averageRawScore: averageRawScore,
      highestRawScore: highestRawScore,
      lowestRawScore: lowestRawScore,
      medianRawScore: medianRawScore,
      averagePercentage: averagePercentage,
      highestPercentage: highestPercentage,
      lowestPercentage: lowestPercentage,
      medianPercentage: medianPercentage,
      unclassifiedCount: unclassifiedCount,
      categoryDistribution: categoryDistribution,
      scoreDistribution: scoreDistribution,
      rankedScorers: _rankScorers(analyzable),
    );
  }

  // --- analyzable gate ---------------------------------------------

  /// A scan feeds the statistics only when it is graded **and** the answer
  /// key covered the whole 72-item sheet. No score is recomputed, clamped
  /// or repaired.
  static bool _isAnalyzable(LocalScan scan) {
    final result = scan.result;
    return result != null &&
        result.status == 'Graded' &&
        result.totalGraded == _atMaxRawScore &&
        result.totalItems == _atMaxRawScore;
  }

  // --- ranking ----------------------------------------------------

  static List<AtRankedScorer> _rankScorers(List<LocalScan> analyzable) {
    if (analyzable.isEmpty) return const [];

    final ordered = [...analyzable]..sort((a, b) {
        final byScore =
            b.result!.rawScore.compareTo(a.result!.rawScore); // desc
        if (byScore != 0) return byScore;
        final an = _examineeNumberOf(a) ?? '';
        final bn = _examineeNumberOf(b) ?? '';
        if (an.isEmpty != bn.isEmpty) return an.isEmpty ? 1 : -1; // blanks last
        final byNumber = an.compareTo(bn);
        if (byNumber != 0) return byNumber;
        return a.id.compareTo(b.id);
      });

    final result = <AtRankedScorer>[];
    var rank = 0;
    int? previousScore;
    for (final scan in ordered) {
      final rawScore = scan.result!.rawScore;
      if (rawScore != previousScore) {
        rank += 1; // dense: next distinct score -> next rank
        previousScore = rawScore;
      }
      result.add(
        AtRankedScorer(
          rank: rank,
          scanId: scan.id,
          rawScore: rawScore,
          percentage: _atPercentage(rawScore),
          category: admissionCategory(rawScore),
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
