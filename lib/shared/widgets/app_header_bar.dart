import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';

/// The compact green top bar used on Staff Home, Exam Hub, and Cloud
/// Archive screens ("GUIDE GRADE" wordmark + optional trailing action).
class AppHeaderBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final Widget? trailing;
  final bool showLogo;

  const AppHeaderBar({
    super.key,
    required this.title,
    this.trailing,
    this.showLogo = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primaryGreen,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: SafeArea(
        bottom: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                if (showLogo) ...[
                  const _LogoBadge(),
                  const SizedBox(width: 8),
                ],
                Text(
                  title,
                  style: AppTextStyles.heading(size: 12.5, color: Colors.white, weight: FontWeight.w800)
                      .copyWith(letterSpacing: 1.1),
                ),
              ],
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }

  @override
  // A touch taller with the logo so the badge isn't cramped.
  Size get preferredSize => Size.fromHeight(showLogo ? 60 : 52);
}

/// The app's hexagon "G" mark on a small white badge: the logo is green, so it
/// needs the white to stay visible on the green bar.
class _LogoBadge extends StatelessWidget {
  const _LogoBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('app-header-logo'),
      width: 32,
      height: 32,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(9)),
      child: Image.asset(
        'assets/images/guidegrade logo1 trimmed.png',
        fit: BoxFit.contain,
        // A missing asset must never take the whole header down.
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
  }
}
