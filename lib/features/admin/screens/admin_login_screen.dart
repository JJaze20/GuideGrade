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

    _runAuth(() => _authService.signInForWeb(email: email, password: password));
  }

  // AuthService has already confirmed [user] is approved and active by the
  // time this runs (see AuthService.signInForWeb/_authorize) — but, unlike
  // before this screen became the shared Web login, [user] may now be
  // EITHER known role. Route by the account's own role, never a value
  // chosen at sign-in.
  void _navigateAfterLogin(UserModel user) {
    AppStateScope.of(context).setCurrentUser(user);
    final destination = user.role == 'system_admin'
        ? AppRoutes.adminDashboard
        : AppRoutes.guidanceWebHome;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(destination, (route) => false);
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
      backgroundColor: const Color(0xFFE8F5E9),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: 1.0,
            child: Image.asset(
              'assets/images/login-campus.jpg',
              filterQuality: FilterQuality.high,
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
                  child: Row(
                    children: [
                      Image.asset(
                        'assets/images/ndmu_logo.png',
                        width: 72,
                        height: 100,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                        semanticLabel: 'Notre Dame of Marbel University crest',
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'NDMU Guidance and Testing Center',
                          key: const Key('webLoginInstitution'),
                          textAlign: TextAlign.left,
                          style:
                              AppTextStyles.heading(
                                size: MediaQuery.sizeOf(context).width < 600
                                    ? 20
                                    : 30,
                                color: const Color(0xFFFFF5DE),
                              ).copyWith(
                                shadows: const [
                                  Shadow(
                                    color: Color(0xE614243D),
                                    blurRadius: 8,
                                    offset: Offset(0, 2),
                                  ),
                                  Shadow(
                                    color: Color(0xB3000000),
                                    blurRadius: 2,
                                    offset: Offset(0, 1),
                                  ),
                                ],
                              ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: MediaQuery.sizeOf(context).width < 600 ? 96 : 180,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: constraints.maxHeight,
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
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
          Positioned(
            top: 24,
            right: 24,
            child: SafeArea(
              child: Image.asset(
                'assets/images/guidance_council_logo.png',
                key: const Key('webLoginGuidanceLogo'),
                width: MediaQuery.sizeOf(context).width < 600 ? 96 : 180,
                height: MediaQuery.sizeOf(context).width < 600 ? 96 : 180,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                semanticLabel: 'NDMU Guidance and Testing Center logo',
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _loginFieldDecoration({
    required String hint,
    required IconData icon,
    Widget? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF87938C), fontSize: 14),
      filled: true,
      fillColor: const Color(0xFFFAF8F2),
      prefixIcon: Icon(icon, size: 20, color: const Color(0xFF64756A)),
      suffixIcon: suffix,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFD7DCCF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.primaryGreen, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFFE5EBE6)),
      ),
    );
  }

  Widget _buildSignInCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF174D2A),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFF39734B)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x550D2E19),
            blurRadius: 48,
            offset: Offset(0, 20),
          ),
        ],
      ),
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF236339),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Image.asset(
                  'assets/images/guidegrade logo1 trimmed.png',
                  height: 44,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'GuideGrade',
              textAlign: TextAlign.center,
              style: AppTextStyles.heading(
                size: 23,
                color: const Color(0xFF8EDCA0),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Guidance and Testing Center',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Color(0xFFD0E5D4)),
            ),
            const SizedBox(height: 20),
            Text(
              'Welcome back',
              style: AppTextStyles.heading(
                size: 21,
                color: const Color(0xFFF5FAF5),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Sign in with your authorized account.',
              style: TextStyle(fontSize: 14, color: Color(0xFFD0E5D4)),
            ),
            const SizedBox(height: 12),
            const Text(
              'Email',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE7F2E8),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _emailController,
              enabled: !_isLoading,
              autofillHints: const [AutofillHints.username],
              autocorrect: false,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              decoration: _loginFieldDecoration(
                hint: 'Enter your email',
                icon: Icons.email_outlined,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Password',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFFE7F2E8),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              enabled: !_isLoading,
              obscureText: _obscurePassword,
              autofillHints: const [AutofillHints.password],
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (!_isLoading) _handleEmailLogin();
              },
              decoration: _loginFieldDecoration(
                hint: 'Enter your password',
                icon: Icons.lock_outline_rounded,
                suffix: IconButton(
                  tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                    color: const Color(0xFF64756A),
                  ),
                  onPressed: _isLoading
                      ? null
                      : () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isLoading ? null : _handleEmailLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(48),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
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
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Sign In',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(width: 10),
                        Icon(Icons.arrow_forward_rounded, size: 18),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
