import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_text_styles.dart';
import '../../core/constants/app_tokens.dart';

/// The shared "something is not content yet" views: loading, empty and error.
/// Every list/table screen should use these instead of hand-rolling an icon
/// plus a sentence, so the three states look and behave the same everywhere:
///  * loading shows a REAL progress indicator (not a static icon),
///  * empty explains what is missing and, when possible, what to do next,
///  * error says what failed and offers a retry.
class _StateScaffold extends StatelessWidget {
  const _StateScaffold({
    required this.leading,
    required this.title,
    this.message,
    this.action,
    this.liveRegion = false,
  });

  final Widget leading;
  final String title;
  final String? message;
  final Widget? action;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Semantics(
            liveRegion: liveRegion,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading,
                const SizedBox(height: AppSpace.lg),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.subtitle(),
                ),
                if (message != null) ...[
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    message!,
                    textAlign: TextAlign.center,
                    style: AppTextStyles.caption(),
                  ),
                ],
                if (action != null) ...[
                  const SizedBox(height: AppSpace.lg),
                  action!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _iconBubble(IconData icon, Color fg, Color bg) => Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, size: 26, color: fg),
    );

/// A centered progress indicator with an optional message.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.message = 'Loading…'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return _StateScaffold(
      liveRegion: true,
      leading: const SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(strokeWidth: 3),
      ),
      title: message,
    );
  }
}

/// "Nothing here" view. Give [message] to say why and [action] for the next
/// step (for example a "Create user" button or "Clear filters").
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return _StateScaffold(
      leading: _iconBubble(icon, AppColors.neutralFg, AppColors.neutralBg),
      title: title,
      message: message,
      action: action,
    );
  }
}

/// A failed load. [message] should be the already-friendly text; [onRetry]
/// shows a "Try again" button so the user is never stuck.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.title = 'Something went wrong',
    this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return _StateScaffold(
      liveRegion: true,
      leading: _iconBubble(
        Icons.error_outline_rounded,
        AppColors.dangerFg,
        AppColors.dangerBg,
      ),
      title: title,
      message: message,
      action: onRetry == null
          ? null
          : OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Try again'),
            ),
    );
  }
}
