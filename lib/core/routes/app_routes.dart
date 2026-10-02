import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/logging_service.dart';
import '../../core/state/app_state.dart';
import '../../core/utils/platform_utils.dart';
import '../../shared/widgets/app_bottom_nav.dart';
import '../../features/authentication/screens/mobile_login_screen.dart';
import '../../features/authentication/screens/profile_setup_screen.dart';
import '../../features/splash/screens/splash_screen.dart';
import '../../features/admin/screens/admin_login_screen.dart';
import '../../features/home/screens/staff_home_screen.dart';
import '../../features/home/screens/profile_screen.dart';
import '../../features/exam/screens/exam_hub_screen.dart';
import '../../features/exam/screens/exam_setup_screen.dart';
import '../../features/exam/screens/exam_scanning_screen.dart';
import '../../features/exam/screens/exam_results_screen.dart';
import '../../features/exam/screens/answer_key_entry_screen.dart';
import '../../features/archive/screens/cloud_archive_screen.dart';
import '../../features/archive/screens/batch_archive_detail_screen.dart';
import '../../features/archive/screens/qtm_batch_analytics_screen.dart';
import '../../features/archive/screens/tat_batch_analytics_screen.dart';
import '../../features/archive/screens/at_batch_analytics_screen.dart';
import '../../features/admin/screens/admin_dashboard_screen.dart';
import '../../features/guidance/screens/exam_management_screen.dart';
import '../../features/guidance/screens/exam_sheet_preview_screen.dart';
import '../../features/guidance/screens/batch_management_screen.dart';
import '../../features/guidance/screens/create_batch_screen.dart';
import '../../features/guidance/screens/edit_batch_screen.dart';
import '../../features/admin/screens/user_management_screen.dart';
import '../../features/admin/screens/create_user_screen.dart';
import '../../features/admin/screens/edit_user_screen.dart';
import '../../features/admin/screens/system_logs_screen.dart';
import '../../features/guidance_web/screens/guidance_web_home_screen.dart';
import '../constants/exam_catalog.dart';
import '../../models/local_batch.dart';
import '../../models/user.dart';

/// Centralized route names. Keeping these as constants avoids typos
/// when navigating between feature modules.
class AppRoutes {
  AppRoutes._();

  static const String splash = '/splash';
  static const String login = '/login';
  static const String mobileLogin = '/mobile-login';
  static const String adminLogin = '/admin-login';
  static const String staffHome = '/staff-home';
  static const String profile = '/profile';
  static const String profileSetup = '/profile-setup';
  static const String examHub = '/exam-hub';
  static const String examSetup = '/exam-setup';
  static const String examScanning = '/exam-scanning';
  static const String examResults = '/exam-results';
  static const String answerKeyEntry = '/answer-key-entry';
  static const String cloudArchive = '/cloud-archive';
  static const String batchArchiveDetail = '/batch-archive-detail';
  static const String qtmBatchAnalytics = '/qtm-batch-analytics';
  static const String tatBatchAnalytics = '/tat-batch-analytics';
  static const String atBatchAnalytics = '/at-batch-analytics';
  static const String adminDashboard = '/admin-dashboard';
  static const String examManagement = '/exam-management';
  static const String examSheetPreview = '/exam-sheet-preview';
  static const String batchManagement = '/batch-management';
  static const String createBatch = '/create-batch';
  static const String editBatch = '/edit-batch';
  static const String userManagement = '/user-management';
  static const String createUser = '/create-user';
  static const String editUser = '/edit-user';
  static const String systemLogs = '/system-logs';
  static const String guidanceWebHome = '/guidance-web-home';

  /// Routes reachable without being signed in at all.
  static const Set<String> _publicRoutes = {splash, login, mobileLogin, adminLogin};

  /// Routes that additionally require the `system_admin` role, on top of
  /// being an approved, active user. System Administrator responsibilities
  /// (user management, system logs, administrative monitoring) live here —
  /// none of it is confidential examination data.
  static const Set<String> _adminOnlyRoutes = {
    adminDashboard,
    userManagement,
    createUser,
    editUser,
    systemLogs,
  };

  /// Routes that require the `guidance_council` role — Staff Home and the
  /// confidential examination workflow (exams, answer keys, batches,
  /// OMR scanning, results). `system_admin` must never reach
  /// these, per the System Administrator = system management / Guidance
  /// Council = examination management separation. `profile` is
  /// deliberately excluded from this set — it stays open to both roles.
  static const Set<String> _guidanceOnlyRoutes = {
    staffHome,
    profileSetup,
    examHub,
    examSetup,
    examScanning,
    examResults,
    answerKeyEntry,
    examManagement,
    examSheetPreview,
    batchManagement,
    createBatch,
    editBatch,
    cloudArchive,
    batchArchiveDetail,
    qtmBatchAnalytics,
    tatBatchAnalytics,
    atBatchAnalytics,
  };

  /// Routes for the Guidance Council WEB Console — deliberately a
  /// SEPARATE set from [_guidanceOnlyRoutes] (the mobile examination
  /// workflow), never merged into it and never merged into
  /// [_adminOnlyRoutes]. Gated the same way: requires an approved,
  /// active `guidance_council` [AppState.currentUser]. `system_admin` must
  /// never reach these, and a `guidance_council` account reaching one of
  /// these on mobile (or a [_guidanceOnlyRoutes] route on Web) is not
  /// specially prevented here — nothing in the app currently navigates a
  /// mobile build to a route in this set, or a Web build to a route in
  /// [_guidanceOnlyRoutes]. Phase 1 has only [guidanceWebHome]; later
  /// phases (Results, Examinee Records, Archive, Analytics, Export) add
  /// their own route names here.
  static const Set<String> _guidanceWebRoutes = {
    guidanceWebHome,
  };

  /// Generates routes for [MaterialApp.onGenerateRoute]. Using this
  /// approach (rather than a static `routes` map) lets us pass
  /// arguments cleanly to screens like Exam Setup/Results.
  ///
  /// [appState] gates every non-public route on both Firebase's own auth
  /// state (`FirebaseAuth.instance.currentUser`) and the Firestore-approved
  /// [AppState.currentUser] set either by a successful login (see
  /// `AuthService._authorize`) or, on a fresh cold start, by
  /// `AuthService.restoreSession` (called in `main()`, before `runApp`).
  /// Checking both — not just one — matters: Firebase can have a cached
  /// session with no corresponding approval in this app's state (restore
  /// failed, or hasn't run yet), and [AppState.currentUser] only ever gets
  /// set through a path that's already passed Firestore authorization.
  /// Neither signal alone is sufficient; a route is protected only when
  /// both hold. [_landingScreen] uses this same pair of signals to decide
  /// what `login` (this app's `initialRoute`) actually shows.
  ///
  /// Beyond that, an approved user's *role* additionally gates
  /// [_adminOnlyRoutes] against [_guidanceOnlyRoutes]/[_guidanceWebRoutes]
  /// — a `guidance_council` account can never reach the Admin Dashboard,
  /// and a `system_admin` account can never reach the examination
  /// workflow (mobile) or the Guidance Council Web Console, even though
  /// both are otherwise "approved." Each is bounced to their own role's
  /// home screen (see [_guidanceHomeScreen], platform-aware) rather than a
  /// login screen, since they're validly signed in — just not for the
  /// route they asked for.
  ///
  /// `profile` is intentionally left role-neutral (in neither restricted
  /// set) — it only shows the signed-in identity and a logout action, so
  /// there's nothing role-specific to gate. `staffHome` is guidance-only
  /// (in [_guidanceOnlyRoutes]): it's the Guidance Council's own home
  /// screen and entry point into the examination workflow.
  ///
  /// Typing/deep-linking a protected route's name while any of these
  /// checks fail redirects instead of building the requested screen —
  /// hiding a button never was, and still isn't, this app's only line of
  /// defense.
  static Route<dynamic> onGenerateRoute(RouteSettings settings, AppState appState) {
    final name = settings.name;

    if (name != null && !_publicRoutes.contains(name)) {
      final approvedUser = appState.currentUser;
      final isApproved = FirebaseAuth.instance.currentUser != null && approvedUser != null;

      if (!isApproved) {
        return _fade(PlatformUtils.isWeb ? const AdminLoginScreen() : const MobileLoginScreen());
      }

      // Mandatory Mobile Profile Setup: an approved, active guidance_council
      // account whose profile (structured name, display name, Position --
      // see UserModel.isProfileComplete) is not yet complete is redirected
      // here for every named route except profileSetup itself (avoiding a
      // redirect loop). Mobile only -- the Guidance Council Web Console is
      // untouched by this feature. Checked BEFORE the role gates below, so
      // it takes priority over (and is never bypassed by) any of them.
      if (!PlatformUtils.isWeb &&
          approvedUser.role == 'guidance_council' &&
          !approvedUser.isProfileComplete &&
          name != profileSetup) {
        return _fade(const ProfileSetupScreen());
      }

      if (_adminOnlyRoutes.contains(name) && approvedUser.role != 'system_admin') {
        return _fade(_guidanceHomeScreen());
      }

      if ((_guidanceOnlyRoutes.contains(name) || _guidanceWebRoutes.contains(name)) &&
          approvedUser.role != 'guidance_council') {
        // Fire-and-forget: onGenerateRoute must return synchronously, so
        // this audit write isn't (can't be) awaited. LoggingService never
        // throws internally, so this can't affect navigation either way.
        if (approvedUser.role == 'system_admin') {
          LoggingService().logAdminGuidanceRouteDenied(approvedUser, route: name);
        }
        return _fade(const AdminDashboardScreen());
      }
    }

    switch (settings.name) {
      case splash:
        return PageRouteBuilder(
          pageBuilder: (_, __, ___) => const SplashScreen(),
          transitionDuration: Duration.zero,
        );
      case login:
        // This is initialRoute (see main.dart's MaterialApp) — the very
        // first route generated on every cold start, before the guard
        // above ever runs (login is public). _landingScreen is what
        // actually makes AuthService.restoreSession visible to the user:
        // skip straight past the login screen when a session was already
        // restored, instead of always building the login screen here
        // regardless of that.
        return _fade(_landingScreen(appState));
      case mobileLogin:
        return _fade(const MobileLoginScreen());
      case adminLogin:
        return _fade(const AdminLoginScreen());
      case staffHome:
        return tabRoute(staffHome, const StaffHomeScreen());
      case profile:
        return _slide(const ProfileScreen());
      case profileSetup:
        return _fade(const ProfileSetupScreen());
      case examHub:
        return tabRoute(examHub, const ExamHubScreen());
      case examSetup:
        return _slide(ExamSetupScreen(preselectBatchId: settings.arguments as String?));
      case examScanning:
        return _slide(const ExamScanningScreen());
      case examResults:
        return _slide(const ExamResultsScreen());
      case answerKeyEntry:
        return _slide(const AnswerKeyEntryScreen());
      case cloudArchive:
        return tabRoute(cloudArchive, const CloudArchiveScreen());
      case batchArchiveDetail:
        return _slide(BatchArchiveDetailScreen(batchId: settings.arguments as String));
      case qtmBatchAnalytics:
        return _slide(QtmBatchAnalyticsScreen(batchId: settings.arguments as String));
      case tatBatchAnalytics:
        return _slide(TatBatchAnalyticsScreen(batchId: settings.arguments as String));
      case atBatchAnalytics:
        return _slide(AtBatchAnalyticsScreen(batchId: settings.arguments as String));
      case adminDashboard:
        return _fade(const AdminDashboardScreen());
      case examManagement:
        return _fade(const ExamManagementScreen());
      case examSheetPreview:
        return _fade(ExamSheetPreviewScreen(entry: settings.arguments as ExamCatalogEntry));
      case batchManagement:
        return _fade(const BatchManagementScreen());
      case createBatch:
        return _fade(CreateBatchScreen(initialExamCode: settings.arguments as String?));
      case editBatch:
        return _fade(EditBatchScreen(batch: settings.arguments as LocalBatch?));
      case userManagement:
        return _fade(const UserManagementScreen());
      case createUser:
        return _fade(const CreateUserScreen());
      case editUser:
        return _fade(EditUserScreen(user: settings.arguments as UserModel?));
      case systemLogs:
        return _fade(const SystemLogsScreen());
      case guidanceWebHome:
        return _fade(const GuidanceWebHomeScreen());
      default:
        return _fade(_landingScreen(appState));
    }
  }

  /// What `login`/an unrecognized route should actually show: the
  /// already-approved user's own home screen when one exists (same
  /// approve + role signals as the guard above), otherwise the
  /// platform-appropriate login screen. Deliberately not applied to
  /// [mobileLogin]/[adminLogin] — those are explicit "show me this exact
  /// platform's login screen" requests, kept unconditional.
  static Widget _landingScreen(AppState appState) {
    final approvedUser = appState.currentUser;
    final isApproved = FirebaseAuth.instance.currentUser != null && approvedUser != null;
    if (!isApproved) {
      return PlatformUtils.isWeb ? const AdminLoginScreen() : const MobileLoginScreen();
    }
    if (approvedUser.role == 'system_admin') return const AdminDashboardScreen();
    // Same mandatory Mobile Profile Setup check as onGenerateRoute's central
    // guard, duplicated here deliberately: this function is the OTHER
    // dashboard-entry path (cold start / session restore via the public
    // `login` route), which never runs through that guard at all -- see its
    // own doc comment above. Skipping this check here would let an
    // incomplete profile reach the dashboard directly on every app restart.
    if (!PlatformUtils.isWeb && approvedUser.role == 'guidance_council' && !approvedUser.isProfileComplete) {
      return const ProfileSetupScreen();
    }
    return _guidanceHomeScreen();
  }

  /// The Guidance Council's own home screen, platform-appropriate: the
  /// mobile examination workflow's [StaffHomeScreen] on Android/iOS, or the
  /// Web Console's [GuidanceWebHomeScreen] on Web. Used both as the
  /// approved-user landing screen and as the bounce target when a
  /// `guidance_council` account is denied an [_adminOnlyRoutes] route —
  /// this is the platform-aware replacement for what used to
  /// unconditionally return [StaffHomeScreen] (which would have been wrong
  /// to show inside a Web browser once a `guidance_council` account could
  /// be approved on Web at all — see [AdminLoginScreen.
  /// _navigateAfterLogin]).
  static Widget _guidanceHomeScreen() {
    return PlatformUtils.isWeb ? const GuidanceWebHomeScreen() : const StaffHomeScreen();
  }

  /// Left-to-right order of the bottom-nav tabs.
  static const Map<String, int> _tabOrder = {staffHome: 0, examHub: 1, cloudArchive: 2};

  /// The [AppBottomNav] tab id for each tab route.
  static const Map<String, String> _tabNavId = {staffHome: 'home', examHub: 'sheet', cloudArchive: 'cloud'};

  /// The tab last navigated to, so the next tab switch knows which way to
  /// swipe. Home is where a signed-in session starts.
  static int _currentTab = 0;

  /// Which way the swipe in progress is moving (+1 = new page enters from the
  /// right, -1 = from the left, 0 = none). Read by the page being left so it
  /// slides out the opposite way; cleared once the transition is over so a
  /// later, unrelated route pushed on top of a tab doesn't move it.
  static int _swipeDirection = 0;

  static const Duration _tabSwipeDuration = Duration(milliseconds: 280);

  /// Switches to another bottom-nav tab, leaving no history behind it (the
  /// existing tab behaviour).
  ///
  /// When the current tab is the only route on the stack — the normal case,
  /// since every tab switch clears it — this is a replacement, which is what
  /// lets the page being left slide away with the new one. A plain
  /// push-and-remove-everything drops the old page instantly, so it would just
  /// sit there and get covered. If something is still underneath, fall back to
  /// the old clear-everything push (the new page still swipes in).
  static void switchTab(BuildContext context, String route) {
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) {
      navigator.pushReplacementNamed(route);
    } else {
      navigator.pushNamedAndRemoveUntil(route, (_) => false);
    }
  }

  /// Route for one of the bottom-nav tabs: swipes sideways in the direction of
  /// the tab's position (Exams is right of Home, Archive right of Exams), the
  /// page being left sliding away the other way. Re-selecting the current tab
  /// has nothing to swipe towards, so that is a plain fade.
  @visibleForTesting
  static Route<dynamic> tabRoute(String name, Widget child) {
    final target = _tabOrder[name] ?? 0;
    final direction = target.compareTo(_currentTab).sign;
    _currentTab = target;
    if (direction == 0) return _fade(child);
    _swipeDirection = direction;

    final route = PageRouteBuilder<dynamic>(
      pageBuilder: (_, __, ___) => child,
      transitionDuration: _tabSwipeDuration,
      reverseTransitionDuration: _tabSwipeDuration,
      transitionsBuilder: (_, animation, secondaryAnimation, c) {
        final entering = Tween<Offset>(begin: Offset(direction.toDouble(), 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
        final page = _leaving(secondaryAnimation, SlideTransition(position: entering, child: c));
        // The bottom nav belongs to each tab's Scaffold, so it would slide
        // along with the page. Hold a fixed copy over it while the swipe
        // runs, and let the page's own (identical) nav show once it ends.
        return AnimatedBuilder(
          animation: animation,
          builder: (_, __) => Stack(
            children: [
              Positioned.fill(child: page),
              if (!animation.isCompleted)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  // A Scaffold strips the top (status bar) inset before it lays
                  // out its bottom bar; outside one, the nav would add that
                  // padding to its own top and grow upward. Strip it here too
                  // so this copy is exactly the size of the page's own nav.
                  child: Builder(
                    builder: (ctx) => MediaQuery.removePadding(
                      context: ctx,
                      removeTop: true,
                      child: AppBottomNav(activeTab: _tabNavId[name] ?? 'home'),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
    // The swipe is over when the new page has finished arriving; until then
    // the page being left needs to know which way to slide.
    route.completed.whenComplete(() {
      if (_swipeDirection == direction) _swipeDirection = 0;
    });
    return route;
  }

  /// Slides [child] away opposite to the swipe in progress while another tab
  /// is covering it. With no swipe in progress ([_swipeDirection] is 0) this
  /// is a no-op, so a page pushed over a tab later doesn't move it. Shared by
  /// every route a tab can have been opened with (including [_fade], the
  /// landing route), since the page being left always uses its OWN route to
  /// leave.
  static Widget _leaving(Animation<double> secondaryAnimation, Widget child) {
    final leaving = Tween<Offset>(begin: Offset.zero, end: Offset(-_swipeDirection.toDouble(), 0))
        .animate(CurvedAnimation(parent: secondaryAnimation, curve: Curves.easeOutCubic));
    return SlideTransition(position: leaving, child: child);
  }

  static Route<dynamic> _fade(Widget child) {
    return PageRouteBuilder(
      pageBuilder: (_, __, ___) => child,
      transitionsBuilder: (_, animation, secondaryAnimation, c) =>
          _leaving(secondaryAnimation, FadeTransition(opacity: animation, child: c)),
      transitionDuration: const Duration(milliseconds: 220),
    );
  }

  static Route<dynamic> _slide(Widget child) {
    return PageRouteBuilder(
      pageBuilder: (_, __, ___) => child,
      transitionsBuilder: (_, animation, __, c) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: c,
      ),
      transitionDuration: const Duration(milliseconds: 250),
    );
  }
}
