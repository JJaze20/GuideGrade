import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/auth_service.dart';
import '../../../shared/utils/logout_helper.dart';
import '../../../shared/widgets/primary_button.dart';

/// Profile — shows the signed-in user's info and lets them log out.
/// Reached by tapping the profile icon on Staff Home.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser;
    final displayName = user?.displayName?.trim();
    final name = (displayName != null && displayName.isNotEmpty) ? displayName : 'NDMU Staff Officer';
    final email = user?.email;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Profile', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0xFF1B5E20), shape: BoxShape.circle),
                      child: const FaIcon(FontAwesomeIcons.userTie, size: 28, color: Colors.white),
                    ),
                    const SizedBox(height: 14),
                    Text(name, style: AppTextStyles.heading(size: 15), textAlign: TextAlign.center),
                    if (email != null) ...[
                      const SizedBox(height: 4),
                      Text(email, style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: 'LOG OUT',
                icon: FontAwesomeIcons.rightFromBracket,
                color: AppColors.warmRedOrange,
                onPressed: () => confirmLogout(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
