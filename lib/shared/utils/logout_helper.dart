import 'package:flutter/material.dart';

import '../../core/routes/app_routes.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/logging_service.dart';
import '../../core/state/app_state.dart';

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

  final appState = AppStateScope.of(context);

  // Only System Administrator logouts are logged in v1 (Guidance Council
  // logout logging is out of scope for now, matching the login side).
  // This must run BEFORE signOut() — the log write needs the still-live
  // authenticated session, per the deployed rules' actorUid ==
  // request.auth.uid check.
  final currentUser = appState.currentUser;
  if (currentUser != null && currentUser.role == 'system_admin') {
    await LoggingService().logLogout(currentUser);
  }

  try {
    await AuthService().signOut();
  } catch (_) {
    // Even if sign-out fails locally (e.g. no network), still route the
    // user back to login rather than leaving them stuck on a dead session.
  }

  // Clear the approved-user state the route guard in AppRoutes keys off,
  // so a protected route can't still be reached after logout.
  appState.setCurrentUser(null);

  if (!context.mounted) return;
  Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
}
