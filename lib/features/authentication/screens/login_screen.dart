import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/primary_button.dart';

/// Login screen with Firebase email/password and Google sign-in.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();

  bool _obscurePassword = true;
  bool _isLoading = false;
  static const String _adminEmail = 'admin@ndmu.edu.ph';

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _runAuth(Future<UserCredential> Function() signIn) async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      final credential = await signIn();
      if (!mounted) return;
      _navigateAfterLogin(credential.user);
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      _showError(AuthService.messageFor(error));
    } catch (_) {
      if (!mounted) return;
      _showError('Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _handleEmailLogin() {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      _showError('Enter your email and password.');
      return;
    }

    _runAuth(
      () => _authService.signInWithEmail(email: email, password: password),
    );
  }

  void _handleGoogleLogin() {
    _runAuth(_authService.signInWithGoogle);
  }

  void _navigateAfterLogin(User? user) {
    if (user == null) {
      _showError('Sign-in succeeded but no user profile was returned.');
      return;
    }

    final appState = AppStateScope.of(context);
    final email = user.email ?? '';
    final isAdmin = email.toLowerCase() == _adminEmail.toLowerCase();

    appState.userRole = isAdmin ? 'admin' : 'staff';
    final route = isAdmin ? AppRoutes.adminDashboard : AppRoutes.staffHome;
    Navigator.of(context).pushNamedAndRemoveUntil(route, (route) => false);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.slate900,
      body: SafeArea(
        child: Column(
          children: [
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
                    errorBuilder: (_, __, ___) =>
                        Container(color: AppColors.slate800),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      height: 60,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [
                            AppColors.lightBg,
                            AppColors.lightBg.withOpacity(0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
                            colors: [
                              AppColors.warmRedOrange,
                              AppColors.accentYellowGreen,
                              Color(0xFF1565C0),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const FaIcon(
                          FontAwesomeIcons.shieldHalved,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Guide',
                        style: AppTextStyles.logo(
                          size: 28,
                          color: AppColors.warmRedOrange,
                        ),
                      ),
                      Text(
                        'Grade',
                        style: AppTextStyles.logo(
                          size: 28,
                          color: AppColors.primaryGreen,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Guidance automated test diagnostic checking',
                    style: AppTextStyles.body(
                      size: 10,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
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
                            SecondaryButton(
                              label: _isLoading
                                  ? 'SIGNING IN...'
                                  : 'CONTINUE WITH GOOGLE',
                              onPressed: _isLoading ? null : _handleGoogleLogin,
                              icon: FontAwesomeIcons.google,
                              foregroundColor: AppColors.textDark,
                            ),
                            const SizedBox(height: 20),
                            Row(
                              children: [
                                Expanded(
                                  child: Divider(color: Colors.grey.shade300),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    'or sign in with email',
                                    style: AppTextStyles.body(
                                      size: 11,
                                      color: AppColors.textGray,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Divider(color: Colors.grey.shade300),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Text(
                              'Email',
                              style: AppTextStyles.body(
                                size: 12,
                                weight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              autofillHints: const [AutofillHints.email],
                              enabled: !_isLoading,
                              decoration: const InputDecoration(
                                hintText: 'staff@ndmu.edu.ph',
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Password',
                              style: AppTextStyles.body(
                                size: 12,
                                weight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              textInputAction: TextInputAction.done,
                              autofillHints: const [AutofillHints.password],
                              enabled: !_isLoading,
                              onSubmitted: (_) => _handleEmailLogin(),
                              decoration: InputDecoration(
                                hintText: '••••••••',
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    size: 18,
                                    color: Colors.grey,
                                  ),
                                  onPressed: _isLoading
                                      ? null
                                      : () => setState(
                                          () => _obscurePassword =
                                              !_obscurePassword,
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    PrimaryButton(
                      label: _isLoading ? 'SIGNING IN...' : 'LOGIN',
                      icon: FontAwesomeIcons.arrowRight,
                      color: AppColors.textDark,
                      onPressed: _isLoading ? null : _handleEmailLogin,
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
