import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/at_categories.dart';
import 'package:guidegrade/core/omr/at_reference_tables.dart';
import 'package:guidegrade/core/omr/at_sai.dart';

/// Per-category raw scores as the existing scorer produces them, using the
/// official item counts (VC 12, VR 24, FR 18, QR 18).
AtCategoryScores scores({
  required int vc,
  required int vr,
  required int fr,
  required int qr,
  int vcTotal = 12,
  int vrTotal = 24,
  int frTotal = 18,
  int qrTotal = 18,
}) => AtCategoryScores({
  AtCategory.vc: AtCategoryScore(AtCategory.vc, vc, vcTotal),
  AtCategory.vr: AtCategoryScore(AtCategory.vr, vr, vrTotal),
  AtCategory.fr: AtCategoryScore(AtCategory.fr, fr, frTotal),
  AtCategory.qr: AtCategoryScore(AtCategory.qr, qr, qrTotal),
});

/// Juan Dela Cruz: VC 6, VR 11, FR 7, QR 10 -> Verbal 17, Nonverbal 17,
/// Total 34.
AtCategoryScores juan() => scores(vc: 6, vr: 11, fr: 7, qr: 10);

void main() {
  group('Table 10 data', () {
    test('has Total raw 1-72, Verbal raw 1-36 and Nonverbal raw 1-36', () {
      expect(atTotalScaledScores.keys.toList()..sort(), [
        for (var i = 1; i <= 72; i++) i,
      ]);
      expect(atVerbalScaledScores.keys.toList()..sort(), [
        for (var i = 1; i <= 36; i++) i,
      ]);
      expect(atNonverbalScaledScores.keys.toList()..sort(), [
        for (var i = 1; i <= 36; i++) i,
      ]);
    });

    test('scaled scores strictly increase with the raw score', () {
      for (final map in [
        atTotalScaledScores,
        atVerbalScaledScores,
        atNonverbalScaledScores,
      ]) {
        final raws = map.keys.toList()..sort();
        for (var i = 1; i < raws.length; i++) {
          expect(map[raws[i]]!, greaterThan(map[raws[i - 1]]!));
        }
      }
    });

    test('the three conversions are independent of each other', () {
      // The same raw score 17 gives three different scaled scores.
      expect(atScaledScore(AtScoreCategory.total, 17), 595);
      expect(atScaledScore(AtScoreCategory.verbal, 17), 645);
      expect(atScaledScore(AtScoreCategory.nonverbal, 17), 630);
    });

    test('end points and the example from the specification', () {
      expect(atScaledScore(AtScoreCategory.total, 1), 482);
      expect(atScaledScore(AtScoreCategory.total, 72), 825);
      expect(atScaledScore(AtScoreCategory.total, 34), 637);
      expect(atScaledScore(AtScoreCategory.verbal, 36), 808);
      expect(atScaledScore(AtScoreCategory.nonverbal, 36), 793);
    });

    test('a raw score with no entry has no scaled score', () {
      expect(atScaledScore(AtScoreCategory.total, 0), isNull);
      expect(atScaledScore(AtScoreCategory.total, 73), isNull);
      expect(atScaledScore(AtScoreCategory.verbal, 37), isNull);
      expect(atScaledScore(AtScoreCategory.nonverbal, -1), isNull);
    });
  });

  group('completed months (calendar-month anniversaries)', () {
    final birth = DateTime(2008, 2, 5);

    test('February 5 to October 4 of the exam year is 7 months', () {
      final age = atAgeOn(birth, DateTime(2026, 10, 4))!;
      expect([age.years, age.months], [18, 7]);
    });

    test('February 5 to October 5 is 8 months', () {
      final age = atAgeOn(birth, DateTime(2026, 10, 5))!;
      expect([age.years, age.months], [18, 8]);
    });

    test('February 5 to November 1 is still 8 months', () {
      final age = atAgeOn(birth, DateTime(2026, 11, 1))!;
      expect([age.years, age.months], [18, 8]);
    });

    test('the birthday itself starts a new year at 0 months', () {
      expect(atAgeOn(birth, DateTime(2026, 2, 4))!.years, 17);
      final onBirthday = atAgeOn(birth, DateTime(2026, 2, 5))!;
      expect([onBirthday.years, onBirthday.months], [18, 0]);
    });

    test('a birth date after the exam date is invalid', () {
      expect(atAgeOn(DateTime(2026, 11, 2), DateTime(2026, 11, 1)), isNull);
    });

    test('the same day is 0 years 0 months', () {
      final age = atAgeOn(DateTime(2026, 11, 1), DateTime(2026, 11, 1))!;
      expect([age.years, age.months], [0, 0]);
    });

    test('only the calendar day counts, never the time of day', () {
      final late = DateTime(2026, 10, 5, 23, 59);
      final early = DateTime(2008, 2, 5, 0, 1);
      expect(completedMonthsBetween(early, late), 224); // 18 y 8 m
    });

    test('a month with no such day completes on its last day', () {
      // Born January 31: one month is complete on February 28 (2025).
      expect(
        completedMonthsBetween(DateTime(2024, 1, 31), DateTime(2025, 1, 31)),
        12,
      );
      expect(
        completedMonthsBetween(DateTime(2025, 1, 31), DateTime(2025, 2, 27)),
        0,
      );
      expect(
        completedMonthsBetween(DateTime(2025, 1, 31), DateTime(2025, 2, 28)),
        1,
      );
      expect(
        completedMonthsBetween(DateTime(2025, 1, 31), DateTime(2025, 3, 30)),
        1,
      );
      expect(
        completedMonthsBetween(DateTime(2025, 1, 31), DateTime(2025, 3, 31)),
        2,
      );
    });

    test(
      'born on February 29 turns a year older on February 28 in a common year',
      () {
        expect(
          completedMonthsBetween(DateTime(2008, 2, 29), DateTime(2009, 2, 27)),
          11,
        );
        expect(
          completedMonthsBetween(DateTime(2008, 2, 29), DateTime(2009, 2, 28)),
          12,
        );
      },
    );
  });

  group('which SAI table and month column', () {
    AtSaiSelection? pick(int years, int months) =>
        atSaiSelectionFor(AtAge(years, months));

    test('under 17 has no table', () {
      expect(pick(16, 11), isNull);
      expect(pick(0, 0), isNull);
      expect(pick(10, 6), isNull);
    });

    test('17 uses Table 23 with the month column', () {
      for (final (months, bracket) in [
        (0, 0),
        (2, 0),
        (3, 1),
        (5, 1),
        (6, 2),
        (8, 2),
        (9, 3),
        (11, 3),
      ]) {
        final s = pick(17, months)!;
        expect(
          [s.table, s.monthBracket],
          [AtSaiTable.age17, bracket],
          reason: '17y ${months}m',
        );
        expect(s.tableLabel, 'Table 23');
      }
    });

    test('18 uses Table 24 with the month column', () {
      for (final (months, bracket) in [
        (0, 0),
        (2, 0),
        (3, 1),
        (5, 1),
        (6, 2),
        (8, 2),
        (9, 3),
        (11, 3),
      ]) {
        final s = pick(18, months)!;
        expect(
          [s.table, s.monthBracket],
          [AtSaiTable.age18, bracket],
          reason: '18y ${months}m',
        );
        expect(s.tableLabel, 'Table 24');
      }
    });

    test(
      '19 and over always use Table 24, 9-11 months, whatever the months',
      () {
        for (final years in [19, 20, 25, 40, 99]) {
          for (final months in [0, 4, 8, 11]) {
            final s = pick(years, months)!;
            expect(
              [s.table, s.monthBracket],
              [AtSaiTable.age18, 3],
              reason: '${years}y ${months}m',
            );
            expect(s.monthLabel, '9-11');
          }
        }
      },
    );
  });

  group('the specification example (Juan Dela Cruz)', () {
    test(
      'born February 5 2008, exam November 1 2026: 18 y 8 m, Table 24 6-8',
      () {
        final p = computeAtScoreProfile(
          juan(),
          birthDate: DateTime(2008, 2, 5),
          examDate: DateTime(2026, 11, 1),
        );
        expect(p.status, AtScoreStatus.ok);
        expect([p.age!.years, p.age!.months], [18, 8]);
        expect(p.selection!.tableLabel, 'Table 24');
        expect(p.selection!.monthLabel, '6-8');

        expect([p.verbal.raw, p.nonverbal.raw, p.total.raw], [17, 17, 34]);
        expect(
          [p.total.maxRaw, p.verbal.maxRaw, p.nonverbal.maxRaw],
          [72, 36, 36],
        );
        expect(
          [p.total.scaled, p.verbal.scaled, p.nonverbal.scaled],
          [637, 645, 630],
        );
        expect([p.total.sai, p.verbal.sai, p.nonverbal.sai], [89, 92, 89]);
        expect(p.hasSai, isTrue);
      },
    );

    test('the same scores read the 17-year-old table for a 17 year old', () {
      // Born Nov 1 2009, exam Nov 1 2026: 17 y 0 m -> Table 23, 0-2 months.
      final young = computeAtScoreProfile(
        juan(),
        birthDate: DateTime(2009, 11, 1),
        examDate: DateTime(2026, 11, 1),
      );
      expect(young.selection!.tableLabel, 'Table 23');
      expect(young.selection!.monthLabel, '0-2');
      expect(
        [young.total.sai, young.verbal.sai, young.nonverbal.sai],
        [90, 92, 90],
      );

      // 17 y 10 m -> Table 23, 9-11 months.
      final older = computeAtScoreProfile(
        juan(),
        birthDate: DateTime(2009, 1, 1),
        examDate: DateTime(2026, 11, 1),
      );
      expect(older.selection!.monthLabel, '9-11');
      expect(
        [older.total.sai, older.verbal.sai, older.nonverbal.sai],
        [89, 92, 89],
      );
    });

    test('an 18 year old with 0 months uses Table 24, 0-2', () {
      final p = computeAtScoreProfile(
        juan(),
        birthDate: DateTime(2008, 11, 1),
        examDate: DateTime(2026, 11, 1),
      );
      expect(p.selection!.tableLabel, 'Table 24');
      expect(p.selection!.monthLabel, '0-2');
      expect([p.total.sai, p.verbal.sai, p.nonverbal.sai], [89, 92, 89]);
    });

    test('a 19+ examinee always reads the 9-11 months column', () {
      final p = computeAtScoreProfile(
        juan(),
        birthDate: DateTime(2000, 6, 20),
        examDate: DateTime(2026, 11, 1),
      );
      expect(p.age!.years, 26);
      expect(p.selection!.tableLabel, 'Table 24');
      expect(p.selection!.monthLabel, '9-11');
      expect([p.total.sai, p.verbal.sai, p.nonverbal.sai], [89, 92, 89]);
    });

    test('the age uses the exam date, never today', () {
      // Same birth date, exam a year earlier: a 17 year old.
      final p = computeAtScoreProfile(
        juan(),
        birthDate: DateTime(2008, 2, 5),
        examDate: DateTime(2025, 11, 1),
      );
      expect([p.age!.years, p.age!.months], [17, 8]);
      expect(p.selection!.tableLabel, 'Table 23');
    });
  });

  group('raw score of 0', () {
    test('has no scaled score, and its SAI is 50, in all three categories', () {
      final p = computeAtScoreProfile(
        scores(vc: 0, vr: 0, fr: 0, qr: 0),
        birthDate: DateTime(2008, 2, 5),
        examDate: DateTime(2026, 11, 1),
      );
      expect(p.status, AtScoreStatus.ok);
      for (final line in [p.total, p.verbal, p.nonverbal]) {
        expect(line.raw, 0);
        expect(line.scaled, isNull);
        expect(line.sai, 50);
      }
    });

    test('one category at 0 does not affect the others', () {
      final p = computeAtScoreProfile(
        scores(vc: 0, vr: 0, fr: 7, qr: 10),
        birthDate: DateTime(2008, 2, 5),
        examDate: DateTime(2026, 11, 1),
      );
      expect(p.verbal.raw, 0);
      expect(p.verbal.scaled, isNull);
      expect(p.verbal.sai, 50);
      expect(p.nonverbal.scaled, 630);
      expect(p.nonverbal.sai, 89);
      expect(p.total.raw, 17);
      expect(p.total.scaled, 595);
    });

    test('raw 1 also gives 50 in every column of both tables', () {
      for (final table in [AtSaiTable.age17, AtSaiTable.age18]) {
        for (var bracket = 0; bracket < 4; bracket++) {
          for (final category in AtScoreCategory.values) {
            final scaled = atScaledScore(category, 1)!;
            final sai = atSaiForScaled(
              AtSaiSelection(table, bracket),
              category,
              scaled,
            );
            expect(sai, 50, reason: '$table $bracket $category');
          }
        }
      }
    });

    test('a perfect score reads the top of each table', () {
      final p = computeAtScoreProfile(
        scores(vc: 12, vr: 24, fr: 18, qr: 18),
        birthDate: DateTime(2008, 2, 5),
        examDate: DateTime(2026, 11, 1),
      );
      expect([p.total.raw, p.verbal.raw, p.nonverbal.raw], [72, 36, 36]);
      expect(
        [p.total.scaled, p.verbal.scaled, p.nonverbal.scaled],
        [825, 808, 793],
      );
      // Table 24, 6-8 months: Total "ABOVE 811" and Verbal "ABOVE 801" are 150,
      // but no Nonverbal raw score reaches "ABOVE 796": 793 is SAI 148.
      expect([p.total.sai, p.verbal.sai, p.nonverbal.sai], [150, 150, 148]);
    });
  });

  group('when the SAI cannot be given', () {
    test('missing dates: raw and scaled scores still show, SAI does not', () {
      for (final (birth, exam) in [
        (null, DateTime(2026, 11, 1)),
        (DateTime(2008, 2, 5), null),
        (null, null),
      ]) {
        final p = computeAtScoreProfile(
          juan(),
          birthDate: birth,
          examDate: exam,
        );
        expect(p.status, AtScoreStatus.missingDates);
        expect(p.hasSai, isFalse);
        expect(p.age, isNull);
        expect(
          [p.total.scaled, p.verbal.scaled, p.nonverbal.scaled],
          [637, 645, 630],
        );
        expect(
          [p.total.sai, p.verbal.sai, p.nonverbal.sai],
          [null, null, null],
        );
      }
    });

    test('a birth date after the exam date is flagged, not guessed', () {
      final p = computeAtScoreProfile(
        juan(),
        birthDate: DateTime(2026, 11, 2),
        examDate: DateTime(2026, 11, 1),
      );
      expect(p.status, AtScoreStatus.invalidDates);
      expect(p.total.sai, isNull);
    });

    test('an examinee under 17 gets scaled scores but no SAI', () {
      final p = computeAtScoreProfile(
        juan(),
        birthDate: DateTime(2010, 6, 1),
        examDate: DateTime(2026, 11, 1),
      );
      expect(p.status, AtScoreStatus.belowMinimumAge);
      expect(p.age!.years, 16);
      expect(p.total.scaled, 637);
      expect([p.total.sai, p.verbal.sai, p.nonverbal.sai], [null, null, null]);
      expect(p.selection, isNull);
    });

    test(
      'an answer key that is not 36 Verbal / 36 Nonverbal gives no conversions',
      () {
        final p = computeAtScoreProfile(
          scores(vc: 6, vr: 11, fr: 7, qr: 10, vrTotal: 30), // Verbal 42
          birthDate: DateTime(2008, 2, 5),
          examDate: DateTime(2026, 11, 1),
        );
        expect(p.status, AtScoreStatus.incompleteKey);
        expect(p.total.scaled, isNull);
        expect(p.verbal.scaled, isNull);
        expect(p.total.sai, isNull);
        // The raw scores are still reported as they are.
        expect(p.total.raw, 34);
      },
    );

    test('a key with items missing (partial) is incomplete too', () {
      final p = computeAtScoreProfile(
        scores(vc: 6, vr: 11, fr: 7, qr: 10, qrTotal: 10),
        birthDate: DateTime(2008, 2, 5),
        examDate: DateTime(2026, 11, 1),
      );
      expect(p.status, AtScoreStatus.incompleteKey);
    });
  });

  group('the SAI tables are complete and consistent', () {
    final rawsByCategory = {
      AtScoreCategory.total: [for (var i = 1; i <= 72; i++) i],
      AtScoreCategory.verbal: [for (var i = 1; i <= 36; i++) i],
      AtScoreCategory.nonverbal: [for (var i = 1; i <= 36; i++) i],
    };

    test(
      'every Table 10 scaled score maps to exactly one SAI in every column',
      () {
        for (final tableData in [atSaiTable17, atSaiTable18]) {
          expect(tableData, hasLength(3));
          for (final category in AtScoreCategory.values) {
            expect(tableData[category.index], hasLength(4));
            for (var bracket = 0; bracket < 4; bracket++) {
              final bands = tableData[category.index][bracket];
              expect(bands, hasLength(101)); // SAI 150 down to 50
              for (final raw in rawsByCategory[category]!) {
                final scaled = atScaledScore(category, raw)!;
                final hits = bands.where(
                  (b) => scaled >= b.lo && scaled <= b.hi,
                );
                expect(
                  hits,
                  hasLength(1),
                  reason: '$category bracket $bracket raw $raw ($scaled)',
                );
              }
            }
          }
        }
      },
    );

    test('a higher raw score never gives a lower SAI', () {
      for (final table in [AtSaiTable.age17, AtSaiTable.age18]) {
        for (var bracket = 0; bracket < 4; bracket++) {
          for (final category in AtScoreCategory.values) {
            int? previous;
            for (final raw in rawsByCategory[category]!) {
              final sai = atSaiForScaled(
                AtSaiSelection(table, bracket),
                category,
                atScaledScore(category, raw)!,
              )!;
              if (previous != null) {
                expect(
                  sai,
                  greaterThanOrEqualTo(previous),
                  reason: '$table $bracket $category raw $raw',
                );
              }
              previous = sai;
            }
          }
        }
      }
    });

    test('every SAI is within 50 and 150', () {
      for (final tableData in [atSaiTable17, atSaiTable18]) {
        for (final perCategory in tableData) {
          for (final bands in perCategory) {
            for (final band in bands) {
              expect(band.sai, inInclusiveRange(50, 150));
              expect(band.lo, lessThanOrEqualTo(band.hi));
            }
          }
        }
      }
    });
  });
}
