import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/user.dart';

/// Web login screen — the single entry point for BOTH Web-authorized
/// roles (`system_admin` and `guidance_council`; see [AppRoutes]). Kept as
/// one screen rather than two, per the smallest-safe-change approach: it
/// authenticates via [AuthService.signInForWeb] (no role is requested or
/// assumed at sign-in time) and then routes purely by whichever role the
/// account's own Firestore document actually has ([_navigateAfterLogin]) —
/// never a value chosen by the person signing in. A `system_admin` account
/// still lands on exactly the same [AdminDashboardScreen] as before this
/// change; only a `guidance_council` account signing in here is new
/// behavior (routes to `GuidanceWebHomeScreen`).
class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();

  bool _obscurePassword = true;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _runAuth(Future<UserModel> Function() signIn) async {
    if (_isLoading) return;

    setState(() => _isLoading = true);
    try {
      final user = await signIn();
      if (!mounted) return;
      _navigateAfterLogin(user);
    } catch (error) {
      if (!mounted) return;
      _showError(AuthService.messageFor(error));
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
      () => _authService.signInForWeb(email: email, password: password),
    );
  }

  // AuthService has already confirmed [user] is approved and active by the
  // time this runs (see AuthService.signInForWeb/_authorize) — but, unlike
  // before this screen became the shared Web login, [user] may now be
  // EITHER known role. Route by the account's own role, never a value
  // chosen at sign-in.
  void _navigateAfterLogin(UserModel user) {
    AppStateScope.of(context).setCurrentUser(user);
    final destination = user.role == 'system_admin' ? AppRoutes.adminDashboard : AppRoutes.guidanceWebHome;
    Navigator.of(context).pushNamedAndRemoveUntil(destination, (route) => false);
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
      backgroundColor: AppColors.primaryGreen,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: 0.18,
            child: Image.asset(
              'assets/images/NDMU BANNER.png',
              fit: BoxFit.cover,
              alignment: Alignment.center,
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
                  child: Text(
                    'NDMU Guidance and Testing Center',
                    key: const Key('webLoginInstitution'),
                    textAlign: TextAlign.left,
                    style: AppTextStyles.heading(size: 20, color: Colors.white),
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: constraints.maxHeight),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 480),
                              child: _buildSignInCard(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSignInCard() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x24000000),
            blurRadius: 32,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Image.asset(
              'assets/images/guidegrade logo1 trimmed.png',
              height: 72,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Web Console',
            textAlign: TextAlign.center,
            style: AppTextStyles.heading(size: 24, color: AppColors.primaryGreen),
          ),
          const SizedBox(height: 8),
          Text(
            'Guidance automated test diagnostic checking system',
            textAlign: TextAlign.center,
            style: AppTextStyles.body(size: 13, color: AppColors.textGray),
          ),
          const SizedBox(height: 28),
          Text('Sign In', style: AppTextStyles.heading(size: 22)),
          const SizedBox(height: 20),
                    TextField(
                      controller: _emailController,
                      enabled: !_isLoading,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        hintText: 'you@ndmu.edu.ph',
                        prefixIcon: const Icon(Icons.email_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                      ),
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 16),

                    TextField(
                      controller: _passwordController,
                      enabled: !_isLoading,
                      obscureText: _obscurePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        hintText: 'Enter your password',
                        prefixIcon: const Icon(Icons.lock_outlined),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          onPressed: () {
                            setState(() => _obscurePassword = !_obscurePassword);
                          },
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    ElevatedButton(
                      onPressed: _isLoading ? null : _handleEmailLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Text(
                              'SIGN IN',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                    ),

        ],
      ),
    );
  }
}
