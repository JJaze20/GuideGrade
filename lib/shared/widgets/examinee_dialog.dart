import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/services/batch_repository.dart';
import '../../models/local_batch.dart';
import 'name_crop_strip.dart';

/// Result of [showExamineeDialog]: [ExamineeDialogResult.cleared] is true
/// when the user chose "Remove", otherwise [info] holds the entered values.
class ExamineeDialogResult {
  final ExamineeInfo? info;
  final bool cleared;

  const ExamineeDialogResult({this.info, this.cleared = false});
}

/// Per-sheet student entry — last name, first name, examinee number. When
/// [batchId]/[scan]/[repository] are all given, the sheet's own cropped
/// handwriting (see [NameCropStrip]) is shown above the fields so staff can
/// read it while typing — this app runs no automatic handwriting
/// recognition, so nothing here is ever pre-filled from the scan itself.
/// Last/First Name may be left blank (a counselor may not know a name yet,
/// or may only have part of it); Examinee Number is still required.
/// Returns null if dismissed without saving.
Future<ExamineeDialogResult?> showExamineeDialog(
  BuildContext context, {
  ExamineeInfo? initial,
  String? sheetLabel,
  Set<String> otherNumbers = const {},
  String? batchId,
  LocalScan? scan,
  BatchRepository? repository,
}) {
  final lastCtrl = TextEditingController(text: initial?.lastName ?? '');
  final firstCtrl = TextEditingController(text: initial?.firstName ?? '');
  final middleCtrl = TextEditingController(text: initial?.middleName ?? '');
  final numberCtrl = TextEditingController(text: initial?.examineeNumber ?? '');
  final formKey = GlobalKey<FormState>();

  InputDecoration deco(String label) => InputDecoration(
    labelText: label,
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );

  return showDialog<ExamineeDialogResult>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        sheetLabel == null ? 'Student for this sheet' : 'Student — $sheetLabel',
        style: AppTextStyles.heading(size: 14),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (batchId != null && scan != null && repository != null) ...[
                Text(
                  'Handwritten name on this sheet',
                  style: AppTextStyles.body(
                    size: 10.5,
                    color: AppColors.textGray,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                NameCropStrip(
                  batchId: batchId,
                  scan: scan,
                  repository: repository,
                  height: 94,
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                key: const Key('examineeDialog.lastName'),
                controller: lastCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: deco('Last name (optional)'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('examineeDialog.firstName'),
                controller: firstCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: deco('First name (optional)'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('examineeDialog.middleName'),
                controller: middleCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: deco('Middle name (optional)'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: const Key('examineeDialog.examineeNumber'),
                controller: numberCtrl,
                keyboardType: TextInputType.text,
                decoration: deco('Examinee number'),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty) return 'Required';
                  if (otherNumbers.contains(t)) {
                    return 'Already used by another sheet in this batch';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (initial != null && !initial.isEmpty)
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, const ExamineeDialogResult(cleared: true)),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF991B1B),
            ),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            Navigator.pop(
              ctx,
              ExamineeDialogResult(
                info: ExamineeInfo(
                  firstName: firstCtrl.text.trim(),
                  lastName: lastCtrl.text.trim(),
                  middleName: middleCtrl.text.trim(),
                  examineeNumber: numberCtrl.text.trim(),
                ),
              ),
            );
          },
          style: TextButton.styleFrom(foregroundColor: AppColors.primaryGreen),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
