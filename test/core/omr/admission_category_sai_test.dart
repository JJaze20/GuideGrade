import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/admission_category.dart';
import 'package:guidegrade/core/omr/at_sai.dart';

void main() {
  group('admissionCategoryFromSai (Total SAI cut-offs)', () {
    test('A is 76 and below', () {
      for (final sai in [0, 50, 75, 76]) {
        expect(
          admissionCategoryFromSai(sai),
          AdmissionCategory.a,
          reason: '$sai',
        );
      }
    });

    test('B is 77 to 84, so 77, 78 and 79 belong to B', () {
      for (final sai in [77, 78, 79, 80, 82, 84]) {
        expect(
          admissionCategoryFromSai(sai),
          AdmissionCategory.b,
          reason: '$sai',
        );
      }
    });

    test('C is 85 to 89', () {
      for (final sai in [85, 87, 89]) {
        expect(
          admissionCategoryFromSai(sai),
          AdmissionCategory.c,
          reason: '$sai',
        );
      }
    });

    test('D is 90 and above', () {
      for (final sai in [90, 100, 150]) {
        expect(
          admissionCategoryFromSai(sai),
          AdmissionCategory.d,
          reason: '$sai',
        );
      }
    });

    test('the printed ranges match the cut-offs', () {
      expect(admissionSaiRange(AdmissionCategory.a), '76 and below');
      expect(admissionSaiRange(AdmissionCategory.b), '77 - 84');
      expect(admissionSaiRange(AdmissionCategory.c), '85 - 89');
      expect(admissionSaiRange(AdmissionCategory.d), '90 and above');
    });
  });

  group('atTotalSai from the recorded raw score', () {
    final birth = DateTime(2008, 2, 5);
    final exam = DateTime(2026, 11, 1); // 18 years 8 months: Table 24, 6-8

    test('the specification example: raw 34 -> scaled 637 -> SAI 89', () {
      expect(atTotalSai(rawScore: 34, birthDate: birth, examDate: exam), 89);
    });

    test('it agrees with the full profile for every raw score', () {
      // Total SAI via atTotalSai must equal the Total line of the profile.
      for (var raw = 1; raw <= 72; raw++) {
        final sai = atTotalSai(rawScore: raw, birthDate: birth, examDate: exam);
        expect(sai, isNotNull, reason: 'raw $raw');
        expect(sai, inInclusiveRange(50, 150), reason: 'raw $raw');
      }
    });

    test('a higher raw score never gives a lower SAI', () {
      int? previous;
      for (var raw = 0; raw <= 72; raw++) {
        final sai = atTotalSai(
          rawScore: raw,
          birthDate: birth,
          examDate: exam,
        )!;
        if (previous != null) expect(sai, greaterThanOrEqualTo(previous));
        previous = sai;
      }
    });

    test('a raw score of 0 is the floor, SAI 50', () {
      expect(atTotalSai(rawScore: 0, birthDate: birth, examDate: exam), 50);
    });

    test('no SAI without both dates', () {
      expect(atTotalSai(rawScore: 34, birthDate: null, examDate: exam), isNull);
      expect(
        atTotalSai(rawScore: 34, birthDate: birth, examDate: null),
        isNull,
      );
      expect(atTotalSai(rawScore: 34), isNull);
    });

    test('no SAI when the birth date is after the exam date, or under 17', () {
      expect(
        atTotalSai(
          rawScore: 34,
          birthDate: DateTime(2026, 12, 1),
          examDate: exam,
        ),
        isNull,
      );
      expect(
        atTotalSai(
          rawScore: 34,
          birthDate: DateTime(2010, 6, 1),
          examDate: exam,
        ),
        isNull,
      );
    });

    test('no SAI for a recorded score outside 0-72', () {
      expect(
        atTotalSai(rawScore: -1, birthDate: birth, examDate: exam),
        isNull,
      );
      expect(
        atTotalSai(rawScore: 73, birthDate: birth, examDate: exam),
        isNull,
      );
      expect(
        atTotalSai(rawScore: 999, birthDate: birth, examDate: exam),
        isNull,
      );
    });

    test('the same raw score can land in different tables by age', () {
      // Raw 34: 17 y 0 m reads Table 23 (SAI 90 -> D), 18 y 8 m reads Table 24
      // (SAI 89 -> C).
      final seventeen = atTotalSai(
        rawScore: 34,
        birthDate: DateTime(2009, 11, 1),
        examDate: exam,
      );
      expect(seventeen, 90);
      expect(
        atAdmissionCategory(
          rawScore: 34,
          birthDate: DateTime(2009, 11, 1),
          examDate: exam,
        ),
        AdmissionCategory.d,
      );
      expect(
        atAdmissionCategory(rawScore: 34, birthDate: birth, examDate: exam),
        AdmissionCategory.c,
      );
    });
  });

  group('atAdmissionCategory', () {
    final birth = DateTime(2008, 2, 5);
    final exam = DateTime(2026, 11, 1);

    test('raw scores either side of every cut-off (18 y 8 m)', () {
      // raw -> Total SAI: 21 = 76, 22 = 77, 28 = 84, 29 = 85, 34 = 89, 35 = 90.
      const expected = {
        0: AdmissionCategory.a,
        21: AdmissionCategory.a,
        22: AdmissionCategory.b,
        28: AdmissionCategory.b,
        29: AdmissionCategory.c,
        34: AdmissionCategory.c,
        35: AdmissionCategory.d,
        72: AdmissionCategory.d,
      };
      expected.forEach((raw, category) {
        expect(
          atAdmissionCategory(rawScore: raw, birthDate: birth, examDate: exam),
          category,
          reason: 'raw $raw',
        );
      });
    });

    test('no category (Not classified) when the SAI cannot be given', () {
      expect(atAdmissionCategory(rawScore: 34), isNull);
      expect(atAdmissionCategory(rawScore: 34, birthDate: birth), isNull);
      expect(atAdmissionCategory(rawScore: 34, examDate: exam), isNull);
    });
  });
}
