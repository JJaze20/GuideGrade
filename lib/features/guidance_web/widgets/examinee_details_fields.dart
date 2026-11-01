import 'package:flutter/material.dart';

import '../../../models/local_batch.dart' show ExamineeInfo;

/// The applicant details the Guidance Council enters on the Web Console:
/// birth date, last school attended, gender and (for the Admission Test) the
/// exam date. Shared by the "Create Examinee Record from this Scan" dialog
/// and the examinee edit dialog so both validate and look the same.
///
/// Every field is optional. Birth date and exam date are what the Admission
/// Test SAI needs; school and gender are information only.
class ExamineeDetailsController extends ChangeNotifier {
  ExamineeDetailsController({
    DateTime? birthDate,
    DateTime? examDate,
    String? lastSchool,
    String? gender,
  }) : _birthDate = _dateOnly(birthDate),
       _examDate = _dateOnly(examDate),
       _gender = (gender ?? '').trim().isEmpty ? null : gender!.trim(),
       school = TextEditingController(text: lastSchool ?? '');

  static DateTime? _dateOnly(DateTime? d) =>
      d == null ? null : DateTime(d.year, d.month, d.day);

  DateTime? _birthDate;
  DateTime? _examDate;
  String? _gender;
  final TextEditingController school;

  DateTime? get birthDate => _birthDate;
  DateTime? get examDate => _examDate;
  String? get gender => _gender;

  set birthDate(DateTime? v) {
    _birthDate = _dateOnly(v);
    notifyListeners();
  }

  set examDate(DateTime? v) {
    _examDate = _dateOnly(v);
    notifyListeners();
  }

  set gender(String? v) {
    _gender = (v ?? '').trim().isEmpty ? null : v!.trim();
    notifyListeners();
  }

  String? get lastSchoolOrNull {
    final t = school.text.trim();
    return t.isEmpty ? null : t;
  }

  /// A message when the dates cannot be right, otherwise null. [now] is
  /// injectable for tests.
  String? validate({DateTime? now}) {
    final today = _dateOnly(now ?? DateTime.now())!;
    final exam = _examDate;
    if (exam != null && exam.isAfter(today)) {
      return 'The exam date can’t be in the future.';
    }
    return ExamineeInfo.validateBirthDate(_birthDate, exam ?? today, now: now);
  }

  @override
  void dispose() {
    school.dispose();
    super.dispose();
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

String formatDetailDate(DateTime d) =>
    '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// Genders offered in the dropdown. A value already stored that is not in
/// this list is still shown, so nothing is ever silently dropped.
const examineeGenderOptions = ['Male', 'Female'];

class ExamineeDetailsFields extends StatelessWidget {
  const ExamineeDetailsFields({
    super.key,
    required this.controller,
    this.showExamDate = false,
    this.examDateLabel = 'Exam date (Admission Test)',
    this.enabled = true,
  });

  final ExamineeDetailsController controller;

  /// Only for an Admission Test sitting; other exams do not need it.
  final bool showExamDate;
  final String examDateLabel;
  final bool enabled;

  Future<void> _pick(
    BuildContext context, {
    required DateTime? current,
    required ValueChanged<DateTime?> onPicked,
    DateTime? initialFallback,
  }) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? initialFallback ?? DateTime(now.year - 18),
      firstDate: DateTime(1900),
      lastDate: DateTime(now.year, now.month, now.day),
      helpText: 'Select date',
    );
    if (picked != null) onPicked(picked);
  }

  Widget _dateField(
    BuildContext context, {
    required Key fieldKey,
    required String label,
    required DateTime? value,
    required ValueChanged<DateTime?> onChanged,
    DateTime? initialFallback,
  }) {
    final text = value == null ? '' : formatDetailDate(value);
    return TextFormField(
      key: ValueKey('$fieldKey|$text'),
      initialValue: text,
      readOnly: true,
      enabled: enabled,
      onTap: enabled
          ? () => _pick(
              context,
              current: value,
              onPicked: onChanged,
              initialFallback: initialFallback,
            )
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: 'Select a date',
        suffixIcon: value == null
            ? const Icon(Icons.calendar_today_outlined, size: 18)
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 18),
                onPressed: enabled ? () => onChanged(null) : null,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final stored = controller.gender;
        final options = [
          ...examineeGenderOptions,
          if (stored != null && !examineeGenderOptions.contains(stored)) stored,
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _dateField(
              context,
              fieldKey: const Key('detailsBirthDate'),
              label: 'Birth date (optional)',
              value: controller.birthDate,
              onChanged: (d) => controller.birthDate = d,
            ),
            if (showExamDate) ...[
              const SizedBox(height: 10),
              _dateField(
                context,
                fieldKey: const Key('detailsExamDate'),
                label: examDateLabel,
                value: controller.examDate,
                onChanged: (d) => controller.examDate = d,
                initialFallback: DateTime.now(),
              ),
            ],
            const SizedBox(height: 10),
            TextFormField(
              key: const Key('detailsSchool'),
              controller: controller.school,
              enabled: enabled,
              decoration: const InputDecoration(
                labelText: 'Last school attended (optional)',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              key: const Key('detailsGender'),
              initialValue: stored,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Not specified'),
                ),
                for (final g in options)
                  DropdownMenuItem<String?>(value: g, child: Text(g)),
              ],
              onChanged: enabled ? (v) => controller.gender = v : null,
              decoration: const InputDecoration(labelText: 'Gender (optional)'),
            ),
          ],
        );
      },
    );
  }
}
