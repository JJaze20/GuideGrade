// Startup logging goes to the console by design (before any UI or logger
// exists); the file has always used `print` for this.
// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;
import 'core/constants/app_theme.dart';
import 'core/routes/app_routes.dart';
import 'core/services/auth_service.dart';
import 'core/services/batch_repository.dart';
import 'core/services/local_batch_repository.dart';
import 'core/services/local_storage_service.dart';
import 'core/state/app_state.dart';
import 'core/sync/supabase_sync_client.dart';
import 'core/sync/sync_manager.dart';
import 'core/sync/sync_queue.dart';
import 'core/sync/syncing_batch_repository.dart';
import 'core/utils/platform_utils.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Every screen (camera viewfinder, forms, bottom nav) is built for a tall,
  // portrait frame -- lock to it rather than leaving layouts to cope with a
  // rotation they were never designed for.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

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

  // Supabase (Phase 3): a data/storage plane authorized by the EXISTING
  // Firebase identity via Supabase's native Firebase third-party auth.
  //
  // - No Supabase Auth is ever used: signInWithPassword / signUp /
  //   signInWithOAuth are never called anywhere. The Firebase ID token is
  //   the bearer, supplied on demand by the [accessToken] callback below;
  //   on logout FirebaseAuth clears currentUser, the callback returns null,
  //   and every Supabase request falls back to anonymous.
  // - URL + publishable (anon) key come from --dart-define and are never
  //   hardcoded. No service_role key or JWT secret is present in the app.
  // - When the defines are absent (a plain `flutter run`), Supabase is left
  //   uninitialized and nothing else in the app is affected.
  const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const supabasePublishableKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  var supabaseReady = false;
  if (supabaseUrl.isNotEmpty && supabasePublishableKey.isNotEmpty) {
    try {
      await Supabase.initialize(
        url: supabaseUrl,
        publishableKey: supabasePublishableKey,
        accessToken: () async {
          final user = FirebaseAuth.instance.currentUser;
          return user == null ? null : await user.getIdToken();
        },
      );
      supabaseReady = true;
      print('Supabase initialized (third-party auth: Firebase)');
    } catch (e) {
      print('Supabase initialization error: $e');
      // Non-fatal: the local-only app keeps working without the cloud plane.
    }
  } else {
    print('Supabase not initialized (SUPABASE_URL / SUPABASE_ANON_KEY not set)');
  }

  // Sync infrastructure (Phase 9B-5A): exactly one SyncManager for the app,
  // wired by constructor injection over the local storage layer. restore()
  // reloads the durable job queue and reconciles it against local truth,
  // but NOTHING is processed or uploaded here — processQueue() / start()
  // are deliberately not called in this phase. With Supabase unconfigured
  // the app behaves exactly as before, on a bare LocalBatchRepository.
  final localStorage = LocalStorageService();
  final localBatchRepository = LocalBatchRepository();
  BatchRepository appBatchRepository = localBatchRepository;
  SyncManager? syncManager;

  if (supabaseReady) {
    final syncQueue = SyncQueue();
    final manager = SyncManager(
      queue: syncQueue,
      client: SupabaseSyncClient(
        batches: localBatchRepository,
        localStorage: localStorage,
        identity: _FirebaseSyncIdentity(),
        // SyncQueue.restore() can swap queue.state, so resolve it lazily.
        getSyncState: () => syncQueue.state,
      ),
      batchRepository: localBatchRepository,
      loadAnswerKeys: localStorage.loadAnswerKeys,
    );
    try {
      await manager.restore();
      print('Sync queue restored (processing NOT started)');
    } catch (e) {
      print('Sync queue restore error: ${e.runtimeType}');
    }
    syncManager = manager;
    appBatchRepository = SyncingBatchRepository(
      local: localBatchRepository,
      syncManager: manager,
    );
  } else {
    print('Sync infrastructure skipped (Supabase not configured)');
  }

  final appState = AppState(
    batchRepository: appBatchRepository,
    syncManager: syncManager,
    // Automatic offline -> online sync: AppState subscribes to this only
    // when a SyncManager exists, and on a disconnected -> connected edge
    // asks it to drain the existing queue (SyncManager.syncNow).
    connectivityStream: Connectivity().onConnectivityChanged,
  );
  await appState.loadPersistedData();

  // Restore an already-approved session from Firebase's own persisted auth
  // state (survives an app restart or kill, independent of network) before
  // the route guard in AppRoutes ever runs — without this, AppState.
  // currentUser (in-memory only) is always null on a fresh process, so
  // every cold start bounced to the login screen even for an already
  // signed-in user, online or off. See AuthService.restoreSession's doc
  // comment for why this never signs the session out on an ambiguous
  // (e.g. offline, nothing cached yet) failure — only a definitive denial.
  try {
    final restored = await AuthService().restoreSession();
    if (restored != null) appState.setCurrentUser(restored);
  } catch (e) {
    print('Session restore failed: $e');
  }

  runApp(GuideGradeApp(appState: appState));
}

/// Bridges Supabase's [SyncIdentity] port to Firebase Auth, kept in
/// `main.dart` so `lib/core/sync` never imports `firebase_auth`. Read-only:
/// it exposes the current uid / display name and can force a token refresh;
/// it never signs in or out.
class _FirebaseSyncIdentity implements SyncIdentity {
  @override
  String? get uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  String? get displayName => FirebaseAuth.instance.currentUser?.displayName;

  @override
  Future<bool> refreshToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await user.getIdToken(true); // force-refresh so the next request re-reads it
    return true;
  }
}

/// Root widget for the Guide Grade app.
///
/// This app supports both mobile (Android/iOS) and web platforms:
/// - Mobile: Uses MobileLoginScreen → Staff Home (Guidance Council)
/// - Web: Uses AdminLoginScreen → Admin Dashboard
///
/// Wraps the whole app in [AppStateScope] so any screen (login,
/// staff home, exam flow, archive, admin) can read/update shared state
/// without prop-drilling. [appState] is constructed and its persisted
/// data loaded in [main] before this widget is built, so the registry
/// never flashes empty before populating.
class GuideGradeApp extends StatefulWidget {
  const GuideGradeApp({super.key, required this.appState});

  final AppState appState;

  @override
  State<GuideGradeApp> createState() => _GuideGradeAppState();
}

class _GuideGradeAppState extends State<GuideGradeApp> {
  @override
  Widget build(BuildContext context) {
    return AppStateScope(
      notifier: widget.appState,
      child: MaterialApp(
        title: PlatformUtils.isWeb ? 'GuideGrade Admin Console' : 'GuideGrade',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        initialRoute: AppRoutes.login,
        onGenerateRoute: (settings) => AppRoutes.onGenerateRoute(settings, widget.appState),
      ),
    );
  }
}
