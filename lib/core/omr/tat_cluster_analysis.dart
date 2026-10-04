import 'cluster_analysis.dart';
import 'omr_scorer.dart';
import 'omr_templates.dart';

/// Questionnaire cluster map. Item numbers restart in each TAT test.
/// Shared by examinee Analytics and Export; official scoring is unchanged.
const tatClusterDefs = <(int, ClusterDef)>[
  (
    0,
    ClusterDef('Test 1: Core Learning Theories, Psychology & Pedagogy', 1, 15),
  ),
  (
    0,
    ClusterDef(
      'Test 1: Instructional Planning, Assessment & Classroom Management',
      16,
      30,
    ),
  ),
  (1, ClusterDef('Test 2: Learning Psychology & Instructional Methods', 1, 40)),
  (
    1,
    ClusterDef(
      'Test 2: Classroom Management, Assessment & Professional Ethics',
      41,
      80,
    ),
  ),
  (
    2,
    ClusterDef(
      'Test 3: Advanced Assessment Dynamics & Professional Practice',
      1,
      20,
    ),
  ),
];

int? _right((int, ClusterDef) cluster, List<ScoredItem> items) {
  final (sectionIndex, def) = cluster;
  final section = omrTemplates['TAT']!.sections[sectionIndex].name;
  final matched = items
      .where(
        (item) =>
            item.sectionName == section &&
            item.itemNumber >= def.fromItem &&
            item.itemNumber <= def.toItem,
      )
      .toList();
  // A partial/missing answer key or incomplete scan is unavailable, not zero.
  if (matched.length != def.totalItems ||
      matched.map((item) => item.itemNumber).toSet().length != def.totalItems ||
      matched.any((item) => item.correctChoice == null)) {
    return null;
  }
  return matched.where((item) => item.isCorrect == true).length;
}

Map<String, double> tatClusterAverages(Iterable<List<ScoredItem>> scans) {
  final snapshot = scans.toList();
  return {
    for (final cluster in tatClusterDefs)
      if ([for (final items in snapshot) ?_right(cluster, items)]
          case final counts when counts.isNotEmpty)
        cluster.$2.label: counts.reduce((a, b) => a + b) / counts.length,
  };
}

List<ClusterRow> tatClusterRows(
  List<ScoredItem> items, {
  Map<String, double> averages = const {},
}) => [
  for (final cluster in tatClusterDefs)
    ClusterRow(
      def: cluster.$2,
      total: cluster.$2.totalItems,
      right: _right(cluster, items),
      average: averages[cluster.$2.label],
      band: clusterBandFor(_right(cluster, items), averages[cluster.$2.label]),
    ),
];

const tatClusterScoringNote =
    'Cluster RIGHT and AVERAGE values count correct answers, not weighted points. '
    'TAT has 130 items and a maximum score of 160 points: '
    'Test 1 = right x 2 (60 points); Tests 2 and 3 = right - wrong '
    '(80 and 20 points), each floored at zero. Blank and ambiguous answers '
    'are not deducted. The score above is the recorded examination result.';
