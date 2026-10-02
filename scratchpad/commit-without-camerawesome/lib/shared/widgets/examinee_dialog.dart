import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/services/batch_repository.dart';
import '../../models/local_batch.dart';
import 'form_field_decoration.dart';
import 'name_crop_strip.dart';

/// Result of [showExamineeDialog]: [ExamineeDialogResult.cleared] is true
/// when the user chose "Remove", otherwise [info] holds the entered values.
class ExamineeDialogResult {
  final ExamineeInfo? info;
  final bool cleared;

  const ExamineeDialogResult({this.info, this.cleared = false});
}

/// Per-sheet student entry — last name, first name, middle name, examinee
/// number, plus the optional details birth date, age and last school
/// attended. When [batchId]/[scan]/[repository] are all given, the sheet's own
/// cropped handwriting (see [NameCropStrip]) is shown above the fields so staff
/// can read it while typing — this app runs no automatic handwriting
/// recognition, so nothing here is ever pre-filled from the scan itself.
/// Last/First Name and every detail may be left blank (a counselor may not
/// know them yet); Examinee Number is still required.
///
/// Age: with a birth date, the age is DERIVED (shown read-only) as of the
/// exam date — [examDate], the scan's capture date, falling back to today —
/// so the two can never disagree. With no birth date, an age can be typed in
/// directly; picking a birth date later replaces it.
///
/// [onReviewAnswers], when given, adds a separate "Answers" section with a
/// button that opens the scan for answer correction on top of this dialog,
/// leaving anything typed here untouched. Answer corrections are never part
/// of this form's Save.
///
/// Returns null if dismissed without saving.
Future<ExamineeDialogResult?> showExamineeDialog(
  BuildContext context, {
  ExamineeInfo? initial,
  String? sheetLabel,
  Set<String> otherNumbers = const {},
  String? batchId,
  LocalScan? scan,
  BatchRepository? repository,
  DateTime? examDate,
  VoidCallback? onReviewAnswers,
}) {
  return showDialog<ExamineeDialogResult>(
    context: context,
    builder: (ctx) => _ExamineeDialog(
      initial: initial,
      sheetLabel: sheetLabel,
      otherNumbers: otherNumbers,
      batchId: batchId,
      scan: scan,
      repository: repository,
      examDate: examDate ?? ExamineeInfo.examDateFor(scanCapturedAt: scan?.capturedAt),
      onReviewAnswers: onReviewAnswers,
    ),
  );
}

class _ExamineeDialog extends StatefulWidget {
  final ExamineeInfo? initial;
  final String? sheetLabel;
  final Set<String> otherNumbers;
  final String? batchId;
  final LocalScan? scan;
  final BatchRepository? repository;
  final DateTime examDate;
  final VoidCallback? onReviewAnswers;

  const _ExamineeDialog({
    required this.initial,
    required this.sheetLabel,
    required this.otherNumbers,
    required this.batchId,
    required this.scan,
    required this.repository,
    required this.examDate,
    required this.onReviewAnswers,
  });

  @override
  State<_ExamineeDialog> createState() => _ExamineeDialogState();
}

class _ExamineeDialogState extends State<_ExamineeDialog> {
  late final _lastCtrl = TextEditingController(text: widget.initial?.lastName ?? '');
  late final _firstCtrl = TextEditingController(text: widget.initial?.firstName ?? '');
  late final _middleCtrl = TextEditingController(text: widget.initial?.middleName ?? '');
  late final _numberCtrl = TextEditingController(text: widget.initial?.examineeNumber ?? '');
  late final _schoolCtrl = TextEditingController(text: widget.initial?.lastSchool ?? '');
  late final _ageCtrl = TextEditingController(text: widget.initial?.manualAge?.toString() ?? '');
  final _formKey = GlobalKey<FormState>();

  late DateTime? _birthDate = widget.initial?.birthDate;
  String? _birthError;

  @override
  void dispose() {
    for (final c in [_lastCtrl, _firstCtrl, _middleCtrl, _numberCtrl, _schoolCtrl, _ageCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  int? get _derivedAge => _birthDate == null ? null : ExamineeInfo.ageFromBirthDate(_birthDate!, widget.examDate);

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 15, 1, 1),
      firstDate: DateTime(now.year - ExamineeInfo.maxAge - 1, 1, 1),
      lastDate: now, // a future birth date can not be picked at all
      helpText: 'Birth date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _birthDate = picked;
      _birthError = ExamineeInfo.validateBirthDate(picked, widget.examDate);
      _ageCtrl.clear(); // the age is now derived; never keep a second value
    });
  }

  void _clearBirthDate() => setState(() {
        _birthDate = null;
        _birthError = null;
      });

  void _save() {
    final birthError = ExamineeInfo.validateBirthDate(_birthDate, widget.examDate);
    setState(() => _birthError = birthError);
    if (!_formKey.currentState!.validate() || birthError != null) return;
    final typedAge = int.tryParse(_ageCtrl.text.trim());
    Navigator.pop(
      context,
      ExamineeDialogResult(
        info: ExamineeInfo(
          firstName: _firstCtrl.text.trim(),
          lastName: _lastCtrl.text.trim(),
          middleName: _middleCtrl.text.trim(),
          examineeNumber: _numberCtrl.text.trim(),
          birthDate: _birthDate,
          // Only kept when there is no birth date to derive it from.
          manualAge: _birthDate == null ? typedAge : null,
          lastSchool: _schoolCtrl.text.trim(),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(
          text,
          style: AppTextStyles.body(size: 10.5, color: AppColors.textGray, weight: FontWeight.w800),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final initial = widget.initial;
    final hasCrop = widget.batchId != null && widget.scan != null && widget.repository != null;
    return AlertDialog(
      title: Text(
        widget.sheetLabel == null ? 'Student for this sheet' : 'Student — ${widget.sheetLabel}',
        style: AppTextStyles.heading(size: 14),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hasCrop) ...[
                  Text(
                    'Handwritten name on this sheet',
                    style: AppTextStyles.body(size: 10.5, color: AppColors.textGray, weight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  NameCropStrip(
                    batchId: widget.batchId!,
                    scan: widget.scan!,
                    repository: widget.repository!,
                    height: 94,
                  ),
                  const SizedBox(height: 12),
                ],
                _sectionLabel('STUDENT'),
                TextFormField(
                  key: const Key('examineeDialog.lastName'),
                  controller: _lastCtrl,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: FormFieldStyle.decoration(label: 'Last name (optional)'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('examineeDialog.firstName'),
                  controller: _firstCtrl,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: FormFieldStyle.decoration(label: 'First name (optional)'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('examineeDialog.middleName'),
                  controller: _middleCtrl,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: FormFieldStyle.decoration(label: 'Middle name (optional)'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('examineeDialog.examineeNumber'),
                  controller: _numberCtrl,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.next,
                  decoration: FormFieldStyle.decoration(label: 'Examinee number', required: true),
                  validator: (v) {
                    final t = v?.trim() ?? '';
                    if (t.isEmpty) return 'Required';
                    if (widget.otherNumbers.contains(t)) {
                      return 'Already used by another sheet in this batch';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                _sectionLabel('DETAILS (all optional)'),
                _birthDateField(),
                const SizedBox(height: 12),
                _ageField(),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('examineeDialog.lastSchool'),
                  controller: _schoolCtrl,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.done,
                  decoration: FormFieldStyle.decoration(label: 'Last school attended (optional)'),
                ),
                if (widget.onReviewAnswers != null) ...[
                  const SizedBox(height: 16),
                  const Divider(height: 1),
                  const SizedBox(height: 12),
                  _sectionLabel('ANSWERS'),
                  Text(
                    'Fix an answer the scanner misread. This is separate from the student details above.',
                    style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('examineeDialog.reviewAnswers'),
                    onPressed: widget.onReviewAnswers,
                    icon: const Icon(Icons.fact_check_outlined, size: 16),
                    label: const Text('Review & correct answers'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.primaryGreen,
                      side: const BorderSide(color: AppColors.primaryGreen, width: 1.2),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        if (initial != null && !initial.isEmpty)
          TextButton(
            onPressed: () => Navigator.pop(context, const ExamineeDialogResult(cleared: true)),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF991B1B)),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: _save,
          style: TextButton.styleFrom(foregroundColor: AppColors.primaryGreen),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _birthDateField() {
    final text = _birthDate == null ? '' : ExamineeInfo.birthDateToText(_birthDate!);
    return InkWell(
      key: const Key('examineeDialog.birthDate'),
      borderRadius: BorderRadius.circular(10),
      onTap: _pickBirthDate,
      child: InputDecorator(
        decoration: FormFieldStyle.decoration(
          label: 'Birth date (optional)',
          hint: 'Tap to choose',
          helper: _birthError == null ? 'Age is worked out from this as of the exam date.' : null,
          suffixIcon: _birthDate == null
              ? const Icon(Icons.calendar_today_outlined, size: 18)
              : IconButton(
                  tooltip: 'Clear birth date',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: _clearBirthDate,
                ),
        ).copyWith(errorText: _birthError),
        isEmpty: text.isEmpty,
        child: Text(text, style: AppTextStyles.body(size: 13)),
      ),
    );
  }

  Widget _ageField() {
    if (_birthDate != null) {
      final age = _derivedAge;
      return InputDecorator(
        key: const Key('examineeDialog.ageDerived'),
        decoration: FormFieldStyle.disabled(
          label: 'Age at exam',
          helper: 'Worked out from the birth date. Clear the birth date to type an age instead.',
        ),
        child: Text(age == null ? '—' : '$age', style: AppTextStyles.body(size: 13)),
      );
    }
    return TextFormField(
      key: const Key('examineeDialog.age'),
      controller: _ageCtrl,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
      textInputAction: TextInputAction.next,
      decoration: FormFieldStyle.decoration(
        label: 'Age (optional)',
        helper: 'Use this only if the birth date is unknown.',
      ),
      validator: ExamineeInfo.validateAge,
    );
  }
}
