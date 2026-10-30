import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/at_categories.dart';
import 'package:guidegrade/core/omr/cluster_analysis.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/models/answer_key.dart';

ScoredItem item(int n, {required bool right, bool graded = true}) => ScoredItem(
  sectionName: 'S',
  itemNumber: n,
  markedChoice: right ? 'A' : 'B',
  isAmbiguous: false,
  correctChoice: graded ? 'A' : null,
);

void main() {
  test('QTM clusters cover items 1-60 exactly', () {
    expect(qtmClusterDefs.fold<int>(0, (a, d) => a + d.totalItems), 60);
    expect(qtmClusterDefs.last.label, 'Pre-Calculus & Calculus');
  });

  test('AT groups span their sub-clusters and total 72', () {
    final clusters = atClusterDefs.where((d) => !d.isGroup);
    expect(clusters.fold<int>(0, (a, d) => a + d.totalItems), 72);
    final verbal = atClusterDefs.first;
    expect(verbal.totalItems, 36);
    expect(atClusterDefs[3].totalItems, 36);
    // The four subtests are interleaved, so none is an item range.
    expect(atClusterDefs.every((d) => d.categories != null), isTrue);
    expect(atClusterDefs.every((d) => !d.displayLabel.contains('(')), isTrue);
    expect(qtmClusterDefs.first.displayLabel, 'Algebra & Functions (1–10)');
  });

  test('AT clusters count the items of each real subtest, not item ranges', () {
    // Every item of the official Verbal Comprehension subtest is right.
    final items = [
      for (var n = 1; n <= 72; n++)
        ScoredItem(
          sectionName: 'Answer Document',
          itemNumber: n,
          markedChoice: officialAtCategories[n] == AtCategory.vc ? 'A' : 'B',
          isAmbiguous: false,
          correctChoice: 'A',
          // (right when the item is Verbal Comprehension)
        ),
    ];
    final rows = {
      for (final r in computeClusterRows('AT', items)!) r.def.label: r,
    };
    expect(rows['Verbal Comprehension']!.right, 12);
    expect(rows['Verbal Comprehension']!.total, 12);
    expect(rows['Verbal Reasoning']!.right, 0);
    expect(rows['Verbal Reasoning']!.total, 24);
    expect(rows['Figural Reasoning']!.total, 18);
    expect(rows['Quantitative Reasoning']!.total, 18);
    expect(rows['Verbal']!.right, 12);
    expect(rows['Verbal']!.total, 36);
    expect(rows['Non-Verbal']!.right, 0);
  });

  test('AT clusters follow a category saved in the answer key', () {
    final key = AnswerKey(
      examCode: 'AT',
      correctChoices: const {},
      itemCategories: {AnswerKey.keyFor('Answer Document', 2): 'VC'},
    );
    final items = [
      for (var n = 1; n <= 72; n++)
        ScoredItem(
          sectionName: 'Answer Document',
          itemNumber: n,
          markedChoice: n == 2 ? 'A' : 'B',
          isAmbiguous: false,
          correctChoice: 'A',
          // (only item 2 is right)
        ),
    ];
    final rows = {
      for (final r in computeClusterRows('AT', items, key: key)!)
        r.def.label: r,
    };
    // Item 2 is Verbal Reasoning officially; the key re-files it to VC.
    expect(rows['Verbal Comprehension']!.right, 1);
    expect(rows['Verbal Comprehension']!.total, 13);
    expect(rows['Verbal Reasoning']!.total, 23);
  });

  test('rates each cluster against the batch average', () {
    // Algebra (1-10): 4 right; Word Problems (11-13): 3 right.
    final mine = [
      for (var i = 1; i <= 60; i++)
        item(i, right: i >= 11 && i <= 13 || i <= 4),
    ];
    final rows = computeClusterRows(
      'QTM',
      mine,
      averages: {
        'Algebra & Functions': 6.0,
        'Word Problems': 2.0,
        'Trigonometry': 0.0,
      },
    )!;
    expect(rows[0].right, 4);
    expect(rows[0].band, ClusterBand.below); // 4 < 6
    expect(rows[1].right, 3);
    expect(rows[1].band, ClusterBand.above); // 3 > 2
    expect(rows[4].band, ClusterBand.average); // 0 vs 0
  });

  test('within half an item of the average counts as Average', () {
    expect(clusterBandFor(5, 5.4), ClusterBand.average);
    expect(clusterBandFor(5, 5.6), ClusterBand.below);
    expect(clusterBandFor(6, 5.6), ClusterBand.average);
    expect(clusterBandFor(null, 5), ClusterBand.unrated);
    expect(clusterBandFor(5, null), ClusterBand.unrated);
  });

  test('computes the average right count per cluster across scans', () {
    final a = [
      for (var i = 1; i <= 60; i++) item(i, right: i <= 10),
    ]; // 10 in Algebra
    final b = [
      for (var i = 1; i <= 60; i++) item(i, right: i <= 4),
    ]; // 4 in Algebra
    final avgs = computeClusterAverages('QTM', [a, b]);
    expect(avgs['Algebra & Functions'], 7.0);
    expect(avgs['Word Problems'], 0.0);
  });

  test('ungraded scans are skipped in averages, not counted as zero', () {
    final graded = [for (var i = 1; i <= 60; i++) item(i, right: i <= 10)];
    final ungraded = [
      for (var i = 1; i <= 60; i++) item(i, right: false, graded: false),
    ];
    expect(
      computeClusterAverages('QTM', [graded, ungraded])['Algebra & Functions'],
      10.0,
    );
  });

  test('no answer key -> unrated, never zero', () {
    final rows = computeClusterRows('AT', [
      for (var i = 1; i <= 72; i++) item(i, right: false, graded: false),
    ])!;
    expect(
      rows.every((r) => r.right == null && r.band == ClusterBand.unrated),
      isTrue,
    );
  });

  test('TAT has no cluster analysis', () {
    expect(computeClusterRows('TAT', const []), isNull);
  });

  group('buildClusterInsights', () {
    List<ClusterRow> rows(List<(int right, double? avg)> spec) {
      final defs = qtmClusterDefs;
      return [
        for (var i = 0; i < spec.length; i++)
          ClusterRow(
            def: defs[i],
            total: defs[i].totalItems,
            right: spec[i].$1,
            average: spec[i].$2,
            band: clusterBandFor(spec[i].$1, spec[i].$2),
          ),
      ];
    }

    test('names strengths and concerns', () {
      // Algebra 10/10 (strong), Word Problems 0/3 (concern).
      final out = buildClusterInsights(rows([(10, 5.0), (0, 2.0)]));
      expect(out.first.kind, InsightKind.strength);
      expect(out.first.text, 'Shows aptitude in Algebra & Functions.');
      expect(out.last.kind, InsightKind.concern);
      expect(out.last.text, 'May need more support in Word Problems.');
    });

    test('all strong collapses to one sentence', () {
      final out = buildClusterInsights(rows([(10, 5.0), (3, 1.0)]));
      expect(out, hasLength(1));
      expect(out.single.text, 'Shows strong performance across all clusters.');
    });

    test('AT: both clusters of a group collapse to the group name', () {
      // VC 18/18 and VR 18/18 (Verbal); FR 2/18 and QR 2/18 (Non-Verbal).
      final defs = atClusterDefs;
      ClusterRow row(ClusterDef d, int right) => ClusterRow(
        def: d,
        total: d.totalItems,
        right: right,
        average: 9.0,
        band: clusterBandFor(right, 9.0),
      );
      final out = buildClusterInsights([
        row(defs[0], 36),
        row(defs[1], 18),
        row(defs[2], 18),
        row(defs[3], 4),
        row(defs[4], 2),
        row(defs[5], 2),
      ]);
      expect(out.first.text, 'Shows aptitude in Verbal.');
      expect(out.last.text, 'May need more support in Non-Verbal.');
    });

    test('nothing graded -> no insights', () {
      final r = [
        ClusterRow(
          def: qtmClusterDefs.first,
          total: 10,
          right: null,
          average: null,
          band: ClusterBand.unrated,
        ),
      ];
      expect(buildClusterInsights(r), isEmpty);
    });
  });
}
