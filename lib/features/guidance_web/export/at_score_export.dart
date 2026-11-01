import '../../../core/omr/at_sai.dart';
import 'guidance_web_export_models.dart';

/// Turns an Admission Test [AtScoreProfile] into the plain, already formatted
/// values the PDF prints under "Scaled Score and School Ability Index (SAI)".
/// Pure: the PDF builder does no scoring or lookups of its own.
///
/// [formatDate] renders a date the way the rest of the export does.
ExportScaledScores buildExportScaledScores(
  AtScoreProfile profile, {
  DateTime? birthDate,
  DateTime? examDate,
  required String Function(DateTime) formatDate,
}) {
  String value(int? v) => v == null ? '-' : '$v';
  ExportScoreRow row(String label, AtScoreLine l) => ExportScoreRow(
    label: label,
    raw: '${l.raw} / ${l.maxRaw}',
    scaled: value(l.scaled),
    sai: value(l.sai),
  );

  final selection = profile.selection;
  final age = profile.age;
  final basis = (selection != null && age != null)
      ? 'Age on the exam date: ${age.years} years ${age.months} months - '
            '${selection.tableLabel}, ${selection.monthLabel} months'
      : null;

  final dates = [
    if (birthDate != null) 'Born ${formatDate(birthDate)}',
    if (examDate != null) 'Exam ${formatDate(examDate)}',
  ];

  final rawZero = [
    profile.total,
    profile.verbal,
    profile.nonverbal,
  ].any((l) => l.raw == 0);

  final String? note = switch (profile.status) {
    AtScoreStatus.ok =>
      rawZero
          ? 'A raw score of 0 has no scaled score; its SAI is $atSaiFloor.'
          : null,
    AtScoreStatus.missingDates =>
      birthDate == null && examDate == null
          ? 'SAI not given: the birth date and the exam date have not been '
                'entered.'
          : birthDate == null
          ? 'SAI not given: the birth date has not been entered.'
          : 'SAI not given: the exam date has not been entered.',
    AtScoreStatus.invalidDates =>
      'SAI not given: the birth date is after the exam date.',
    AtScoreStatus.belowMinimumAge =>
      'SAI not given: the age on the exam date is ${age!.years} years '
          '${age.months} months, and the SAI tables start at age '
          '$atSaiMinimumAge.',
    AtScoreStatus.incompleteKey =>
      'Scaled scores and SAI not given: the answer key does not have exactly '
          '$atVerbalItems Verbal and $atNonverbalItems Nonverbal items.',
  };

  return ExportScaledScores(
    rows: [
      row('Total', profile.total),
      row('Verbal', profile.verbal),
      row('Nonverbal', profile.nonverbal),
    ],
    basis: basis,
    dates: dates.isEmpty ? null : dates.join(' - '),
    note: note,
  );
}
