import '../../../core/omr/admission_category.dart';
import 'guidance_web_results_service.dart';

class DashboardDistribution {
  DashboardDistribution(this.title, List<String> labels, List<int> counts)
    : labels = List.unmodifiable(labels),
      counts = List.unmodifiable(counts);
  final String title;
  final List<String> labels;
  final List<int> counts;
  int get total => counts.fold(0, (sum, count) => sum + count);
}

class GuidanceDashboardData {
  GuidanceDashboardData(
    Iterable<int> admission,
    Iterable<int> qtm,
    Iterable<int> tat,
  ) : charts = List.unmodifiable([
        DashboardDistribution('Admission Test', const [
          'A',
          'B',
          'C',
          'D',
        ], _admissionCounts(admission)),
        DashboardDistribution('QTM', const [
          '0–9',
          '10–19',
          '20–29',
          '30–39',
          '40–49',
          '50–60',
        ], _rangeCounts(qtm, 60, 10, 6)),
        DashboardDistribution('TAT', const [
          '0–19',
          '20–39',
          '40–59',
          '60–79',
          '80–99',
          '100–119',
          '120–139',
          '140–160',
        ], _rangeCounts(tat, 160, 20, 8)),
      ]);
  final List<DashboardDistribution> charts;

  static List<int> _admissionCounts(Iterable<int> scores) {
    final counts = List.filled(4, 0);
    for (final score in scores) {
      final category = admissionCategory(score);
      if (category != null) counts[category.index]++;
    }
    return counts;
  }

  static List<int> _rangeCounts(
    Iterable<int> scores,
    int maximum,
    int step,
    int bins,
  ) {
    final counts = List.filled(bins, 0);
    for (final score in scores) {
      if (score < 0 || score > maximum) continue;
      final index = score ~/ step;
      counts[index >= bins ? bins - 1 : index]++;
    }
    return counts;
  }
}

/// Session-only aggregate using the existing read-only Results service.
/// No images, answer keys, local persistence, or backend writes are requested.
class GuidanceWebDashboardService {
  GuidanceWebDashboardService({GuidanceWebResultsService? results})
    : _results = results ?? GuidanceWebResultsService();
  final GuidanceWebResultsService _results;

  Future<GuidanceDashboardData> load() async {
    final batches = await _results.loadBatches();
    final scores = <String, List<int>>{'AT': [], 'QTM': [], 'TAT': []};
    for (final batch in batches) {
      final destination = scores[batch.examCode];
      if (destination == null) continue;
      final results = await _results.loadResultsForBatch(batch);
      for (final scan in results.scans) {
        final result = scan.result;
        if (result == null ||
            !result.isGraded ||
            !results.linkedExamineeByScanId.containsKey(scan.id)) {
          continue;
        }
        // AT/QTM require a fully graded key, as in the existing analytics.
        if (batch.examCode == 'AT' &&
            (result.totalItems != 72 || result.totalGraded != 72)) {
          continue;
        }
        if (batch.examCode == 'QTM' &&
            (result.totalItems != 60 || result.totalGraded != 60)) {
          continue;
        }
        destination.add(result.rawScore);
      }
    }
    return GuidanceDashboardData(scores['AT']!, scores['QTM']!, scores['TAT']!);
  }
}
