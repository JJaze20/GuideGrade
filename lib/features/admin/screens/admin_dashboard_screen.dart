import 'package:flutter/material.dart';

import '../../../core/routes/app_routes.dart';
import '../../../shared/utils/logout_helper.dart';
import '../../../shared/widgets/console_task_card.dart';

/// Administrative tools only; examination workflows belong to Guidance Council.
class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF0F3F8),
    appBar: AppBar(
      backgroundColor: const Color(0xFF14243D),
      foregroundColor: Colors.white,
      toolbarHeight: 76,
      elevation: 0,
      title: Row(
        children: [
          Image.asset('assets/images/guidegrade logo1 trimmed.png', height: 36),
          const SizedBox(width: 12),
          const Flexible(
            child: Text('System Admin Console',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
        ],
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF14243D), Color(0xFF254B62)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.admin_panel_settings_outlined,
                      size: 32, color: Color(0xFF9AE0B3)),
                    const SizedBox(height: 18),
                    Text('Administration',
                      style: TextStyle(
                        fontSize: MediaQuery.sizeOf(context).width < 600 ? 26 : 34,
                        fontWeight: FontWeight.w800, color: Colors.white)),
                    const SizedBox(height: 8),
                    const Text(
                      'Manage accounts, review system activity, and handle restore requests.',
                      style: TextStyle(fontSize: 15, height: 1.6,
                        color: Color(0xFFCDDCE9))),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              const Text('Administrative tools',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700,
                  color: Color(0xFF14243D))),
              const SizedBox(height: 6),
              const Text('Choose a workspace to get started.',
                style: TextStyle(fontSize: 14, color: Color(0xFF64748B))),
              const SizedBox(height: 18),
              ConsoleTaskGrid(
                children: [
                  ConsoleTaskCard(
                    icon: Icons.manage_accounts_outlined,
                    title: 'User Management',
                    description:
                        'Create and manage authorized Guidance Council accounts.',
                    dark: true,
                    accent: const Color(0xFF93C5FD),
                    onTap: () => Navigator.of(
                      context,
                    ).pushNamed(AppRoutes.userManagement),
                  ),
                  ConsoleTaskCard(
                    icon: Icons.history_rounded,
                    title: 'System Logs',
                    description:
                        'Review administrative activity and track account changes.',
                    dark: true,
                    accent: const Color(0xFF99E2C1),
                    onTap: () =>
                        Navigator.of(context).pushNamed(AppRoutes.systemLogs),
                  ),
                  ConsoleTaskCard(
                    icon: Icons.restore_page_outlined,
                    title: 'Restore Management',
                    description:
                        'Review restoration requests and recover eligible retained scans.',
                    dark: true,
                    accent: const Color(0xFFF1CF8B),
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
