import 'package:flutter/material.dart';

import '../../../core/constants/app_tokens.dart';
import 'console_style.dart';

/// Title area at the top of a console page: a small green eyebrow, a large
/// serif title, an optional subtitle, and a breadcrumb trail on the right
/// (below the title on a narrow window).
class ConsolePageHeader extends StatelessWidget {
  const ConsolePageHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.subtitle,
    this.trail = const [],
  });

  final String eyebrow;
  final String title;
  final String? subtitle;

  /// Breadcrumb segments, first to last. The last one is the current page.
  final List<String> trail;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(eyebrow, style: ConsoleText.eyebrow()),
        const SizedBox(height: 6),
        Text(
          title,
          style: ConsoleText.serifTitle(
            size: width < AppBreakpoints.compact ? 28 : 34,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(
            subtitle!,
            style: ConsoleText.body(size: 14.5, color: ConsoleColors.muted),
          ),
        ],
      ],
    );
    final breadcrumb = trail.isEmpty ? null : _Breadcrumb(trail: trail);
    final padding = EdgeInsets.fromLTRB(
      AppSpace.gutterFor(width) + 8,
      16,
      AppSpace.gutterFor(width) + 8,
      8,
    );
    return Padding(
      padding: padding,
      child: width < 900 || breadcrumb == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                titleBlock,
                if (breadcrumb != null) ...[
                  const SizedBox(height: 10),
                  breadcrumb,
                ],
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: titleBlock),
                const SizedBox(width: 24),
                breadcrumb,
              ],
            ),
    );
  }
}

class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.trail});

  final List<String> trail;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < trail.length; i++) {
      final first = i == 0;
      final last = i == trail.length - 1;
      if (i > 0) {
        children.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.chevron_right,
              size: 16,
              color: ConsoleColors.muted,
            ),
          ),
        );
      }
      children.add(
        Text(
          trail[i],
          style: ConsoleText.body(
            size: 13,
            weight: first ? FontWeight.w700 : FontWeight.w400,
            color: first
                ? ConsoleColors.eyebrow
                : (last ? ConsoleColors.muted : ConsoleColors.muted),
          ),
        ),
      );
    }
    // A Wrap, so a long trail drops to a second line on a narrow window.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}
