import 'package:flutter/material.dart';

import '../../core/routes/app_routes.dart';
import '../../core/services/auth_service.dart';

/// Confirms with the user, signs out via [AuthService], and redirects to
/// the login screen — shared by every place a logout action is offered
/// (Staff Home, Profile) so the flow can't drift between them.
Future<void> confirmLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Log out?'),
      content: const Text('You will need to sign in again to access exam records.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Log out'),
        ),
      ],
    ),
  );

  if (confirmed != true) return;
  if (!context.mounted) return;

  try {
    await AuthService().signOut();
  } catch (_) {
    // Even if sign-out fails locally (e.g. no network), still route the
    // user back to login rather than leaving them stuck on a dead session.
  }

  if (!context.mounted) return;
  Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
}
