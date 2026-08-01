import 'package:flutter/material.dart';

import 'package:firebase_core/firebase_core.dart';
import 'core/constants/app_theme.dart';
import 'core/routes/app_routes.dart';
import 'core/state/app_state.dart';
import 'core/utils/platform_utils.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  print('=== GuideGrade Startup ===');
  print('Platform: ${PlatformUtils.platformType}');
  print('Is Web: ${PlatformUtils.isWeb}');
  
  // Initialize Firebase for all platforms
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    print('Firebase initialized successfully');
  } catch (e) {
    print('Firebase initialization error: $e');
    // Continue even if Firebase fails - allows UI to render
  }
  
  runApp(const GuideGradeApp());
}

/// Root widget for the Guide Grade app.
///
/// This app supports both mobile (Android/iOS) and web platforms:
/// - Mobile: Uses MobileLoginScreen → Staff Home (Guidance Council)
/// - Web: Uses AdminLoginScreen → Admin Dashboard
///
/// Wraps the whole app in [AppStateScope] so any screen (login,
/// staff home, exam flow, archive, admin) can read/update shared
/// mock data without prop-drilling.
class GuideGradeApp extends StatefulWidget {
  const GuideGradeApp({super.key});

  @override
  State<GuideGradeApp> createState() => _GuideGradeAppState();
}

class _GuideGradeAppState extends State<GuideGradeApp> {
  final AppState _appState = AppState();

  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: _appState,
      child: MaterialApp(
        title: PlatformUtils.isWeb ? 'GuideGrade Admin Console' : 'GuideGrade',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        initialRoute: AppRoutes.login,
        onGenerateRoute: AppRoutes.onGenerateRoute,
      ),
    );
  }
}
