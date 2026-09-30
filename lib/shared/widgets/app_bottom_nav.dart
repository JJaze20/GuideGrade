import 'package:flutter/material.dart';
import '../../core/constants/app_colors.dart';
import '../../core/routes/app_routes.dart';

/// Staff navigation. Keeps the existing destinations and route-stack behavior.
class AppBottomNav extends StatelessWidget {
  /// 'home' | 'sheet' | 'cloud'
  final String activeTab;

  const AppBottomNav({super.key, required this.activeTab});

  @override
  Widget build(BuildContext context) {
    final selectedIndex = switch (activeTab) {
      'sheet' => 1,
      'cloud' => 2,
      _ => 0,
    };
    return Material(
      color: Colors.white,
      child: NavigationBar(
        selectedIndex: selectedIndex,
        backgroundColor: Colors.white,
        indicatorColor: const Color(0xFFE5F2E7),
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (index) {
          const routes = [
            AppRoutes.staffHome,
            AppRoutes.examHub,
            AppRoutes.cloudArchive,
          ];
          Navigator.of(context).pushNamedAndRemoveUntil(
            routes[index],
            (route) => false,
          );
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home, color: AppColors.primaryGreen),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.document_scanner_outlined),
            selectedIcon: Icon(Icons.document_scanner, color: AppColors.primaryGreen),
            label: 'Exams',
          ),
          NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2, color: AppColors.primaryGreen),
            label: 'Archive',
          ),
        ],
      ),
    );
  }
}
