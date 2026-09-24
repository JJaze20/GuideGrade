import 'package:flutter/material.dart';

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
/// number. Existing birth date, age and school details are preserved on save.
/// When [batchId]/[scan]/[repository] are all given, the sheet's own
/// cropped handwriting (see [NameCropStrip]) is shown above the fields so staff
/// can read it while typing — this app runs no automatic handwriting
/// recognition, so nothing here is ever pre-filled from the scan itself.
/// Last/First Name and every detail may be left blank (a counselor may not
/// know them yet); Examinee Number is still required.
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
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    for (final c in [_lastCtrl, _firstCtrl, _middleCtrl, _numberCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      ExamineeDialogResult(
        info: ExamineeInfo(
          firstName: _firstCtrl.text.trim(),
          lastName: _lastCtrl.text.trim(),
          middleName: _middleCtrl.text.trim(),
          examineeNumber: _numberCtrl.text.trim(),
          birthDate: widget.initial?.birthDate,
          manualAge: widget.initial?.manualAge,
          lastSchool: widget.initial?.lastSchool ?? '',
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
                  textInputAction: TextInputAction.done,
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

}
