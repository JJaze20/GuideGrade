import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';

/// Navy Admin Console — mirrors SCREENS.ADMIN_DASHBOARD.
/// Placeholder framework screen reached when logging in as "admin".
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
                    onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.adminLogin, (r) => false),
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
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const FaIcon(FontAwesomeIcons.toolbox, size: 26, color: AppColors.darkNavy),
                    const SizedBox(height: 8),
                    Text(
                      'Admin Console Framework operational.',
                      style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'User management, session logs, and reports\nwill be added here.',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
