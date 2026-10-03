import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../models/user.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/surface_card.dart';

/// Reusable widget for displaying a single user in the User Management
/// list. Shows only account/administrative fields -- never anything
/// examination-related, since none exist on [UserModel] to begin with.
class UserListItem extends StatelessWidget {
  final UserModel user;
  final VoidCallback onTap;

  const UserListItem({
    super.key,
    required this.user,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isAdmin = user.role == 'system_admin';
    return SurfaceCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      style: AppTextStyles.subtitle(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      user.email,
                      style: AppTextStyles.caption(color: AppColors.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.md),
              StatusBadge(
                label: user.isActive ? 'Active' : 'Inactive',
                tone: user.isActive ? StatusTone.success : StatusTone.neutral,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Wrap(
            spacing: AppSpace.sm,
            children: [
              StatusBadge(
                label: isAdmin ? 'System Admin' : 'Guidance Council',
                tone: isAdmin ? StatusTone.info : StatusTone.success,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
