import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../shared/utils/logout_helper.dart';

/// Navy Admin Console — mirrors SCREENS.ADMIN_DASHBOARD.
///
/// System Administrator entry point: administrative/system-management
/// functions only. Deliberately contains no links to Exams, Answer Keys,
/// Batches, OMR, or Results — that's the Guidance Council's
/// workspace (see AppRoutes._guidanceOnlyRoutes), and the System
/// Administrator role must not reach it, consistent with the deployed
/// Firestore rules (system_admin has no rule granting access to those
/// collections at all).
class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: AppColors.darkNavy,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'NAVY ADMIN CONSOLE',
                    style: AppTextStyles.heading(size: 12, color: Colors.white, weight: FontWeight.w800)
                        .copyWith(letterSpacing: 1.0),
                  ),
                  TextButton(
                    onPressed: () => confirmLogout(context),
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white.withOpacity(0.1),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                    ),
                    child: const Text('Exit', style: TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Administration', style: AppTextStyles.heading(size: 15)),
                  const SizedBox(height: 2),
                  Text(
                    'System management functions for GuideGrade.',
                    style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
                  ),
                  const SizedBox(height: 16),
                  _DashboardTile(
                    icon: FontAwesomeIcons.userGear,
                    iconColor: AppColors.primaryGreen,
                    iconBg: const Color(0xFFECFDF5),
                    title: 'User Management',
                    subtitle: 'Create and manage authorized Guidance Council accounts',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.userManagement),
                  ),
                  const SizedBox(height: 12),
                  _DashboardTile(
                    icon: FontAwesomeIcons.clipboardList,
                    iconColor: AppColors.primaryGreen,
                    iconBg: const Color(0xFFECFDF5),
                    title: 'System Logs',
                    subtitle: 'View the administrative audit trail',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.systemLogs),
                  ),
                  const SizedBox(height: 12),
                  _DashboardTile(
                    icon: FontAwesomeIcons.clockRotateLeft,
                    iconColor: AppColors.primaryGreen,
                    iconBg: const Color(0xFFECFDF5),
                    title: 'Restore Management',
                    subtitle: 'Review and restore soft-deleted scans (metadata only)',
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.restoreManagement),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardTile extends StatelessWidget {
  final FaIconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _DashboardTile({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.cardBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
              child: FaIcon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppTextStyles.body(
                      size: 12.5,
                      weight: FontWeight.w700,
                      color: isEnabled ? AppColors.textDark : AppColors.textGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
                ],
              ),
            ),
            if (isEnabled)
              const FaIcon(FontAwesomeIcons.chevronRight, size: 12, color: Color(0xFFCBD5E1)),
          ],
        ),
      ),
    );
  }
}
