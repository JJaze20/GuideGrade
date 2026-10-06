import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';

/// A keyboard-accessible entry point to an existing console workflow.
class ConsoleTaskCard extends StatelessWidget {
  const ConsoleTaskCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.accent = AppColors.primaryGreen,
    this.dark = false,
  });

  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;
  final Color accent;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: Material(
        color: dark ? const Color(0xFF1B304D) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: dark ? const Color(0xFF354D6A) : AppColors.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: accent.withValues(alpha: 0.06),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: dark ? 0.16 : 0.09),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: accent, size: 24),
                    ),
                    const Spacer(),
                    Icon(Icons.arrow_forward_rounded, color: accent, size: 20),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: dark ? const Color(0xFFF4F7FC) : AppColors.textDark,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: dark ? const Color(0xFFC4D1E2) : AppColors.textGray,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cards wrap naturally and keep readable widths on small browser windows.
class ConsoleTaskGrid extends StatelessWidget {
  const ConsoleTaskGrid({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 1000
          ? 3
          : constraints.maxWidth >= 640
          ? 2
          : 1;
      final width = (constraints.maxWidth - (columns - 1) * 16) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          for (final child in children) SizedBox(width: width, child: child),
        ],
      );
    },
  );
}
