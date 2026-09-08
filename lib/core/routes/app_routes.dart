import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/logging_service.dart';
import '../../core/state/app_state.dart';
import '../../core/utils/platform_utils.dart';
import '../../features/authentication/screens/mobile_login_screen.dart';
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
import '../constants/exam_catalog.dart';
import '../../models/local_batch.dart';
import '../../models/user.dart';

/// Centralized route names. Keeping these as constants avoids typos
/// when navigating between feature modules.
class AppRoutes {
  AppRoutes._();

  static const String login = '/login';
  static const String mobileLogin = '/mobile-login';
  static const String adminLogin = '/admin-login';
  static const String staffHome = '/staff-home';
  static const String profile = '/profile';
  static const String examHub = '/exam-hub';
  static const String examSetup = '/exam-setup';
  static const String examScanning = '/exam-scanning';
  static const String examResults = '/exam-results';
  static const String answerKeyEntry = '/answer-key-entry';
  static const String cloudArchive = '/cloud-archive';
  static const String batchArchiveDetail = '/batch-archive-detail';
  static const String qtmBatchAnalytics = '/qtm-batch-analytics';
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

  /// Routes reachable without being signed in at all.
  static const Set<String> _publicRoutes = {login, mobileLogin, adminLogin};

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
  };

  /// Generates routes for [MaterialApp.onGenerateRoute]. Using this
  /// approach (rather than a static `routes` map) lets us pass
  /// arguments cleanly to screens like Exam Setup/Results.
  ///
  /// [appState] gates every non-public route on both Firebase's own auth
  /// state (`FirebaseAuth.instance.currentUser`) and the Firestore-approved
  /// [AppState.currentUser] set by a successful login (see
  /// `AuthService._authorize`). Checking both — not just one — matters:
  /// Firebase can have a cached session with no corresponding approval in
  /// this app's state (e.g. a fresh app launch, since there is no session
  /// restore), and [AppState.currentUser] only ever gets set through a
  /// login screen that has already passed Firestore authorization. Neither
  /// signal alone is sufficient; a route is protected only when both hold.
  ///
  /// Beyond that, an approved user's *role* additionally gates
  /// [_adminOnlyRoutes] and [_guidanceOnlyRoutes] against each other — a
  /// `guidance_council` account can never reach the Admin Dashboard, and a
  /// `system_admin` account can never reach the examination workflow, even
  /// though both are otherwise "approved." Each is bounced to their own
  /// role's home screen rather than a login screen, since they're validly
  /// signed in — just not for the route they asked for.
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

      if (_adminOnlyRoutes.contains(name) && approvedUser.role != 'system_admin') {
        return _fade(const StaffHomeScreen());
      }

      if (_guidanceOnlyRoutes.contains(name) && approvedUser.role != 'guidance_council') {
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
      case login:
        // Platform-specific login screen
        return _fade(PlatformUtils.isWeb ? const AdminLoginScreen() : const MobileLoginScreen());
      case mobileLogin:
        return _fade(const MobileLoginScreen());
      case adminLogin:
        return _fade(const AdminLoginScreen());
      case staffHome:
        return _fade(const StaffHomeScreen());
      case profile:
        return _slide(const ProfileScreen());
      case examHub:
        return _fade(const ExamHubScreen());
      case examSetup:
        return _slide(const ExamSetupScreen());
      case examScanning:
        return _slide(const ExamScanningScreen());
      case examResults:
        return _slide(const ExamResultsScreen());
      case answerKeyEntry:
        return _slide(const AnswerKeyEntryScreen());
      case cloudArchive:
        return _fade(const CloudArchiveScreen());
      case batchArchiveDetail:
        return _slide(BatchArchiveDetailScreen(batchId: settings.arguments as String));
      case qtmBatchAnalytics:
        return _slide(QtmBatchAnalyticsScreen(batchId: settings.arguments as String));
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
      default:
        return _fade(PlatformUtils.isWeb ? const AdminLoginScreen() : const MobileLoginScreen());
    }
  }

  static Route<dynamic> _fade(Widget child) {
    return PageRouteBuilder(
      pageBuilder: (_, __, ___) => child,
      transitionsBuilder: (_, animation, __, c) => FadeTransition(opacity: animation, child: c),
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
