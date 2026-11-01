import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/at_sai.dart';

/// What to tell the reader about the Admission Test scaled scores and SAI,
/// or null when nothing needs saying. Pure, so it is tested without a widget.
///
/// [hasLinkedExaminee] is whether the scan is linked to an examinee record,
/// which is where the birth date lives.
String? atScoreNote(
  AtScoreProfile profile, {
  required bool hasLinkedExaminee,
  required bool hasBirthDate,
  required bool hasExamDate,
}) {
  switch (profile.status) {
    case AtScoreStatus.ok:
      return null;
    case AtScoreStatus.missingDates:
      if (!hasLinkedExaminee) {
        return 'Link this scan to an examinee record, then add the birth date '
            'and exam date to see the SAI.';
      }
      if (!hasBirthDate && !hasExamDate) {
        return 'Add the birth date and the exam date (Edit Examinee) to see '
            'the SAI.';
      }
      return hasBirthDate
          ? 'Add the exam date (Edit Examinee) to see the SAI.'
          : 'Add the birth date (Edit Examinee) to see the SAI.';
    case AtScoreStatus.invalidDates:
      return 'The birth date is after the exam date. Correct it in Edit '
          'Examinee.';
    case AtScoreStatus.belowMinimumAge:
      final age = profile.age!;
      return 'Age on the exam date is ${age.years} years ${age.months} '
          'months. The SAI tables start at age $atSaiMinimumAge, so no SAI is '
          'given.';
    case AtScoreStatus.incompleteKey:
      return 'The answer key does not have exactly $atVerbalItems Verbal and '
          '$atNonverbalItems Nonverbal items, so scaled scores and the SAI '
          'are not given.';
  }
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _date(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// Raw score, scaled score and SAI for Total, Verbal and Nonverbal, with the
/// age and table the SAI came from. Display only: every number comes from
/// [AtScoreProfile].
class AtScoreTable extends StatelessWidget {
  const AtScoreTable({
    super.key,
    required this.profile,
    required this.hasLinkedExaminee,
    this.birthDate,
    this.examDate,
  });

  final AtScoreProfile profile;
  final bool hasLinkedExaminee;
  final DateTime? birthDate;
  final DateTime? examDate;

  static const _labelStyleSize = 10.5;

  Widget _cell(
    String text, {
    bool header = false,
    bool bold = false,
    TextAlign align = TextAlign.left,
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Text(
      text,
      key: key,
      textAlign: align,
      style: header
          ? AppTextStyles.body(
              size: _labelStyleSize,
              weight: FontWeight.w800,
              color: AppColors.textGray,
            )
          : AppTextStyles.body(
              size: 12,
              weight: bold ? FontWeight.w800 : FontWeight.w600,
            ),
    ),
  );

  TableRow _row(String id, String label, AtScoreLine line) {
    String num(int? v) => v == null ? 'Not given' : '$v';
    return TableRow(
      children: [
        _cell(label),
        _cell(
          '${line.raw} / ${line.maxRaw}',
          align: TextAlign.center,
          key: ValueKey('atScore_${id}_raw'),
        ),
        _cell(
          num(line.scaled),
          align: TextAlign.center,
          key: ValueKey('atScore_${id}_scaled'),
        ),
        _cell(
          num(line.sai),
          bold: true,
          align: TextAlign.center,
          key: ValueKey('atScore_${id}_sai'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final note = atScoreNote(
      profile,
      hasLinkedExaminee: hasLinkedExaminee,
      hasBirthDate: birthDate != null,
      hasExamDate: examDate != null,
    );
    final selection = profile.selection;
    final age = profile.age;
    final rawZero = [
      profile.total,
      profile.verbal,
      profile.nonverbal,
    ].any((l) => l.raw == 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Table(
          key: const Key('atScoreTable'),
          columnWidths: const {
            0: FlexColumnWidth(1.6),
            1: FlexColumnWidth(1.1),
            2: FlexColumnWidth(1.1),
            3: FlexColumnWidth(1.6),
          },
          children: [
            TableRow(
              children: [
                _cell('', header: true),
                _cell('RAW SCORE', header: true, align: TextAlign.center),
                _cell('SCALED SCORE', header: true, align: TextAlign.center),
                _cell(
                  'SCHOOL ABILITY INDEX (SAI)',
                  header: true,
                  align: TextAlign.center,
                ),
              ],
            ),
            _row('total', 'Total', profile.total),
            _row('verbal', 'Verbal', profile.verbal),
            _row('nonverbal', 'Nonverbal', profile.nonverbal),
          ],
        ),
        if (selection != null && age != null) ...[
          const SizedBox(height: 8),
          Text(
            'Age on the exam date: ${age.years} years ${age.months} months · '
            '${selection.tableLabel}, ${selection.monthLabel} months',
            key: const Key('atScoreBasis'),
            style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
          ),
        ],
        if (profile.hasSai && (birthDate != null || examDate != null)) ...[
          const SizedBox(height: 2),
          Text(
            [
              if (birthDate != null) 'Born ${_date(birthDate!)}',
              if (examDate != null) 'Exam ${_date(examDate!)}',
            ].join(' · '),
            key: const Key('atScoreDates'),
            style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
          ),
        ],
        if (rawZero && profile.hasSai) ...[
          const SizedBox(height: 2),
          Text(
            'A raw score of 0 has no scaled score; its SAI is $atSaiFloor.',
            style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
          ),
        ],
        if (note != null) ...[
          const SizedBox(height: 8),
          Text(
            note,
            key: const Key('atScoreNote'),
            style: AppTextStyles.body(
              size: 11,
              weight: FontWeight.w600,
              color: AppColors.warmRedOrange,
            ),
          ),
        ],
      ],
    );
  }
}
