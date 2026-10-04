import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/constants/app_tokens.dart';

/// A form section heading (for example "Account", "Profile") with an optional
/// one-line explanation, separated from the previous section by a rule so long
/// forms read as clear groups.
class FormSectionHeader extends StatelessWidget {
  const FormSectionHeader(this.title, {super.key, this.description, this.first = false});

  final String title;
  final String? description;

  /// The first section of a form has no divider above it.
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : AppSpace.lg, bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!first) ...[
            const Divider(),
            const SizedBox(height: AppSpace.lg),
          ],
          Text(title, style: AppTextStyles.subtitle(color: AppColors.darkNavy)),
          if (description != null) ...[
            const SizedBox(height: 2),
            Text(description!, style: AppTextStyles.caption()),
          ],
        ],
      ),
    );
  }
}

/// The label that sits above a field. Required fields get a red asterisk (and
/// optional ones can say so), so users never have to guess which fields they
/// can skip.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.label, {super.key, this.required = false, this.optionalHint = false});

  final String label;
  final bool required;

  /// Append a muted "(optional)" -- use on forms where most fields are required.
  final bool optionalHint;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xs + 2),
      child: Text.rich(
        TextSpan(
          text: label,
          style: AppTextStyles.body(size: 13, weight: FontWeight.w600),
          children: [
            if (required)
              TextSpan(
                text: ' *',
                style: AppTextStyles.body(
                  size: 13,
                  weight: FontWeight.w800,
                  color: AppColors.dangerFg,
                ),
              ),
            if (optionalHint && !required)
              TextSpan(
                text: '  (optional)',
                style: AppTextStyles.body(size: 12, color: AppColors.textMuted),
              ),
          ],
        ),
      ),
    );
  }
}

/// Page padding for a form in a [ListView]: a 16px gutter on phones, growing
/// symmetrically so the form column stays at most [maxWidth] wide (a
/// comfortable reading width) on tablets and desktop windows instead of
/// stretching fields across the whole screen.
class FormLayout {
  const FormLayout._();

  static EdgeInsets padding(BuildContext context, {double maxWidth = 640}) {
    final width = MediaQuery.sizeOf(context).width;
    final side = ((width - maxWidth) / 2).clamp(AppSpace.lg, double.infinity);
    return EdgeInsets.symmetric(horizontal: side, vertical: AppSpace.lg);
  }
}
