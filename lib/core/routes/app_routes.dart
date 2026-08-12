import 'package:flutter/material.dart';

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
import '../../features/admin/screens/admin_dashboard_screen.dart';
import '../../features/guidance/screens/exam_management_screen.dart';
import '../../features/guidance/screens/create_exam_screen.dart';
import '../../features/guidance/screens/edit_exam_screen.dart';
import '../../features/guidance/screens/answer_key_management_screen.dart';
import '../../features/guidance/screens/batch_management_screen.dart';
import '../../features/guidance/screens/create_batch_screen.dart';
import '../../features/guidance/screens/edit_batch_screen.dart';
import '../../features/guidance/screens/examinee_management_screen.dart';
import '../../features/guidance/screens/create_examinee_screen.dart';
import '../../features/guidance/screens/edit_examinee_screen.dart';
import '../../models/exam.dart';
import '../../models/batch.dart';
import '../../models/examinee.dart';

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
  static const String adminDashboard = '/admin-dashboard';
  static const String examManagement = '/exam-management';
  static const String createExam = '/create-exam';
  static const String editExam = '/edit-exam';
  static const String answerKeyManagement = '/answer-key-management';
  static const String batchManagement = '/batch-management';
  static const String createBatch = '/create-batch';
  static const String editBatch = '/edit-batch';
  static const String examineeManagement = '/examinee-management';
  static const String createExaminee = '/create-examinee';
  static const String editExaminee = '/edit-examinee';

  /// Generates routes for [MaterialApp.onGenerateRoute]. Using this
  /// approach (rather than a static `routes` map) lets us pass
  /// arguments cleanly to screens like Exam Setup/Results.
  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
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
      case adminDashboard:
        return _fade(const AdminDashboardScreen());
      case examManagement:
        return _fade(const ExamManagementScreen());
      case createExam:
        return _fade(const CreateExamScreen());
      case editExam:
        return _fade(EditExamScreen(exam: settings.arguments as ExamModel?));
      case answerKeyManagement:
        return _fade(AnswerKeyManagementScreen(exam: settings.arguments as ExamModel?));
      case batchManagement:
        return _fade(const BatchManagementScreen());
      case createBatch:
        return _fade(const CreateBatchScreen());
      case editBatch:
        return _fade(EditBatchScreen(batch: settings.arguments as BatchModel?));
      case examineeManagement:
        return _fade(const ExamineeManagementScreen());
      case createExaminee:
        return _fade(CreateExamineeScreen(batch: settings.arguments as BatchModel?));
      case editExaminee:
        return _fade(EditExamineeScreen(examinee: settings.arguments as ExamineeModel?));
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
