import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../core/constants/app_colors.dart';
import '../../core/routes/app_routes.dart';

/// The 3-tab bottom navigation bar (Home / Sheet / Archive) shown across
/// the staff-facing screens, matching `getFooterMarkup()` in the prototype.
class AppBottomNav extends StatelessWidget {
  /// 'home' | 'sheet' | 'cloud'
  final String activeTab;

  const AppBottomNav({super.key, required this.activeTab});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        boxShadow: [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, -2))],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _NavItem(
              icon: FontAwesomeIcons.house,
              label: 'Home',
              active: activeTab == 'home',
              onTap: () => Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.staffHome,
                (route) => false,
              ),
            ),
            _NavItem(
              icon: FontAwesomeIcons.fileSignature,
              label: 'Sheet',
              active: activeTab == 'sheet',
              onTap: () => Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.examHub,
                (route) => false,
              ),
            ),
            _NavItem(
              icon: FontAwesomeIcons.boxArchive,
              label: 'Archive',
              active: activeTab == 'cloud',
              onTap: () => Navigator.of(context).pushNamedAndRemoveUntil(
                AppRoutes.cloudArchive,
                (route) => false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final FaIconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.primaryGreen : AppColors.textGray;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FaIcon(icon, size: 15, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 9, color: color, fontWeight: active ? FontWeight.w700 : FontWeight.w400),
            ),
          ],
        ),
      ),
    );
  }
}
