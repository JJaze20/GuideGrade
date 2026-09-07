import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/qtm_result.dart';

void main() {
  group('qtmPercentage — raw / 60 * 100', () {
    test('0 -> 0.0', () {
      expect(qtmPercentage(0), 0.0);
    });
    test('1 -> 1.666...', () {
      expect(qtmPercentage(1), closeTo(100 / 60, 1e-9));
    });
    test('14 -> 23.333... (< 25%)', () {
      expect(qtmPercentage(14), closeTo(1400 / 60, 1e-9));
      expect(qtmPercentage(14)! < 25, isTrue);
    });
    test('15 -> exactly 25.0 (lower "except BSCS" boundary)', () {
      expect(qtmPercentage(15), 25.0);
    });
    test('17 -> 28.333... (still in 25%–29%)', () {
      expect(qtmPercentage(17), closeTo(1700 / 60, 1e-9));
      final p = qtmPercentage(17)!;
      expect(p >= 25 && p < 30, isTrue);
    });
    test('18 -> exactly 30.0 (lower "including BSCS" boundary)', () {
      expect(qtmPercentage(18), 30.0);
    });
    test('30 -> exactly 50.0', () {
      expect(qtmPercentage(30), 50.0);
    });
    test('60 -> exactly 100.0', () {
      expect(qtmPercentage(60), 100.0);
    });

    test('exact boundary percentages: 15/60 == 25% and 18/60 == 30%', () {
      expect(qtmPercentage(15), 25.0);
      expect(qtmPercentage(18), 30.0);
    });

    test('every valid raw 0..60 equals raw * 100 / 60', () {
      for (var raw = 0; raw <= 60; raw++) {
        expect(qtmPercentage(raw), closeTo(raw * 100 / 60, 1e-9),
            reason: 'raw $raw');
      }
    });

    test('invalid raw scores return null', () {
      for (final raw in [-1000, -2, -1, 61, 62, 100, 1000]) {
        expect(qtmPercentage(raw), isNull, reason: 'raw $raw');
      }
    });
  });

  group('qtmEligibility — named cases', () {
    test('0 -> notEligible', () {
      expect(qtmEligibility(0), QtmEligibility.notEligible);
    });
    test('14 -> notEligible', () {
      expect(qtmEligibility(14), QtmEligibility.notEligible);
    });
    test('15 -> allCoursesExceptBscs (25%, inclusive)', () {
      expect(qtmEligibility(15), QtmEligibility.allCoursesExceptBscs);
    });
    test('17 -> allCoursesExceptBscs', () {
      expect(qtmEligibility(17), QtmEligibility.allCoursesExceptBscs);
    });
    test('18 -> allCoursesIncludingBscs (30%, inclusive)', () {
      expect(qtmEligibility(18), QtmEligibility.allCoursesIncludingBscs);
    });
    test('30 -> allCoursesIncludingBscs', () {
      expect(qtmEligibility(30), QtmEligibility.allCoursesIncludingBscs);
    });
    test('60 -> allCoursesIncludingBscs', () {
      expect(qtmEligibility(60), QtmEligibility.allCoursesIncludingBscs);
    });
    test('invalid -1 -> null', () {
      expect(qtmEligibility(-1), isNull);
    });
    test('invalid 61 -> null', () {
      expect(qtmEligibility(61), isNull);
    });
  });

  group('qtmEligibility — exhaustive sweep of every valid raw 0..60', () {
    test('0..14 -> notEligible', () {
      for (var raw = 0; raw <= 14; raw++) {
        expect(qtmEligibility(raw), QtmEligibility.notEligible,
            reason: 'raw $raw');
      }
    });
    test('15..17 -> allCoursesExceptBscs', () {
      for (var raw = 15; raw <= 17; raw++) {
        expect(qtmEligibility(raw), QtmEligibility.allCoursesExceptBscs,
            reason: 'raw $raw');
      }
    });
    test('18..60 -> allCoursesIncludingBscs', () {
      for (var raw = 18; raw <= 60; raw++) {
        expect(qtmEligibility(raw), QtmEligibility.allCoursesIncludingBscs,
            reason: 'raw $raw');
      }
    });
    test('out-of-range values -> null', () {
      for (final raw in [-1000, -2, -1, 61, 62, 100, 1000]) {
        expect(qtmEligibility(raw), isNull, reason: 'raw $raw');
      }
    });
  });

  group('qtmEligibility matches the official percentage bands', () {
    test('for every valid raw 0..60, the band derived from qtmPercentage '
        '(>=30 / >=25 / else) equals qtmEligibility', () {
      for (var raw = 0; raw <= 60; raw++) {
        final pct = qtmPercentage(raw)!;
        final fromPct = pct >= 30
            ? QtmEligibility.allCoursesIncludingBscs
            : pct >= 25
                ? QtmEligibility.allCoursesExceptBscs
                : QtmEligibility.notEligible;
        expect(qtmEligibility(raw), fromPct,
            reason: 'raw $raw -> ${pct.toStringAsFixed(4)}%');
      }
    });
  });

  group('QtmEligibility enum', () {
    test('has exactly the three outcomes in order', () {
      expect(QtmEligibility.values, const [
        QtmEligibility.allCoursesIncludingBscs,
        QtmEligibility.allCoursesExceptBscs,
        QtmEligibility.notEligible,
      ]);
    });
  });
}
