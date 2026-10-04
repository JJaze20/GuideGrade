import 'package:flutter/widgets.dart';

/// Spacing scale (4-pt grid). Prefer these over ad-hoc numbers so rhythm is
/// consistent between screens.
class AppSpace {
  AppSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// Horizontal page gutter for a given viewport width: tighter on phones,
  /// roomier on desktop.
  static double gutterFor(double width) => width < AppBreakpoints.compact ? 16 : 24;
}

/// Corner radii. Three steps plus a pill -- avoid inventing new ones.
class AppRadius {
  AppRadius._();

  /// Chips, small badges, inline controls.
  static const double sm = 8;

  /// Inputs, buttons, dialogs, list rows.
  static const double md = 12;

  /// Cards and panels.
  static const double lg = 16;

  /// Fully rounded (badges, pills).
  static const double pill = 999;

  static BorderRadius get smAll => BorderRadius.circular(sm);
  static BorderRadius get mdAll => BorderRadius.circular(md);
  static BorderRadius get lgAll => BorderRadius.circular(lg);
  static BorderRadius get pillAll => BorderRadius.circular(pill);
}

/// Layout breakpoints (logical px). `compact` = phones, `medium` = tablets /
/// small laptop windows, `expanded` = desktop.
class AppBreakpoints {
  AppBreakpoints._();

  static const double compact = 600;
  static const double medium = 900;
  static const double expanded = 1200;

  static bool isCompact(double width) => width < compact;
  static bool isMedium(double width) => width >= compact && width < medium;
}

/// Minimum interactive size (Material / WCAG 2.5.5 guidance).
class AppHit {
  AppHit._();

  static const double minTarget = 44;
}
