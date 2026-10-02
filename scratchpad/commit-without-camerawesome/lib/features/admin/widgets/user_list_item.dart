import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/user.dart';

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
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.cardBorder),
        ),
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
                        style: AppTextStyles.body(size: 12, weight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        user.email,
                        style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                _buildStatusChip(),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildRoleChip(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleChip() {
    final isAdmin = user.role == 'system_admin';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: isAdmin ? const Color(0xFFE0E7FF) : AppColors.emerald100,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        isAdmin ? 'System Admin' : 'Guidance Council',
        style: AppTextStyles.body(
          size: 9.5,
          weight: FontWeight.w700,
          color: isAdmin ? AppColors.darkNavy : const Color(0xFF065F46),
        ),
      ),
    );
  }

  Widget _buildStatusChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: user.isActive ? AppColors.emerald100 : const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        user.isActive ? 'Active' : 'Inactive',
        style: AppTextStyles.body(
          size: 9.5,
          weight: FontWeight.w700,
          color: user.isActive ? const Color(0xFF065F46) : const Color(0xFF991B1B),
        ),
      ),
    );
  }
}
