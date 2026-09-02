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

/// Per-sheet student entry — last name, first name, examinee number.
/// Last/First Name may arrive pre-filled from [ocrSuggestion] (an on-device
/// OCR guess at the sheet's handwritten name field — see NameOcrService),
/// but staff always review/correct it before saving; [ocrSuggestion] is
/// never itself treated as a saved tag (only [initial] is — see the
/// "Remove" button below). Returns null if dismissed without saving.
Future<ExamineeDialogResult?> showExamineeDialog(
  BuildContext context, {
  ExamineeInfo? initial,
  ExamineeInfo? ocrSuggestion,
  String? sheetLabel,
  Set<String> otherNumbers = const {},
}) {
  // ocrSuggestion only ever seeds the fields when there's no confirmed tag
  // yet — a real, saved [initial] always wins.
  final appliedSuggestion = initial == null ? ocrSuggestion : null;
  final lastCtrl = TextEditingController(text: initial?.lastName ?? appliedSuggestion?.lastName ?? '');
  final firstCtrl = TextEditingController(text: initial?.firstName ?? appliedSuggestion?.firstName ?? '');
  final middleCtrl = TextEditingController(text: initial?.middleName ?? '');
  final numberCtrl = TextEditingController(text: initial?.examineeNumber ?? '');
  final formKey = GlobalKey<FormState>();
  final hasSuggestion = appliedSuggestion != null && !appliedSuggestion.isEmpty;

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
            if (hasSuggestion) ...[
              Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 14, color: AppColors.primaryGreen),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Detected from handwriting — please verify',
                      style: AppTextStyles.body(size: 11, color: AppColors.primaryGreen),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
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
              controller: middleCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: deco('Middle name (optional)'),
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
