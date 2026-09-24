import 'omr_scorer.dart';

/// Cluster analysis for the Admission Test (AT) and Quantitative Math Test
/// (QTM): groups a scan's scored items into named item ranges and rates each
/// range Below Average / Average / Above Average. Pure, no I/O.
///
/// Item numbers are the exam-wide numbers already stored on
/// [ScoredItem.itemNumber] (AT 1–72, QTM 1–60).

/// One row of the cluster table. [isGroup] rows (AT's "Verbal" and
/// "Non-Verbal") span the item ranges of the cluster rows beneath them.
class ClusterDef {
  final String label;
  final int fromItem;
  final int toItem;
  final bool isGroup;

  const ClusterDef(
    this.label,
    this.fromItem,
    this.toItem, {
    this.isGroup = false,
  });

  int get totalItems => toItem - fromItem + 1;
}

const List<ClusterDef> atClusterDefs = [
  ClusterDef('Verbal', 1, 36, isGroup: true),
  ClusterDef('Verbal Comprehension', 1, 18),
  ClusterDef('Verbal Reasoning', 19, 36),
  ClusterDef('Non-Verbal', 37, 72, isGroup: true),
  ClusterDef('Figural Reasoning', 37, 54),
  ClusterDef('Quantitative Reasoning', 55, 72),
];

const List<ClusterDef> qtmClusterDefs = [
  ClusterDef('Algebra & Functions', 1, 10),
  ClusterDef('Word Problems', 11, 13),
  ClusterDef('Advanced Algebra & Sequences', 14, 21),
  ClusterDef('Geometry & Analytic Geometry', 22, 34),
  ClusterDef('Trigonometry', 35, 43),
  ClusterDef('Probability & Statistics', 44, 51),
  ClusterDef('Pre-Calculus & Calculus', 52, 60),
];

/// Cluster definitions for [examCode], or null when the exam has no cluster
/// analysis (TAT, unknown codes).
List<ClusterDef>? clusterDefsFor(String examCode) => switch (examCode) {
  'AT' => atClusterDefs,
  'QTM' => qtmClusterDefs,
  _ => null,
};

enum ClusterBand { below, average, above, unrated }

/// A cluster counts as Average when the examinee's right count is within
/// this many items of the batch average for that cluster.
const double clusterAverageTolerance = 0.5;

/// Rates [right] against the batch [average] for the same cluster. Null
/// inputs (no answer key, or no batch data) are unrated, never below.
ClusterBand clusterBandFor(int? right, double? average) {
  if (right == null || average == null) return ClusterBand.unrated;
  final diff = right - average;
  if (diff.abs() < clusterAverageTolerance) return ClusterBand.average;
  return diff < 0 ? ClusterBand.below : ClusterBand.above;
}

class ClusterRow {
  final ClusterDef def;

  /// Items in the cluster's range.
  final int total;

  /// Correct items, or null when the exam has no answer key (ungraded).
  final int? right;

  /// Batch average of correct items for this cluster, or null when it could
  /// not be computed (no graded scans).
  final double? average;
  final ClusterBand band;

  const ClusterRow({
    required this.def,
    required this.total,
    required this.right,
    required this.average,
    required this.band,
  });
}

int? _rightIn(ClusterDef def, List<ScoredItem> items) {
  final graded = items.where(
    (i) =>
        i.itemNumber >= def.fromItem &&
        i.itemNumber <= def.toItem &&
        i.correctChoice != null,
  );
  if (graded.isEmpty) return null;
  return graded.where((i) => i.isCorrect == true).length;
}

/// Average right count per cluster label across [scans] (each a scan's
/// scored items). Ungraded scans (no answer key coverage in the cluster)
/// are skipped, never counted as zero. Empty map when nothing is graded.
Map<String, double> computeClusterAverages(
  String examCode,
  Iterable<List<ScoredItem>> scans,
) {
  final defs = clusterDefsFor(examCode);
  if (defs == null) return const {};
  final result = <String, double>{};
  for (final def in defs) {
    final counts = [
      for (final items in scans) ?_rightIn(def, items),
    ];
    if (counts.isNotEmpty) {
      result[def.label] = counts.reduce((a, b) => a + b) / counts.length;
    }
  }
  return result;
}

/// Builds the cluster table rows for [examCode] from [items], rated against
/// [averages] (from [computeClusterAverages]); null when the exam has no
/// cluster analysis.
List<ClusterRow>? computeClusterRows(
  String examCode,
  List<ScoredItem> items, {
  Map<String, double> averages = const {},
}) {
  final defs = clusterDefsFor(examCode);
  if (defs == null) return null;
  return [
    for (final def in defs)
      ClusterRow(
        def: def,
        total: def.totalItems,
        right: _rightIn(def, items),
        average: averages[def.label],
        band: clusterBandFor(_rightIn(def, items), averages[def.label]),
      ),
  ];
}

enum InsightKind { strength, concern, neutral }

class ClusterInsight {
  final InsightKind kind;
  final String text;
  const ClusterInsight(this.kind, this.text);
}

/// A cluster counts as a strength at or above this share of its items right
/// (as long as it is not below the batch average), and as a concern below
/// [clusterConcernFraction] or when below the batch average.
const double clusterStrengthFraction = 0.8;
const double clusterConcernFraction = 0.5;


/// Names for [picked] clusters, where every cluster of an AT group (Verbal /
/// Non-Verbal) being picked is reported as the group name instead.
List<String> _namesCollapsingGroups(
  List<ClusterRow> all,
  List<ClusterRow> picked,
) {
  final names = <String>[];
  final covered = <ClusterRow>{};
  for (final g in all.where((r) => r.def.isGroup)) {
    final children = [
      for (final r in all)
        if (!r.def.isGroup &&
            r.def.fromItem >= g.def.fromItem &&
            r.def.toItem <= g.def.toItem)
          r,
    ];
    if (children.length > 1 && children.every(picked.contains)) {
      names.add(g.def.label);
      covered.addAll(children);
    }
  }
  for (final r in picked) {
    if (!covered.contains(r)) names.add(r.def.label);
  }
  return names;
}

String _joinNames(List<String> names) {
  if (names.length <= 1) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Plain-language observations for one examinee's cluster [rows] (group rows
/// like AT's Verbal / Non-Verbal are ignored). Deterministic, rule-based: no
/// generated text beyond these templates. Empty when nothing is graded.
List<ClusterInsight> buildClusterInsights(List<ClusterRow> rows) {
  final rated = [
    for (final r in rows)
      if (!r.def.isGroup && r.right != null && r.total > 0) r,
  ];
  if (rated.isEmpty) return const [];
  double frac(ClusterRow r) => r.right! / r.total;

  final concerns = [
    for (final r in rated)
      if (r.band == ClusterBand.below || frac(r) < clusterConcernFraction) r,
  ]..sort((a, b) => frac(a).compareTo(frac(b)));
  final strengths = [
    for (final r in rated)
      if (!concerns.contains(r) &&
          (r.band == ClusterBand.above || frac(r) >= clusterStrengthFraction))
        r,
  ]..sort((a, b) => frac(b).compareTo(frac(a)));

  final out = <ClusterInsight>[];
  if (strengths.length == rated.length && rated.length > 1) {
    out.add(
      const ClusterInsight(
        InsightKind.strength,
        'Shows strong performance across all clusters.',
      ),
    );
  } else if (strengths.isNotEmpty) {
    final names = _namesCollapsingGroups(rows, strengths).take(3).toList();
    out.add(
      ClusterInsight(
        InsightKind.strength,
        'Shows aptitude in ${_joinNames(names)}.',
      ),
    );
  }
  if (concerns.isNotEmpty) {
    final names = _namesCollapsingGroups(rows, concerns).take(3).toList();
    out.add(
      ClusterInsight(
        InsightKind.concern,
        'May need more support in ${_joinNames(names)}.',
      ),
    );
  }
  if (out.isEmpty) {
    out.add(
      const ClusterInsight(
        InsightKind.neutral,
        'Performance is close to the batch average across clusters.',
      ),
    );
  }
  return out;
}
