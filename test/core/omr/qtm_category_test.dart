import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/qtm_category.dart';

void main() {
  test('QTM category bands', () {
    expect(qtmCategory(0), QtmCategory.a);
    expect(qtmCategory(45), QtmCategory.a);
    expect(qtmCategory(46), isNull);
    expect(qtmCategory(47), isNull);
    expect(qtmCategory(48), QtmCategory.b);
    expect(qtmCategory(50), QtmCategory.b);
    expect(qtmCategory(51), QtmCategory.c);
    expect(qtmCategory(53), QtmCategory.c);
    expect(qtmCategory(54), QtmCategory.d);
    expect(qtmCategory(60), QtmCategory.d);
  });

  test('out of range is null', () {
    expect(qtmCategory(-1), isNull);
    expect(qtmCategory(61), isNull);
  });
}
