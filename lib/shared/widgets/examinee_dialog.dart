import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../models/local_batch.dart';

/// Result of [showExamineeDialog]: [ExamineeDialogResult.cleared] is true
/// when the user chose "Remove", otherwise [info] holds the entered values.
class ExamineeDialogResult {
  final ExamineeInfo? info;
  final bool cleared;

  const ExamineeDialogResult({this.info, this.cleared = false});
}

/// Manual per-sheet student entry — last name, first name, examinee number.
/// There is no OCR; staff type this while holding the physical sheet.
/// Returns null if dismissed without saving.
Future<ExamineeDialogResult?> showExamineeDialog(
  BuildContext context, {
  ExamineeInfo? initial,
  String? sheetLabel,
  Set<String> otherNumbers = const {},
}) {
  final lastCtrl = TextEditingController(text: initial?.lastName ?? '');
  final firstCtrl = TextEditingController(text: initial?.firstName ?? '');
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
      content: Form(
        key: formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: lastCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: deco('Last name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: firstCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: deco('First name'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
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
      actions: [
        if (initial != null && !initial.isEmpty)
          TextButton(
            onPressed: () => Navigator.pop(ctx, const ExamineeDialogResult(cleared: true)),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF991B1B)),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            Navigator.pop(
              ctx,
              ExamineeDialogResult(
                info: ExamineeInfo(
                  firstName: firstCtrl.text.trim(),
                  lastName: lastCtrl.text.trim(),
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
