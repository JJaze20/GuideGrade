import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/constants/app_tokens.dart';

/// The one card/panel container: white surface, 1px border, 16px radius, no
/// shadow. Pass [onTap] to make the whole card an accessible button with a
/// hover/focus state.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpace.lg),
    this.onTap,
    this.color = AppColors.surface,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Material(
      color: color,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.lgAll,
        side: const BorderSide(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null
          ? content
          : Semantics(button: true, child: InkWell(onTap: onTap, child: content)),
    );
  }
}

/// A section/page heading row: title (+ optional subtitle) on the left and
/// optional actions on the right, wrapping under the title on narrow widths.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTextStyles.subtitle()),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!, style: AppTextStyles.caption()),
        ],
      ],
    );
    if (actions.isEmpty) return heading;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpace.md,
      runSpacing: AppSpace.sm,
      children: [
        heading,
        Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.sm, children: actions),
      ],
    );
  }
}
