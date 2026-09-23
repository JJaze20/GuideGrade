import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/utils/logout_helper.dart';
import 'guidance_web_analytics_view.dart';
import 'guidance_web_export_view.dart';
import 'guidance_web_archive_view.dart';
import 'guidance_web_examinee_records_view.dart';
import 'guidance_web_results_view.dart';

/// The Guidance Council Web Console's persistent shell: header, sidebar,
/// and a body that swaps per sidebar selection.
///
/// This is intentionally a SEPARATE console from the System Administrator's
/// [AdminDashboardScreen] — different route set (`AppRoutes.
/// _guidanceWebRoutes`, gated on `role == 'guidance_council'`, never
/// `_adminOnlyRoutes`), different directory (`lib/features/guidance_web/`,
/// never `lib/features/admin/`), different visual language (Guidance
/// Council's own green branding + a persistent sidebar, vs. the Admin
/// Console's navy top bar + tile list), and no shared mutable state: it
/// reads only [AppState.currentUser] — never [AppState.batchRepository] /
/// [AppState.syncManager] / [AppState.cloudRestoreService] (the mobile
/// offline-sync stack), so nothing here depends on `dart:io` or
/// `path_provider`. Data retrieval for Results/Analytics/Export (Phase 2+)
/// is expected to call `SupabaseSyncClient`'s existing read methods
/// directly, not the mobile encrypted local storage layer.
///
/// Phase 1 built the shell with clearly-labeled placeholders for every
/// destination. Phase 2 wires up Results ([GuidanceWebResultsView]) —
/// still read-only, still no local write, no `CloudRestoreService`, no
/// image download (see that class's own doc comment). Examinee Records,
/// Archive ([GuidanceWebArchiveView]) and Analytics
/// ([GuidanceWebAnalyticsView]) are built; Export ([GuidanceWebExportView]) lists
/// batches, with its `export` and `view` actions still to come.
class GuidanceWebHomeScreen extends StatefulWidget {
  const GuidanceWebHomeScreen({super.key});

  @override
  State<GuidanceWebHomeScreen> createState() => _GuidanceWebHomeScreenState();
}

/// The sidebar's navigation destinations. `account` and `logout` are
/// handled separately (see [GuidanceWebHomeScreen]'s footer section) since
/// logout is an action, not a body destination.
enum _GuidanceWebDestination {
  dashboard('Dashboard', FontAwesomeIcons.gaugeHigh),
  results('Results', FontAwesomeIcons.fileLines),
  examineeRecords('Examinee Records', FontAwesomeIcons.userGraduate),
  archive('Archive', FontAwesomeIcons.boxArchive),
  analytics('Analytics', FontAwesomeIcons.chartColumn),
  export('Export', FontAwesomeIcons.fileExport);

  const _GuidanceWebDestination(this.label, this.icon);

  final String label;
  final FaIconData icon;
}

class _GuidanceWebHomeScreenState extends State<GuidanceWebHomeScreen> {
  _GuidanceWebDestination _selected = _GuidanceWebDestination.dashboard;

  @override
  Widget build(BuildContext context) {
    final user = AppStateScope.of(context).currentUser;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Sidebar(
              selected: _selected,
              onSelect: (d) => setState(() => _selected = d),
              userDisplayName: user?.displayName,
              userEmail: user?.email,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(title: _selected.label),
                  Expanded(child: _buildBody()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_selected) {
      case _GuidanceWebDestination.dashboard:
        return const _DashboardBody();
      case _GuidanceWebDestination.results:
        return const GuidanceWebResultsView();
      case _GuidanceWebDestination.examineeRecords:
        return const GuidanceWebExamineeRecordsView();
      case _GuidanceWebDestination.archive:
        return const GuidanceWebArchiveView();
      case _GuidanceWebDestination.analytics:
        return const GuidanceWebAnalyticsView();
      case _GuidanceWebDestination.export:
        return const GuidanceWebExportView();
    }
  }
}

class _Sidebar extends StatelessWidget {
  final _GuidanceWebDestination selected;
  final ValueChanged<_GuidanceWebDestination> onSelect;
  final String? userDisplayName;
  final String? userEmail;

  const _Sidebar({
    required this.selected,
    required this.onSelect,
    required this.userDisplayName,
    required this.userEmail,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Image.asset('assets/images/guidegrade logo1 trimmed.png', height: 30),
                    const SizedBox(width: 8),
                    Text('Guide', style: AppTextStyles.logo(size: 20, color: AppColors.warmRedOrange)),
                    Text('Grade', style: AppTextStyles.logo(size: 20, color: AppColors.primaryGreen)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'GUIDANCE COUNCIL',
                  style: AppTextStyles.body(size: 9.5, weight: FontWeight.w800, color: AppColors.textGray)
                      .copyWith(letterSpacing: 1.0),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.cardBorder),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              children: _GuidanceWebDestination.values
                  .map((d) => _SidebarItem(
                        destination: d,
                        isSelected: d == selected,
                        onTap: () => onSelect(d),
                      ))
                  .toList(),
            ),
          ),
          const Divider(height: 1, color: AppColors.cardBorder),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  userDisplayName ?? 'Account',
                  style: AppTextStyles.body(size: 11, weight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (userEmail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    userEmail!,
                    style: AppTextStyles.body(size: 9.5, color: AppColors.textGray),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => confirmLogout(context),
                    icon: const FaIcon(FontAwesomeIcons.rightFromBracket, size: 12),
                    label: const Text('Logout', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.textDark,
                      side: const BorderSide(color: AppColors.cardBorder),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final _GuidanceWebDestination destination;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({required this.destination, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.emerald100 : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            FaIcon(
              destination.icon,
              size: 14,
              color: isSelected ? AppColors.primaryGreen : AppColors.textGray,
            ),
            const SizedBox(width: 12),
            Text(
              destination.label,
              style: AppTextStyles.body(
                size: 11.5,
                weight: isSelected ? FontWeight.w700 : FontWeight.w600,
                color: isSelected ? AppColors.primaryGreen : AppColors.textDark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String title;

  const _Header({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.cardBorder)),
      ),
      child: Text(title, style: AppTextStyles.heading(size: 16)),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  const _DashboardBody();

  @override
  Widget build(BuildContext context) {
    final user = AppStateScope.of(context).currentUser;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Welcome${user?.displayName != null ? ', ${user!.displayName}' : ''}.',
            style: AppTextStyles.heading(size: 15),
          ),
          const SizedBox(height: 6),
          Text(
            'This is the Guidance Council Web Console. Use the sidebar to open '
            'Results, Analytics or Export.',
            style: AppTextStyles.body(size: 11, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }
}
