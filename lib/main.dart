import 'package:flutter/material.dart';

import 'package:firebase_core/firebase_core.dart';
import 'core/constants/app_theme.dart';
import 'core/routes/app_routes.dart';
import 'core/state/app_state.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const GuideGradeApp());
}

/// Root widget for the Guide Grade mobile app.
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
        title: 'Guide Grade',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        initialRoute: AppRoutes.login,
        onGenerateRoute: AppRoutes.onGenerateRoute,
      ),
    );
  }
}
