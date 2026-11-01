// Admission Test scaled scores and School Ability Index (SAI). Pure: no
// Flutter, no I/O, no clock -- every date is passed in.
//
// The flow, for each of Total / Verbal / Nonverbal INDEPENDENTLY:
//   raw score --(Table 10)--> scaled score --(Table 23 or 24)--> SAI
//
// The tables are the Guidance Council's verified workbooks, copied verbatim
// into at_reference_tables.dart. Nothing is estimated or interpolated.
//
// Which SAI table, and which month column, depends on the examinee's age on
// the DAY OF THE EXAM (never today):
//   * under 17          -> no table (SAI not available)
//   * 17 years          -> Table 23, column by completed months
//   * 18 years          -> Table 24, column by completed months
//   * 19 years and over -> Table 24, always the 9-11 months column
// Completed months follow calendar-month anniversaries. When the birth day
// does not exist in a month (born on the 31st, or Feb 29) the anniversary is
// the last day of that month.

import 'at_categories.dart';
import 'at_reference_tables.dart';

/// Raw scores a complete Admission Test key must produce: Verbal 36 items and
/// Nonverbal 36 items (VC 12 + VR 24, FR 18 + QR 18), 72 in all.
const int atVerbalItems = 36;
const int atNonverbalItems = 36;
const int atTotalItems = atVerbalItems + atNonverbalItems;

/// The SAI of a raw score of 0. Table 10 starts at raw 1 (so a raw score of 0
/// has no scaled score), and the SAI tables' bottom row is 50 ("BELOW ..."),
/// which is also what raw 1 gives in every column.
const int atSaiFloor = 50;

/// The youngest age the SAI tables cover.
const int atSaiMinimumAge = 17;

/// Table 10 for one category, or null when [raw] has no entry (0, negative or
/// above the category's maximum).
int? atScaledScore(AtScoreCategory category, int raw) => switch (category) {
  AtScoreCategory.total => atTotalScaledScores[raw],
  AtScoreCategory.verbal => atVerbalScaledScores[raw],
  AtScoreCategory.nonverbal => atNonverbalScaledScores[raw],
};

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// [d] moved forward by [months], keeping the day of the month, or the last
/// day of that month when it has no such day.
DateTime _addMonths(DateTime d, int months) {
  final total = d.year * 12 + (d.month - 1) + months;
  final year = total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, d.day < lastDay ? d.day : lastDay);
}

/// Whole calendar months from [birthDate] to [examDate], or null when the
/// birth date is after the exam date. Only the calendar day counts.
///
/// February 5 -> October 4 is 7, -> October 5 is 8, -> November 1 is 8.
int? completedMonthsBetween(DateTime birthDate, DateTime examDate) {
  final b = _dateOnly(birthDate);
  final e = _dateOnly(examDate);
  if (b.isAfter(e)) return null;
  var months = (e.year - b.year) * 12 + (e.month - b.month);
  if (_addMonths(b, months).isAfter(e)) months--;
  return months;
}

/// An age as completed years plus the completed months since the last
/// birthday (0-11).
class AtAge {
  const AtAge(this.years, this.months);
  final int years;
  final int months;

  @override
  String toString() => '$years years $months months';
}

/// The age on [examDate], or null when [birthDate] is after it.
AtAge? atAgeOn(DateTime birthDate, DateTime examDate) {
  final months = completedMonthsBetween(birthDate, examDate);
  return months == null ? null : AtAge(months ~/ 12, months % 12);
}

enum AtSaiTable { age17, age18 }

/// Which SAI table and which month column an age uses.
class AtSaiSelection {
  const AtSaiSelection(this.table, this.monthBracket);
  final AtSaiTable table;

  /// 0 = 0-2 months, 1 = 3-5, 2 = 6-8, 3 = 9-11.
  final int monthBracket;

  /// "0-2", "3-5", "6-8" or "9-11".
  String get monthLabel => const ['0-2', '3-5', '6-8', '9-11'][monthBracket];

  /// "Table 23" or "Table 24".
  String get tableLabel => table == AtSaiTable.age17 ? 'Table 23' : 'Table 24';
}

/// The table and month column for [age], or null for an age under 17.
AtSaiSelection? atSaiSelectionFor(AtAge age) {
  if (age.years < atSaiMinimumAge) return null;
  if (age.years == 17) return AtSaiSelection(AtSaiTable.age17, age.months ~/ 3);
  if (age.years == 18) return AtSaiSelection(AtSaiTable.age18, age.months ~/ 3);
  return const AtSaiSelection(AtSaiTable.age18, 3); // 19 and over: 9-11 months
}

/// The SAI for a scaled score, or null when no band covers it.
int? atSaiForScaled(
  AtSaiSelection selection,
  AtScoreCategory category,
  int scaled,
) {
  final table = selection.table == AtSaiTable.age17
      ? atSaiTable17
      : atSaiTable18;
  final bands = table[category.index][selection.monthBracket];
  for (final band in bands) {
    if (scaled >= band.lo && scaled <= band.hi) return band.sai;
  }
  return null;
}

/// Why an SAI is, or is not, available.
enum AtScoreStatus {
  /// Dates are valid and the age is covered: SAI values are filled in.
  ok,

  /// Birth date and/or exam date not entered yet.
  missingDates,

  /// The birth date is after the exam date.
  invalidDates,

  /// Younger than 17 on the exam date: neither SAI table covers the age.
  belowMinimumAge,

  /// The answer key does not split the sheet 36 Verbal / 36 Nonverbal, so the
  /// Verbal and Nonverbal raw scores cannot be trusted.
  incompleteKey,
}

/// One conversion line: raw -> scaled -> SAI for one category.
class AtScoreLine {
  const AtScoreLine({
    required this.category,
    required this.raw,
    required this.maxRaw,
    this.scaled,
    this.sai,
  });

  final AtScoreCategory category;
  final int raw;
  final int maxRaw;

  /// Null for a raw score of 0 (not in Table 10) or an incomplete key.
  final int? scaled;

  /// Null unless the profile's status is [AtScoreStatus.ok].
  final int? sai;
}

/// The full Admission Test result: three independent lines plus the age and
/// the table used. Recomputed from the raw scores and the two dates each time
/// it is shown; nothing here is stored.
class AtScoreProfile {
  const AtScoreProfile({
    required this.status,
    required this.total,
    required this.verbal,
    required this.nonverbal,
    this.age,
    this.selection,
  });

  final AtScoreStatus status;
  final AtScoreLine total;
  final AtScoreLine verbal;
  final AtScoreLine nonverbal;

  /// Age on the exam date; null while dates are missing or invalid.
  final AtAge? age;

  /// The table and month column used; null unless [status] is ok.
  final AtSaiSelection? selection;

  bool get hasSai => status == AtScoreStatus.ok;
}

/// Computes the profile from the per-category raw [scores] (the existing
/// [computeAtCategoryScores]) and the dates. A null [scores] (nothing graded)
/// has no profile, so this takes the non-null value.
AtScoreProfile computeAtScoreProfile(
  AtCategoryScores scores, {
  DateTime? birthDate,
  DateTime? examDate,
}) {
  final complete =
      scores.verbalTotal == atVerbalItems &&
      scores.nonVerbalTotal == atNonverbalItems;

  AtScoreLine line(AtScoreCategory category, int raw, int max) => AtScoreLine(
    category: category,
    raw: raw,
    maxRaw: max,
    scaled: complete ? atScaledScore(category, raw) : null,
  );

  final total = line(AtScoreCategory.total, scores.totalRight, atTotalItems);
  final verbal = line(
    AtScoreCategory.verbal,
    scores.verbalRight,
    atVerbalItems,
  );
  final nonverbal = line(
    AtScoreCategory.nonverbal,
    scores.nonVerbalRight,
    atNonverbalItems,
  );

  AtScoreProfile without(AtScoreStatus status, {AtAge? age}) => AtScoreProfile(
    status: status,
    total: total,
    verbal: verbal,
    nonverbal: nonverbal,
    age: age,
  );

  if (!complete) return without(AtScoreStatus.incompleteKey);
  if (birthDate == null || examDate == null) {
    return without(AtScoreStatus.missingDates);
  }
  final age = atAgeOn(birthDate, examDate);
  if (age == null) return without(AtScoreStatus.invalidDates);
  final selection = atSaiSelectionFor(age);
  if (selection == null) {
    return without(AtScoreStatus.belowMinimumAge, age: age);
  }

  AtScoreLine withSai(AtScoreLine l) {
    // Raw 0 has no Table 10 entry; its SAI is the floor (see atSaiFloor).
    final sai = l.raw == 0
        ? atSaiFloor
        : (l.scaled == null
              ? null
              : atSaiForScaled(selection, l.category, l.scaled!));
    return AtScoreLine(
      category: l.category,
      raw: l.raw,
      maxRaw: l.maxRaw,
      scaled: l.scaled,
      sai: sai,
    );
  }

  return AtScoreProfile(
    status: AtScoreStatus.ok,
    total: withSai(total),
    verbal: withSai(verbal),
    nonverbal: withSai(nonverbal),
    age: age,
    selection: selection,
  );
}
