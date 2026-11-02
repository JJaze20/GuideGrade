import '../../../core/omr/admission_category.dart';
import '../../../core/omr/at_sai.dart';
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
  /// [admissionSai] is the Total SAI of each classified Admission Test
  /// examinee (the category comes from it: A 76 and below, B 77-84, C 85-89,
  /// D 90 and above); [admissionNotClassified] counts those whose SAI cannot
  /// be given yet (birth date or exam date missing, or under 17).
  GuidanceDashboardData(
    Iterable<int> admissionSai,
    Iterable<int> qtm,
    Iterable<int> tat, {
    int admissionNotClassified = 0,
  }) : charts = List.unmodifiable([
         DashboardDistribution(
           'Admission Test',
           [
             'A',
             'B',
             'C',
             'D',
             if (admissionNotClassified > 0) 'Not classified',
           ],
           [
             ..._admissionCounts(admissionSai),
             if (admissionNotClassified > 0) admissionNotClassified,
           ],
         ),
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

  static List<int> _admissionCounts(Iterable<int> totalSai) {
    final counts = List.filled(4, 0);
    for (final sai in totalSai) {
      counts[admissionCategoryFromSai(sai).index]++;
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
    var atNotClassified = 0;
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
        if (batch.examCode == 'AT') {
          // A recorded score outside 0-72 is invalid, never "not classified".
          if (result.rawScore < 0 || result.rawScore > 72) continue;
          // The Admission Test category comes from the Total SAI, which needs
          // the examinee's birth date and this sitting's exam date.
          final sai = atTotalSai(
            rawScore: result.rawScore,
            birthDate: results.linkedExamineeByScanId[scan.id]?.birthDate,
            examDate: results.examDateByScanId[scan.id],
          );
          if (sai == null) {
            atNotClassified++;
          } else {
            destination.add(sai);
          }
          continue;
        }
        destination.add(result.rawScore);
      }
    }
    return GuidanceDashboardData(
      scores['AT']!,
      scores['QTM']!,
      scores['TAT']!,
      admissionNotClassified: atNotClassified,
    );
  }
}
