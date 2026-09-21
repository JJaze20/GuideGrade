import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/tat_category.dart';

void main() {
  test('TAT category bands (out of 160)', () {
    expect(tatCategory(0), TatCategory.a);
    expect(tatCategory(121), TatCategory.a);
    expect(tatCategory(122), isNull);
    expect(tatCategory(127), isNull);
    expect(tatCategory(128), TatCategory.b);
    expect(tatCategory(135), TatCategory.b);
    expect(tatCategory(136), TatCategory.c);
    expect(tatCategory(143), TatCategory.c);
    expect(tatCategory(144), TatCategory.d);
    expect(tatCategory(160), TatCategory.d);
  });

  test('out of range is null', () {
    expect(tatCategory(-1), isNull);
    expect(tatCategory(161), isNull);
  });
}
