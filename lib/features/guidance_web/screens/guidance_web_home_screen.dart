import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/state/app_state.dart';
import '../../../shared/utils/logout_helper.dart';
import '../../home/screens/profile_screen.dart';
import '../services/guidance_web_dashboard_service.dart';
import '../widgets/console_clock.dart';
import '../widgets/console_page_header.dart';
import '../widgets/console_style.dart';
import 'guidance_web_dashboard_view.dart';
import 'guidance_web_analytics_view.dart';
import 'guidance_web_export_view.dart';
import 'guidance_web_archive_view.dart';
import 'guidance_web_examinee_records_view.dart';
import 'guidance_web_results_view.dart';

/// The Guidance Council Web Console's persistent shell: a green top bar, a
/// slim icon sidebar that slides open over the page when the mouse touches it,
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
  const GuidanceWebHomeScreen({
    super.key,
    this.dashboardService,
    this.clock = DateTime.now,
  });

  final GuidanceWebDashboardService? dashboardService;

  /// The time shown in the top bar; only replaced in tests.
  final DateTime Function() clock;

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
  archive('Completed Batch', FontAwesomeIcons.boxArchive),
  analytics('Analytics', FontAwesomeIcons.chartColumn),
  export('Export', FontAwesomeIcons.fileExport);

  const _GuidanceWebDestination(this.label, this.icon);

  final String label;
  final FaIconData icon;
}

class _GuidanceWebHomeScreenState extends State<GuidanceWebHomeScreen> {
  static const double _railClosedWidth = 76;
  static const double _railOpenWidth = 280;
  static const Duration _slide = Duration(milliseconds: 180);

  _GuidanceWebDestination _selected = _GuidanceWebDestination.dashboard;

  /// The mouse is over the sidebar: it slides open over the page.
  bool _hovering = false;

  /// The menu button keeps the sidebar open and moves the page aside (also
  /// how a touch screen, which has no hover, opens it).
  bool _pinned = false;

  @override
  Widget build(BuildContext context) {
    final user = AppStateScope.of(context).currentUser;
    final compact = MediaQuery.sizeOf(context).width < 900;

    Widget rail({required bool open, bool inDrawer = false}) => _SideRail(
      open: open,
      expandToFit: inDrawer,
      selected: _selected,
      onSelect: (destination) {
        setState(() => _selected = destination);
        if (inDrawer) Navigator.of(context).pop();
      },
      userDisplayName: user?.displayName,
      userEmail: user?.email,
      onProfile: () {
        if (inDrawer) Navigator.of(context).pop();
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const ProfileScreen()));
      },
      onLogout: () => confirmLogout(context),
    );

    final page = DecoratedBox(
      decoration: consolePageBackground,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConsolePageHeader(
            eyebrow: 'GUIDANCE WORKSPACE',
            title: _selected.label,
            trail: ['GuideGrade', 'Guidance Council', _selected.label],
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );

    if (compact) {
      return Scaffold(
        backgroundColor: ConsoleColors.pageTop,
        drawer: Drawer(
          backgroundColor: ConsoleColors.railGreen,
          child: SafeArea(child: rail(open: true, inDrawer: true)),
        ),
        appBar: AppBar(
          backgroundColor: ConsoleColors.headerGreen,
          foregroundColor: ConsoleColors.onGreen,
          title: Text(
            _selected.label,
            style: ConsoleText.body(
              size: 18,
              weight: FontWeight.w700,
              color: ConsoleColors.onGreen,
            ),
          ),
        ),
        body: SafeArea(child: page),
      );
    }

    return Scaffold(
      backgroundColor: ConsoleColors.pageTop,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ConsoleHeader(
              clock: widget.clock,
              pinned: _pinned,
              onToggleRail: () => setState(() => _pinned = !_pinned),
            ),
            Expanded(
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: _slide,
                    curve: Curves.easeOut,
                    left: _pinned ? _railOpenWidth : _railClosedWidth,
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: page,
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: MouseRegion(
                      onEnter: (_) => setState(() => _hovering = true),
                      onExit: (_) => setState(() => _hovering = false),
                      child: rail(open: _pinned || _hovering),
                    ),
                  ),
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
        return GuidanceWebDashboardView(service: widget.dashboardService);
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

/// Dark green top bar: menu button, university crest and name, and the
/// current time and date on the right.
class _ConsoleHeader extends StatelessWidget {
  const _ConsoleHeader({
    required this.clock,
    required this.pinned,
    required this.onToggleRail,
  });

  final DateTime Function() clock;
  final bool pinned;
  final VoidCallback onToggleRail;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 84,
      color: ConsoleColors.headerGreen,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Tooltip(
            message: pinned ? 'Collapse navigation' : 'Keep navigation open',
            child: Material(
              color: Colors.white.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.18)),
              ),
              child: InkWell(
                key: const Key('consoleMenuButton'),
                borderRadius: BorderRadius.circular(12),
                onTap: onToggleRail,
                child: const SizedBox(
                  width: 52,
                  height: 52,
                  child: Icon(Icons.menu, color: ConsoleColors.onGreen),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Image.asset(
            'assets/images/ndmu_logo.png',
            height: 48,
            errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 48),
          ),
          const SizedBox(width: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Notre Dame of Marbel University',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.body(
                    size: 18,
                    weight: FontWeight.w700,
                    color: ConsoleColors.onGreen,
                  ),
                ),
                Text(
                  'Guidance and Testing Center',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ConsoleText.body(
                    size: 12.5,
                    color: ConsoleColors.onGreenMuted,
                  ),
                ),
              ],
            ),
          ),
          // The date and the time sit together, close, with a thin divider,
          // flush with the right edge of the bar.
          Expanded(
            child: ConsoleClock(
              clock: clock,
              layout: (context, date, time) => Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: date),
                    Container(
                      width: 1,
                      height: 30,
                      margin: const EdgeInsets.symmetric(horizontal: 18),
                      color: Colors.white.withValues(alpha: 0.25),
                    ),
                    time,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The sidebar: icons only when closed, icons + labels + account when open.
/// It slides open over the page; the page does not move unless pinned.
class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.open,
    required this.expandToFit,
    required this.selected,
    required this.onSelect,
    required this.userDisplayName,
    required this.userEmail,
    required this.onProfile,
    required this.onLogout,
  });

  /// Whether the rail is (sliding) open. Ignored when [expandToFit].
  final bool open;

  /// Fill the available width (the narrow-window drawer) instead of sliding.
  final bool expandToFit;
  final _GuidanceWebDestination selected;
  final ValueChanged<_GuidanceWebDestination> onSelect;
  final String? userDisplayName;
  final String? userEmail;
  final VoidCallback onProfile;
  final VoidCallback onLogout;

  static const double _closedWidth = 76;
  static const double _openWidth = 280;
  // Below this width the account details are replaced by the initials badge.
  static const double _showDetailsAt = 200;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      key: const Key('consoleRail'),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: expandToFit ? null : (open ? _openWidth : _closedWidth),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ConsoleColors.railGreen, ConsoleColors.railGreenDeep],
        ),
        boxShadow: open && !expandToFit
            ? const [
                BoxShadow(
                  color: Color(0x33000000),
                  blurRadius: 18,
                  offset: Offset(4, 0),
                ),
              ]
            : const [],
      ),
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showDetails = constraints.maxWidth >= _showDetailsAt;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 18),
                Expanded(
                  child: ListView(
                    children: [
                      for (final destination in _GuidanceWebDestination.values)
                        _RailItem(
                          destination: destination,
                          isSelected: destination == selected,
                          showLabel: showDetails,
                          onTap: () => onSelect(destination),
                        ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: 0.14)),
                _RailAccount(
                  showDetails: showDetails,
                  displayName: userDisplayName,
                  email: userEmail,
                  onProfile: onProfile,
                  onLogout: onLogout,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.destination,
    required this.isSelected,
    required this.showLabel,
    required this.onTap,
  });

  final _GuidanceWebDestination destination;
  final bool isSelected;
  final bool showLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final icon = FaIcon(
      destination.icon,
      size: 16,
      color: isSelected ? ConsoleColors.gold : ConsoleColors.onGreenMuted,
    );
    final item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: isSelected ? ConsoleColors.railSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: Colors.white.withValues(alpha: 0.07),
          onTap: onTap,
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border(
                left: BorderSide(
                  color: isSelected ? ConsoleColors.gold : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            child: Row(
              children: [
                // Open: the icon sits in a fixed cell with the label beside it.
                // Closed: the icon alone, centered -- no label is built, so no
                // sliver of its first letter peeks out of the narrow rail.
                if (showLabel)
                  SizedBox(width: 46, child: Center(child: icon))
                else
                  Expanded(child: Center(child: icon)),
                if (showLabel)
                  Expanded(
                    child: Text(
                      destination.label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: ConsoleText.body(
                        size: 14,
                        weight: isSelected ? FontWeight.w700 : FontWeight.w600,
                        color: ConsoleColors.onGreen,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    // Closed: the icon alone needs its name on hover.
    return showLabel ? item : Tooltip(message: destination.label, child: item);
  }
}

class _RailAccount extends StatelessWidget {
  const _RailAccount({
    required this.showDetails,
    required this.displayName,
    required this.email,
    required this.onProfile,
    required this.onLogout,
  });

  final bool showDetails;
  final String? displayName;
  final String? email;
  final VoidCallback onProfile;
  final VoidCallback onLogout;

  String get _initials {
    final parts = (displayName ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'GC';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final badge = CircleAvatar(
      radius: 21,
      backgroundColor: ConsoleColors.railSelected,
      child: Text(
        _initials,
        style: ConsoleText.body(
          size: 13,
          weight: FontWeight.w800,
          color: ConsoleColors.onGreen,
        ),
      ),
    );
    if (!showDetails) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Tooltip(message: displayName ?? 'Account', child: badge),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              badge,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName ?? 'Account',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ConsoleText.body(
                        size: 13.5,
                        weight: FontWeight.w700,
                        color: ConsoleColors.onGreen,
                      ),
                    ),
                    if (email != null)
                      Text(
                        email!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ConsoleText.body(
                          size: 11.5,
                          color: ConsoleColors.onGreenMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onProfile,
            icon: const FaIcon(FontAwesomeIcons.user, size: 12),
            label: const Text('Profile', style: TextStyle(fontSize: 13.5)),
            style: OutlinedButton.styleFrom(
              foregroundColor: ConsoleColors.onGreen,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('consoleSignOut'),
            onPressed: onLogout,
            icon: const FaIcon(FontAwesomeIcons.rightFromBracket, size: 12),
            label: const Text('Sign out', style: TextStyle(fontSize: 13.5)),
            style: OutlinedButton.styleFrom(
              foregroundColor: ConsoleColors.onGreen,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      ),
    );
  }
}
