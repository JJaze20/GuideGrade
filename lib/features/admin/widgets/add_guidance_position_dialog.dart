import 'package:flutter/material.dart';

/// The "Add Guidance Position" prompt shared by Create User and Edit User --
/// the only two screens with a Guidance Position "+" action. Asks for a
/// human-readable label only; returns the trimmed text the admin entered, or
/// null if they cancelled.
///
/// This only checks the label is non-blank -- duplicate-label/duplicate-
/// value validation and the internal-value slug happen server-side against
/// the live position list (see `FirestoreService.addGuidancePosition` /
/// `GuidancePositions.validateNewLabel`), not here, since only the caller
/// has the current position list to check against.
Future<String?> showAddGuidancePositionDialog(BuildContext context) {
  final controller = TextEditingController();
  final formKey = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add Guidance Position'),
      content: Form(
        key: formKey,
        child: TextFormField(
          key: const Key('addGuidancePosition.label'),
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Position name',
            hintText: 'e.g., Auditing',
          ),
          validator: (value) =>
              (value == null || value.trim().isEmpty) ? 'Position name is required' : null,
        ),
      ),
      actions: [
        TextButton(
          key: const Key('addGuidancePosition.cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('addGuidancePosition.add'),
          onPressed: () {
            if (!formKey.currentState!.validate()) return;
            Navigator.of(dialogContext).pop(controller.text.trim());
          },
          child: const Text('Add'),
        ),
      ],
    ),
  );
}
