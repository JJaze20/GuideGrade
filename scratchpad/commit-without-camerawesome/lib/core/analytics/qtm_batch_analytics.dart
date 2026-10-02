// Pure, dependency-free descriptive analytics for one QTM batch.
//
// This is a CORE helper: no Flutter, no Firebase, no Supabase, no file /
// SharedPreferences / network / BuildContext / AppState access. It reads
// the already-persisted models and computes numbers; it never mutates the
// source batch or its scans.
//
// The official QTM percentage and eligibility bands are NOT re-derived
// here — they come from [qtmPercentage] / [qtmEligibility] in
// lib/core/omr/qtm_result.dart. `LocalScanResult.percentage` is a legacy
// generic value and is deliberately never read.

import '../../models/local_batch.dart';
import '../omr/qtm_result.dart';

/// Fixed raw-score bands for [QtmBatchAnalytics.scoreDistribution]. Type-safe
/// keys rather than arbitrary strings. Bands 0–9 … 40–49 are width 10; the
/// final band is 50–60 (inclusive of the maximum 60).
enum QtmScoreBand {
  band0to9(0, 9, '0–9'),
  band10to19(10, 19, '10–19'),
  band20to29(20, 29, '20–29'),
  band30to39(30, 39, '30–39'),
  band40to49(40, 49, '40–49'),
  band50to60(50, 60, '50–60');

  const QtmScoreBand(this.minRawScore, this.maxRawScore, this.label);

  /// Inclusive lower bound of the band.
  final int minRawScore;

  /// Inclusive upper bound of the band.
  final int maxRawScore;

  /// Human-readable range, e.g. `"10–19"`.
  final String label;

  /// The band a raw score falls into, or `null` when the score is outside
  /// the valid `0..60` range (corrupt data — a real QTM raw score is
  /// always `0..60`).
  static QtmScoreBand? forRawScore(int rawScore) {
    for (final band in values) {
      if (rawScore >= band.minRawScore && rawScore <= band.maxRawScore) {
        return band;
      }
    }
    return null;
  }
}

/// One graded QTM examinee's position in the batch ranking. Immutable;
/// carries enough to identify the examinee and show the result without
/// recomputing anything.
class QtmRankedScorer {
  const QtmRankedScorer({
    required this.rank,
    required this.scanId,
    required this.rawScore,
    required this.percentage,
    required this.eligibility,
    this.examineeNumber,
    this.displayName,
  });

  /// Dense rank: highest raw score is `1`, tied raw scores share a rank,
  /// and the next distinct raw score gets the next integer (no gaps).
  final int rank;

  /// [LocalScan.id] — the non-personal technical id of the scan.
  final String scanId;

  /// Correct-answer count, `0..60` (`LocalScanResult.rawScore`).
  final int rawScore;

  /// Official QTM percentage, `rawScore / 60 * 100` via [qtmPercentage].
  /// Non-null for any raw score in `0..60`.
  final double? percentage;

  /// Official QTM eligibility band via [qtmEligibility]. Non-null for any
  /// raw score in `0..60`.
  final QtmEligibility? eligibility;

  /// [ExamineeInfo.examineeNumber] when a non-blank tag exists, else `null`
  /// (untagged, or OCR-suggested name with no number yet).
  final String? examineeNumber;

  /// [ExamineeInfo.displayName] when the scan carries an examinee, else
  /// `null`. May be `"Unnamed"` when an examinee object exists but is blank.
  final String? displayName;
}

/// Descriptive analytics for one QTM batch.
///
/// Only **graded** scans (`scan.result?.isGraded == true`) feed the
/// averages, min/max, median, distributions, ranking and top scorers. A
/// graded raw score of `0` is a valid data point and is included. Every
/// scan — graded or not — is counted in [totalExaminees].
class QtmBatchAnalytics {
  QtmBatchAnalytics._({
    required this.totalExaminees,
    required this.gradedExaminees,
    required this.averageRawScore,
    required this.averagePercentage,
    required this.highestRawScore,
    required this.lowestRawScore,
    required this.medianRawScore,
    required Map<QtmEligibility, int> eligibilityDistribution,
    required Map<QtmScoreBand, int> scoreDistribution,
    required List<QtmRankedScorer> rankedScorers,
  })  : eligibilityDistribution = Map.unmodifiable(eligibilityDistribution),
        scoreDistribution = Map.unmodifiable(scoreDistribution),
        rankedScorers = List.unmodifiable(rankedScorers);

  /// Every scan in the batch (graded and ungraded).
  final int totalExaminees;

  /// Scans where `scan.result?.isGraded == true`.
  final int gradedExaminees;

  /// `totalExaminees - gradedExaminees`.
  int get ungradedExaminees => totalExaminees - gradedExaminees;

  /// Mean raw score (`0..60`) over graded scans, or `null` when none are
  /// graded.
  final double? averageRawScore;

  /// Mean of the official `qtmPercentage(rawScore)` over graded scans, or
  /// `null` when none are graded. Never derived from
  /// `LocalScanResult.percentage`.
  final double? averagePercentage;

  /// Highest graded raw score, or `null` when none are graded.
  final int? highestRawScore;

  /// Lowest graded raw score, or `null` when none are graded.
  final int? lowestRawScore;

  /// Median graded raw score (mean of the two middle values for an even
  /// count), or `null` when none are graded.
  final double? medianRawScore;

  /// Count of graded scans per official [QtmEligibility] band. Contains all
  /// three keys (some possibly `0`) when there is ≥ 1 graded scan; an empty
  /// map for an empty / all-ungraded batch.
  final Map<QtmEligibility, int> eligibilityDistribution;

  /// Count of graded scans per fixed [QtmScoreBand]. Contains all six keys
  /// (some possibly `0`) when there is ≥ 1 graded scan; an empty map for an
  /// empty / all-ungraded batch.
  final Map<QtmScoreBand, int> scoreDistribution;

  /// Every graded examinee, dense-ranked, highest raw score first, with a
  /// deterministic tie order (raw score desc, then examinee number asc with
  /// blanks last, then scan id asc). Only the raw score affects [rank].
  final List<QtmRankedScorer> rankedScorers;

  /// The top scorers by dense rank, **including every tie at the cutoff**.
  ///
  /// `limit` is a number of distinct ranks: e.g. for raw scores
  /// `60, 59, 59, 58` (dense ranks `1, 2, 2, 3`), `topScorers(limit: 2)`
  /// returns the `60` and both `59`s. `limit <= 0` returns an empty list.
  List<QtmRankedScorer> topScorers({int limit = 5}) {
    if (limit <= 0 || rankedScorers.isEmpty) return const [];
    return List.unmodifiable(
      rankedScorers.where((scorer) => scorer.rank <= limit),
    );
  }

  /// Analytics for a QTM [batch]. Throws [ArgumentError] if the batch is not
  /// a QTM batch — a non-QTM batch is never silently analysed.
  factory QtmBatchAnalytics.fromBatch(LocalBatch batch) {
    if (batch.examCode != 'QTM') {
      throw ArgumentError('QtmBatchAnalytics requires a QTM batch');
    }
    return QtmBatchAnalytics.fromScans(batch.scans);
  }

  /// Analytics for an arbitrary collection of [scans] assumed to belong to
  /// a QTM batch. Pure — the input is only read.
  factory QtmBatchAnalytics.fromScans(Iterable<LocalScan> scans) {
    final all = scans.toList(growable: false);
    final graded = all
        .where((scan) => scan.result?.isGraded == true)
        .toList(growable: false);
    final rawScores = graded
        .map((scan) => scan.result!.rawScore)
        .toList(growable: false)
      ..sort();

    double? averageRawScore;
    double? averagePercentage;
    int? highestRawScore;
    int? lowestRawScore;
    double? medianRawScore;
    final eligibilityDistribution = <QtmEligibility, int>{};
    final scoreDistribution = <QtmScoreBand, int>{};

    if (rawScores.isNotEmpty) {
      final sum = rawScores.fold<int>(0, (acc, s) => acc + s);
      averageRawScore = sum / rawScores.length;

      final percentages = rawScores
          .map(qtmPercentage)
          .whereType<double>()
          .toList(growable: false);
      averagePercentage = percentages.isEmpty
          ? null
          : percentages.fold<double>(0, (acc, p) => acc + p) /
              percentages.length;

      lowestRawScore = rawScores.first;
      highestRawScore = rawScores.last;

      final n = rawScores.length;
      medianRawScore = n.isOdd
          ? rawScores[n ~/ 2].toDouble()
          : (rawScores[n ~/ 2 - 1] + rawScores[n ~/ 2]) / 2;

      for (final band in QtmEligibility.values) {
        eligibilityDistribution[band] = 0;
      }
      for (final band in QtmScoreBand.values) {
        scoreDistribution[band] = 0;
      }
      for (final rawScore in rawScores) {
        final eligibility = qtmEligibility(rawScore);
        if (eligibility != null) {
          eligibilityDistribution[eligibility] =
              eligibilityDistribution[eligibility]! + 1;
        }
        final band = QtmScoreBand.forRawScore(rawScore);
        if (band != null) {
          scoreDistribution[band] = scoreDistribution[band]! + 1;
        }
      }
    }

    return QtmBatchAnalytics._(
      totalExaminees: all.length,
      gradedExaminees: graded.length,
      averageRawScore: averageRawScore,
      averagePercentage: averagePercentage,
      highestRawScore: highestRawScore,
      lowestRawScore: lowestRawScore,
      medianRawScore: medianRawScore,
      eligibilityDistribution: eligibilityDistribution,
      scoreDistribution: scoreDistribution,
      rankedScorers: _rankScorers(graded),
    );
  }

  // --- ranking -----------------------------------------------------------

  static List<QtmRankedScorer> _rankScorers(List<LocalScan> graded) {
    if (graded.isEmpty) return const [];

    final ordered = [...graded]..sort((a, b) {
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

    final result = <QtmRankedScorer>[];
    var rank = 0;
    int? previousScore;
    for (final scan in ordered) {
      final rawScore = scan.result!.rawScore;
      if (rawScore != previousScore) {
        rank += 1; // dense: next distinct score -> next rank
        previousScore = rawScore;
      }
      result.add(
        QtmRankedScorer(
          rank: rank,
          scanId: scan.id,
          rawScore: rawScore,
          percentage: qtmPercentage(rawScore),
          eligibility: qtmEligibility(rawScore),
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
