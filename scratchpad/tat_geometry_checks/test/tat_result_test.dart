import 'package:flutter_test/flutter_test.dart';
import '../../../lib/core/omr/tat_result.dart';

void main() {
  group('tatPercentage — total / 160 * 100', () {
    test('0 -> 0.0', () {
      expect(tatPercentage(0), 0.0);
    });
    test('1 -> 0.625', () {
      expect(tatPercentage(1), closeTo(100 / 160, 1e-9));
    });
    test('47 -> 29.375 (< 30%)', () {
      expect(tatPercentage(47), closeTo(4700 / 160, 1e-9));
      expect(tatPercentage(47)! < 30, isTrue);
    });
    test('48 -> exactly 30.0 (the eligibility boundary)', () {
      expect(tatPercentage(48), 30.0);
    });
    test('80 -> exactly 50.0', () {
      expect(tatPercentage(80), 50.0);
    });
    test('100 -> exactly 62.5', () {
      expect(tatPercentage(100), 62.5);
    });
    test('160 -> exactly 100.0', () {
      expect(tatPercentage(160), 100.0);
    });
    test('invalid -1 -> null', () {
      expect(tatPercentage(-1), isNull);
    });
    test('invalid 161 -> null', () {
      expect(tatPercentage(161), isNull);
    });

    test('48 / 160 * 100 == 30.0%', () {
      expect(tatPercentage(48), 30.0);
      expect(48 * 100 / 160, 30.0);
    });

    test('every valid total 0..160 equals total * 100 / 160', () {
      for (var total = 0; total <= 160; total++) {
        expect(tatPercentage(total), closeTo(total * 100 / 160, 1e-9),
            reason: 'total $total');
      }
    });

    test('out-of-range values return null', () {
      for (final total in [-1000, -2, -1, 161, 200, 1000]) {
        expect(tatPercentage(total), isNull, reason: 'total $total');
      }
    });
  });

  group('tatEligibility — named cases', () {
    test('0 -> doesNotMeetRequirement', () {
      expect(tatEligibility(0), TatEligibility.doesNotMeetRequirement);
    });
    test('47 -> doesNotMeetRequirement', () {
      expect(tatEligibility(47), TatEligibility.doesNotMeetRequirement);
    });
    test('48 -> meetsRequirement (inclusive 30%)', () {
      expect(tatEligibility(48), TatEligibility.meetsRequirement);
    });
    test('49 -> meetsRequirement', () {
      expect(tatEligibility(49), TatEligibility.meetsRequirement);
    });
    test('159 -> meetsRequirement', () {
      expect(tatEligibility(159), TatEligibility.meetsRequirement);
    });
    test('160 -> meetsRequirement', () {
      expect(tatEligibility(160), TatEligibility.meetsRequirement);
    });
    test('invalid -1 -> null', () {
      expect(tatEligibility(-1), isNull);
    });
    test('invalid 161 -> null', () {
      expect(tatEligibility(161), isNull);
    });
  });

  group('tatEligibility — exhaustive sweep of every valid total 0..160', () {
    test('0..47 -> doesNotMeetRequirement', () {
      for (var total = 0; total <= 47; total++) {
        expect(tatEligibility(total), TatEligibility.doesNotMeetRequirement,
            reason: 'total $total');
      }
    });
    test('48..160 -> meetsRequirement', () {
      for (var total = 48; total <= 160; total++) {
        expect(tatEligibility(total), TatEligibility.meetsRequirement,
            reason: 'total $total');
      }
    });
    test('out-of-range values -> null', () {
      for (final total in [-1000, -2, -1, 161, 200, 1000]) {
        expect(tatEligibility(total), isNull, reason: 'total $total');
      }
    });
  });

  group('tatEligibility matches the official 30% percentage cut', () {
    test('for every valid total 0..160, eligibility == (percentage >= 30)', () {
      for (var total = 0; total <= 160; total++) {
        final pct = tatPercentage(total)!;
        final expected = pct >= 30
            ? TatEligibility.meetsRequirement
            : TatEligibility.doesNotMeetRequirement;
        expect(tatEligibility(total), expected,
            reason: 'total $total -> ${pct.toStringAsFixed(4)}%');
      }
    });
  });

  group('TatEligibility enum', () {
    test('has exactly the two outcomes in order', () {
      expect(TatEligibility.values, const [
        TatEligibility.meetsRequirement,
        TatEligibility.doesNotMeetRequirement,
      ]);
    });
  });
}
