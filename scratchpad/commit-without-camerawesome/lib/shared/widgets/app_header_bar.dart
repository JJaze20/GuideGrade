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
                  Text('G', style: AppTextStyles.logo(size: 20, color: Colors.amber.shade300)),
                  const SizedBox(width: 6),
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
  Size get preferredSize => const Size.fromHeight(52);
}
