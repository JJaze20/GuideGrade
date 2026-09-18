import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/routes/app_routes.dart';

/// Brief branded splash shown on mobile cold start: the logo fades and
/// scales in, holds, then hands off to [AppRoutes.login] -- which resolves
/// to the signed-in user's home screen or the login screen (see
/// AppRoutes._landingScreen). All of main()'s async setup (Firebase,
/// Supabase, session restore) has already finished by the time this widget
/// is built, so the delay here is purely for the animation, not a loading
/// gate.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..forward();
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _goToApp();
  }

  Future<void> _goToApp() async {
    await Future.delayed(const Duration(milliseconds: 1300));
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(AppRoutes.login);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      body: Center(
        child: FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Image.asset(
              'assets/images/guidegrade logo2.png',
              width: 180,
              height: 180,
            ),
          ),
        ),
      ),
    );
  }
}
