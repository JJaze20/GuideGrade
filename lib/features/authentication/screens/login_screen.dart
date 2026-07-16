import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/primary_button.dart';

/// Login / Splash screen — mirrors SCREENS.SPLASH in the prototype.
///
/// Simple rule matching the mockup's "Interactive Helper":
///  - username "admin" -> Admin Console
///  - anything else    -> Staff Home
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _handleLogin() {
    final email = _emailController.text.trim();
    final appState = AppStateScope.of(context);

    if (email == 'admin') {
      appState.userRole = 'admin';
      Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.adminDashboard, (r) => false);
    } else {
      appState.userRole = 'staff';
      Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (r) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slate900,
      body: SafeArea(
        child: Column(
          children: [
            // Hero banner
            SizedBox(
              height: 170,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    'https://images.unsplash.com/photo-1541339907198-e08756dedf3f?auto=format&fit=crop&w=600&q=80',
                    fit: BoxFit.cover,
                    color: Colors.black.withOpacity(0.4),
                    colorBlendMode: BlendMode.darken,
                    errorBuilder: (_, __, ___) => Container(color: AppColors.slate800),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: 60,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [AppColors.lightBg, AppColors.lightBg.withOpacity(0)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Wordmark + tagline
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.warmRedOrange, AppColors.accentYellowGreen, Color(0xFF1565C0)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const FaIcon(FontAwesomeIcons.shieldHalved, color: Colors.white, size: 18),
                      ),
                      const SizedBox(width: 8),
                      Text('Guide', style: AppTextStyles.logo(size: 28, color: AppColors.warmRedOrange)),
                      Text('Grade', style: AppTextStyles.logo(size: 28, color: AppColors.primaryGreen)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Guidance automated test diagnostic checking',
                    style: AppTextStyles.body(size: 10, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),

            // Form card
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Email / Username', style: AppTextStyles.body(size: 12, weight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _emailController,
                              decoration: const InputDecoration(hintText: 'staff@ndmu.edu.ph'),
                            ),
                            const SizedBox(height: 16),
                            Text('Password', style: AppTextStyles.body(size: 12, weight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              decoration: InputDecoration(
                                hintText: '••••••••',
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword ? Icons.visibility_off : Icons.visibility,
                                    size: 18,
                                    color: Colors.grey,
                                  ),
                                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: 'LOGIN',
                      icon: FontAwesomeIcons.arrowRight,
                      color: AppColors.textDark,
                      onPressed: _handleLogin,
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        'Tip: username "admin" opens the Admin Console',
                        style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                      ),
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
