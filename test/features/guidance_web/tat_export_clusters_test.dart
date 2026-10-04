import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/exam_score.dart';
import 'package:guidegrade/core/omr/omr_scorer.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/features/guidance_web/export/tat_export_clusters.dart';
import 'package:guidegrade/features/guidance_web/export/guidance_web_export_pdf.dart';
import 'package:guidegrade/features/guidance_web/export/guidance_web_export_models.dart';
import 'package:guidegrade/features/guidance_web/export/guidance_web_export_service.dart';

List<ScoredItem> answers({bool right = true, bool graded = true}) => [
  for (final section in omrTemplates['TAT']!.sections)
    for (var n = 1; n <= section.itemCount; n++)
      ScoredItem(
        sectionName: section.name,
        itemNumber: n,
        markedChoice: right ? 'A' : 'B',
        isAmbiguous: false,
        correctChoice: graded ? 'A' : null,
      ),
];

void main() {
  test(
    'TAT PDF renders all five cluster labels with scoring explanation',
    () async {
      final items = answers();
      final doc = ExportDocument(
        examinees: [
          ExportExamineeSection(
            examLabel: 'TAT',
            batchLabel: 'TAT-2026 - Teaching Aptitude Test',
            examineeId: 'TEST-ONLY',
            firstName: 'Sample',
            middleName: '-',
            lastName: 'Examinee',
            age: '-',
            scanDate: 'October 3, 2026',
            score: '160 / 160',
            percentage: '100.00%',
            clusterRows: tatClusterRows(
              items,
              averages: tatClusterAverages([items]),
            ),
            clusterNote: tatClusterScoringNote,
            categoryBands: exportCategoryBands('TAT'),
            categoryLetter: 'D',
          ),
        ],
      );
      final bytes = await buildExportPdf(
        doc,
        leftLogo: await File('assets/images/ndmu_logo.png').readAsBytes(),
        rightLogo: await File(
          'assets/images/guidance_council_logo.png',
        ).readAsBytes(),
      );
      expect(bytes.length, greaterThan(1000));
      final preview = Platform.environment['TAT_EXPORT_QA_PATH'];
      if (preview != null) await File(preview).writeAsBytes(bytes);
    },
  );
  test('five PDF clusters cover 130 items with isolated test numbering', () {
    final rows = tatClusterRows(answers());
    expect(rows.map((r) => r.total), [15, 15, 40, 40, 20]);
    expect(rows.map((r) => r.right), [15, 15, 40, 40, 20]);
    expect(rows.fold(0, (sum, r) => sum + r.total), 130);
    final score = computeExamScoreForCode(
      ScoredResult(examCode: 'TAT', items: answers()),
    )!;
    expect(
      [score.tatTest1Score, score.tatTest2Score, score.tatTest3Score],
      [60, 80, 20],
    );
    expect(score.rawScore, 160);
  });
  test('same item numbers in other tests cannot leak into a cluster', () {
    final items = answers()
        .where((i) => i.sectionName == omrTemplates['TAT']!.sections[1].name)
        .toList();
    expect(tatClusterRows(items).map((r) => r.right), [
      null,
      null,
      40,
      40,
      null,
    ]);
  });
  test('averages use batch correct counts and skip unavailable clusters', () {
    final averages = tatClusterAverages([
      answers(),
      answers(right: false),
      answers(graded: false),
    ]);
    expect(averages.values, [7.5, 7.5, 20, 20, 10]);
    expect(
      tatClusterRows(
        answers(),
        averages: averages,
      ).every((r) => r.right! > r.average!),
      isTrue,
    );
  });
  test(
    'incomplete and duplicate item data are unavailable, not false zero',
    () {
      final items = answers();
      items.removeAt(0);
      expect(tatClusterRows(items).first.right, isNull);
      items.insert(0, items.first);
      expect(tatClusterRows(items).first.right, isNull);
      expect(
        tatClusterRows(answers(right: false)).every((r) => r.right == 0),
        isTrue,
      );
    },
  );
  test('existing right-minus-wrong floors tests at zero', () {
    final score = computeExamScoreForCode(
      ScoredResult(examCode: 'TAT', items: answers(right: false)),
    )!;
    expect(score.rawScore, 0);
    expect(score.totalItems, 130);
  });
}
