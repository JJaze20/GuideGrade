import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/analytics/at_category_averages.dart';
import 'package:guidegrade/core/omr/at_categories.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

const _section = 'Answer Document';

final _key = AnswerKey(
  examCode: 'AT',
  correctChoices: {
    for (var n = 1; n <= 72; n++) AnswerKey.keyFor(_section, n): 'A',
  },
);

/// A graded 72-item sheet where only items of [right] categories are correct.
LocalScan _scan(
  Set<AtCategory> right, {
  String id = 's',
  String status = 'Graded',
  int totalGraded = 72,
}) => LocalScan(
  id: id,
  imageFileName: 'x.jpg',
  capturedAt: DateTime.utc(2026),
  decoded: OmrScanResult(
    examCode: 'AT',
    items: [
      for (var n = 1; n <= 72; n++)
        OmrItemResult(
          sectionName: _section,
          itemNumber: n,
          markedChoice: right.contains(officialAtCategories[n]) ? 'A' : 'B',
        ),
    ],
  ),
  result: LocalScanResult(
    rawScore: 10,
    totalGraded: totalGraded,
    totalItems: 72,
    percentage: 0,
    status: status,
    scannedAt: DateTime.utc(2026),
    processedByUid: 'u',
    processedByName: 'n',
  ),
);

void main() {
  test('averages each subtest across the analyzable examinees', () {
    final averages = computeAtCategoryAverages([
      _scan({AtCategory.vc}, id: 'a'), // VC 12/12, others 0
      _scan({AtCategory.vc, AtCategory.qr}, id: 'b'), // + QR 18/18
    ], _key)!;
    expect(averages.examineeCount, 2);
    expect(averages.of(AtCategory.vc).average, 12);
    expect(averages.of(AtCategory.vc).total, 12);
    expect(averages.of(AtCategory.vr).average, 0);
    expect(averages.of(AtCategory.vr).total, 24);
    expect(averages.of(AtCategory.fr).total, 18);
    expect(averages.of(AtCategory.qr).average, 9);
    expect(averages.of(AtCategory.qr).percentage, 50);
    expect(averages.byCategory.map((a) => a.category), AtCategory.values);
  });

  test('a category saved in the answer key is used over the official one', () {
    final key = AnswerKey(
      examCode: 'AT',
      correctChoices: _key.correctChoices,
      itemCategories: {AnswerKey.keyFor(_section, 2): 'VC'},
    );
    final averages = computeAtCategoryAverages([
      _scan({AtCategory.vc}),
    ], key)!;
    expect(averages.of(AtCategory.vc).total, 13);
    expect(averages.of(AtCategory.vr).total, 23);
  });

  test('ungraded and partly graded scans are left out, like every AT '
      'statistic', () {
    final averages = computeAtCategoryAverages([
      _scan({AtCategory.vc}, id: 'good'),
      _scan({AtCategory.qr}, id: 'ungraded', status: 'Ungraded'),
      _scan({AtCategory.fr}, id: 'partial', totalGraded: 10),
    ], _key)!;
    expect(averages.examineeCount, 1);
    expect(averages.of(AtCategory.qr).average, 0);
  });

  test('no answer key or nothing analyzable gives no averages', () {
    expect(
      computeAtCategoryAverages([
        _scan({AtCategory.vc}),
      ], null),
      isNull,
    );
    expect(computeAtCategoryAverages(const [], _key), isNull);
    expect(
      computeAtCategoryAverages([_scan({}, status: 'Ungraded')], _key),
      isNull,
    );
  });
}
