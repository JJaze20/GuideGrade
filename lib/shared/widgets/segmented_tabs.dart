import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/constants/app_tokens.dart';

/// One tab in [SegmentedTabs]. [count] adds a small number after the label.
class SegmentedTabItem<T> {
  const SegmentedTabItem({required this.value, required this.label, this.count});

  final T value;
  final String label;
  final int? count;
}

/// The page-level tab switcher used by multi-view screens (replaces the
/// hand-rolled `_tabButton` rows). Wraps onto extra lines instead of
/// overflowing on narrow screens, gives the selected tab a clear filled state
/// plus bold text (not colour alone), and exposes selected/button semantics.
class SegmentedTabs<T> extends StatelessWidget {
  const SegmentedTabs({
    super.key,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.padding = EdgeInsets.zero,
  });

  final List<SegmentedTabItem<T>> items;
  final T selected;
  final ValueChanged<T> onChanged;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // Wraps (rather than scrolling sideways) so every tab stays visible and
    // tappable on a narrow phone or with large text.
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.xs,
        children: [for (final item in items) _tab(item)],
      ),
    );
  }

  Widget _tab(SegmentedTabItem<T> item) {
    final isSelected = item.value == selected;
    final text = item.count == null ? item.label : '${item.label} (${item.count})';
    return Semantics(
      button: true,
      selected: isSelected,
      child: TextButton(
        onPressed: () => onChanged(item.value),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          backgroundColor: isSelected ? AppColors.successBg : Colors.transparent,
          foregroundColor: isSelected ? AppColors.primaryGreen : AppColors.textMuted,
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
            side: BorderSide(
              color: isSelected ? AppColors.successBorder : Colors.transparent,
            ),
          ),
        ),
        child: Text(
          text,
          style: AppTextStyles.body(
            size: 13,
            weight: isSelected ? FontWeight.w800 : FontWeight.w600,
            color: isSelected ? AppColors.primaryGreen : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}
