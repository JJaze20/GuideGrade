// Pure batch averages of the four Admission Test (OLSAT) subtests, for the
// Guidance Council's Analytics page. No Flutter, no I/O: it only reads the
// scans and the answer key it is given.
//
// Each examinee's per-subtest raw score comes from the existing
// [computeAtCategoryScores] (the same one the Guidance App's View Scan and
// the web Result Summary use), so every screen agrees. Only scans that
// [AtBatchAnalytics.isAnalyzable] accepts feed the averages -- the exact
// records behind the rest of the AT statistics.

import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../omr/at_categories.dart';
import '../omr/omr_scorer.dart';
import 'at_batch_analytics.dart';

/// Average raw score of one subtest: [average] right answers out of [total]
/// items, over [AtCategoryAverages.examineeCount] examinees.
class AtCategoryAverage {
  final AtCategory category;
  final double average;
  final int total;
  const AtCategoryAverage(this.category, this.average, this.total);

  /// Average as a share of the subtest's items, 0-100.
  double get percentage => total == 0 ? 0 : average * 100 / total;
}

class AtCategoryAverages {
  final int examineeCount;
  final List<AtCategoryAverage> byCategory;
  const AtCategoryAverages(this.examineeCount, this.byCategory);

  AtCategoryAverage of(AtCategory c) =>
      byCategory.firstWhere((a) => a.category == c);
}

/// Averages per subtest across the analyzable [scans], or null when there is
/// no answer key or no analyzable scan (nothing to average).
AtCategoryAverages? computeAtCategoryAverages(
  Iterable<LocalScan> scans,
  AnswerKey? key,
) {
  if (key == null) return null;
  final sums = {for (final c in AtCategory.values) c: 0};
  final totals = {for (final c in AtCategory.values) c: 0};
  var count = 0;
  for (final scan in scans) {
    if (!AtBatchAnalytics.isAnalyzable(scan)) continue;
    final scores = computeAtCategoryScores(
      scoreOmrResult(scan.effectiveDecoded, key).items,
      key,
    );
    if (scores == null) continue;
    count++;
    for (final c in AtCategory.values) {
      sums[c] = sums[c]! + scores.scoreOf(c).right;
      totals[c] = scores.scoreOf(c).total;
    }
  }
  if (count == 0) return null;
  return AtCategoryAverages(count, [
    for (final c in AtCategory.values)
      AtCategoryAverage(c, sums[c]! / count, totals[c]!),
  ]);
}
