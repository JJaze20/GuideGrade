import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';
import '../../../shared/utils/logout_helper.dart';
import '../../../shared/widgets/console_task_card.dart';

/// Administrative tools only; examination workflows belong to Guidance Council.
class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.lightBg,
    appBar: AppBar(
      backgroundColor: AppColors.darkNavy,
      foregroundColor: Colors.white,
      title: const Text(
        'System Admin Console',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => confirmLogout(context),
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const Text('Sign out'),
          style: TextButton.styleFrom(
            foregroundColor: Colors.white,
            minimumSize: const Size(48, 48),
          ),
        ),
        const SizedBox(width: 12),
      ],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              const Text(
                'Administration',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textDark,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Manage accounts, review system activity, and handle restore requests.',
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: AppColors.textGray,
                ),
              ),
              const SizedBox(height: 28),
              ConsoleTaskGrid(
                children: [
                  ConsoleTaskCard(
                    icon: Icons.manage_accounts_outlined,
                    title: 'User Management',
                    description:
                        'Create and manage authorized Guidance Council accounts.',
                    accent: AppColors.darkNavy,
                    onTap: () => Navigator.of(
                      context,
                    ).pushNamed(AppRoutes.userManagement),
                  ),
                  ConsoleTaskCard(
                    icon: Icons.history_rounded,
                    title: 'System Logs',
                    description:
                        'Review administrative activity and track account changes.',
                    accent: AppColors.darkNavy,
                    onTap: () =>
                        Navigator.of(context).pushNamed(AppRoutes.systemLogs),
                  ),
                  ConsoleTaskCard(
                    icon: Icons.restore_page_outlined,
                    title: 'Restore Management',
                    description:
                        'Review requests and restore retained scans using lifecycle metadata.',
                    accent: AppColors.darkNavy,
                    onTap: () => Navigator.of(
                      context,
                    ).pushNamed(AppRoutes.restoreManagement),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
