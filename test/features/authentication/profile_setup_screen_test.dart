import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/authentication/screens/profile_setup_screen.dart';
import 'package:guidegrade/models/guidance_position.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/user.dart';
import 'package:guidegrade/shared/widgets/primary_button.dart';

class _Call {
  _Call({
    required this.firstName,
    required this.lastName,
    required this.middleInitial,
    required this.displayName,
    required this.guidancePosition,
  });

  final String firstName;
  final String lastName;
  final String middleInitial;
  final String displayName;
  final String guidancePosition;
}

/// Never reaches real Firebase/Firestore -- the same pattern
/// `create_user_screen_test.dart`'s `_FakeProvisioningService` already uses
/// for `UserProvisioningService`.
class _FakeFirestoreService implements FirestoreService {
  final calls = <_Call>[];
  Object? errorToThrow;
  List<GuidancePosition> positions = GuidancePositions.defaults;

  @override
  Future<List<GuidancePosition>> loadGuidancePositions() async => positions;

  @override
  Future<void> updateOwnProfile({
    required String firstName,
    required String lastName,
    required String middleInitial,
    required String displayName,
    required String guidancePosition,
  }) async {
    if (errorToThrow != null) throw errorToThrow!;
    calls.add(_Call(
      firstName: firstName,
      lastName: lastName,
      middleInitial: middleInitial,
      displayName: displayName,
      guidancePosition: guidancePosition,
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeBatchRepository implements BatchRepository {
  @override
  Future<List<LocalBatch>> getBatches() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeFirestoreService firestoreService;
  late AppState appState;

  UserModel incompleteUser({
    String? firstName,
    String? lastName,
    String? middleInitial,
    String displayName = '',
    String? guidancePosition,
  }) =>
      UserModel(
        userId: 'gc-1',
        email: 'staff@ndmu.edu.ph',
        displayName: displayName,
        role: 'guidance_council',
        isActive: true,
        createdAt: DateTime.utc(2026),
        firstName: firstName,
        lastName: lastName,
        middleInitial: middleInitial,
        guidancePosition: guidancePosition,
      );

  setUp(() {
    firestoreService = _FakeFirestoreService();
    appState = AppState(batchRepository: _FakeBatchRepository());
    appState.setCurrentUser(incompleteUser());
  });

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
  });

  /// A minimal MaterialApp with its own tiny named-route table -- NOT the
  /// real AppRoutes.onGenerateRoute, which touches FirebaseAuth.instance
  /// (uninitialized, and unmockable without a Firebase test harness this
  /// repository does not have) and would crash in a plain unit test. This
  /// only needs to observe whether ProfileSetupScreen actually navigated to
  /// '/staff-home' after a successful save.
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        initialRoute: '/profile-setup',
        onGenerateRoute: (settings) {
          if (settings.name == '/profile-setup') {
            return MaterialPageRoute(
              builder: (_) => ProfileSetupScreen(firestoreService: firestoreService),
            );
          }
          if (settings.name == '/staff-home') {
            return MaterialPageRoute(builder: (_) => const Scaffold(body: Text('STAFF HOME')));
          }
          return null;
        },
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fill(
    WidgetTester tester, {
    String first = 'Juan',
    String mi = 'D.',
    String last = 'Dela Cruz',
    String display = 'Juan Dela Cruz',
  }) async {
    await tester.enterText(find.byKey(const Key('profileSetup.firstName')), first);
    await tester.enterText(find.byKey(const Key('profileSetup.middleInitial')), mi);
    await tester.enterText(find.byKey(const Key('profileSetup.lastName')), last);
    await tester.enterText(find.byKey(const Key('profileSetup.displayName')), display);
  }

  Future<void> selectPosition(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const Key('profileSetup.position')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    final button = find.byType(PrimaryButton);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('shows all five required fields and explains completion is required', (tester) async {
    await pumpScreen(tester);
    expect(find.text('First Name'), findsOneWidget);
    expect(find.text('Last Name'), findsOneWidget);
    expect(find.text('Middle Initial'), findsOneWidget);
    expect(find.text('Display Name'), findsOneWidget);
    expect(find.text('Position'), findsOneWidget);
    expect(find.textContaining('required'), findsWidgets);
  });

  testWidgets('missing First Name is rejected', (tester) async {
    await pumpScreen(tester);
    await fill(tester, first: '   ');
    await selectPosition(tester, 'Guidance Staff');
    await submit(tester);
    expect(find.text('First Name is required'), findsOneWidget);
    expect(firestoreService.calls, isEmpty);
  });

  testWidgets('missing Last Name is rejected', (tester) async {
    await pumpScreen(tester);
    await fill(tester, last: '');
    await selectPosition(tester, 'Guidance Staff');
    await submit(tester);
    expect(find.text('Last Name is required'), findsOneWidget);
    expect(firestoreService.calls, isEmpty);
  });

  testWidgets('an invalid Middle Initial is rejected', (tester) async {
    await pumpScreen(tester);
    await fill(tester, mi: 'Dela');
    await selectPosition(tester, 'Guidance Staff');
    await submit(tester);
    expect(find.text('Enter a single letter, e.g. D or D.'), findsOneWidget);
    expect(firestoreService.calls, isEmpty);
  });

  testWidgets('missing Display Name is rejected', (tester) async {
    await pumpScreen(tester);
    await fill(tester, display: '   ');
    await selectPosition(tester, 'Guidance Staff');
    await submit(tester);
    expect(find.text('This field is required'), findsOneWidget);
    expect(firestoreService.calls, isEmpty);
  });

  testWidgets('missing Position is rejected', (tester) async {
    await pumpScreen(tester);
    await fill(tester);
    await submit(tester);
    expect(find.text('Position is required'), findsOneWidget);
    expect(firestoreService.calls, isEmpty);
  });

  testWidgets('the Position dropdown offers only the three canonical choices', (tester) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const Key('profileSetup.position')));
    await tester.pumpAndSettle();
    expect(find.text('Guidance Head'), findsWidgets);
    expect(find.text('Psychometrician'), findsWidgets);
    expect(find.text('Guidance Staff'), findsWidgets);
  });

  testWidgets('a valid profile is accepted, saved, and navigates to the dashboard', (tester) async {
    await pumpScreen(tester);
    await fill(tester);
    await selectPosition(tester, 'Guidance Staff');
    await submit(tester);

    expect(firestoreService.calls, hasLength(1));
    final call = firestoreService.calls.single;
    expect(call.firstName, 'Juan');
    expect(call.lastName, 'Dela Cruz');
    expect(call.middleInitial, 'D.');
    expect(call.displayName, 'Juan Dela Cruz');
    expect(call.guidancePosition, 'guidance_staff');
    expect(find.text('STAFF HOME'), findsOneWidget, reason: 'navigated to the dashboard after saving');
  });

  testWidgets('successful save updates AppState.currentUser in place -- no re-login required', (tester) async {
    await pumpScreen(tester);
    await fill(tester);
    await selectPosition(tester, 'Guidance Staff');
    await submit(tester);

    final updated = appState.currentUser!;
    expect(updated.userId, 'gc-1', reason: 'same account, never a new one');
    expect(updated.firstName, 'Juan');
    expect(updated.lastName, 'Dela Cruz');
    expect(updated.middleInitial, 'D.');
    expect(updated.displayName, 'Juan Dela Cruz');
    expect(updated.guidancePosition, 'guidance_staff');
    expect(updated.isProfileComplete, isTrue);
  });

  testWidgets('a save failure leaves the form usable and keeps entered data', (tester) async {
    firestoreService.errorToThrow = Exception('network down');
    await pumpScreen(tester);
    await fill(tester);
    await selectPosition(tester, 'Guidance Staff');
    await submit(tester);

    expect(find.textContaining('Could not save'), findsOneWidget);
    expect(find.text('STAFF HOME'), findsNothing, reason: 'never navigated away on failure');
    final firstNameField = tester.widget<TextFormField>(find.byKey(const Key('profileSetup.firstName')));
    expect(firstNameField.controller!.text, 'Juan', reason: 'entered data is preserved after a failed save');
  });

  testWidgets('duplicate submission is prevented while a save is in flight', (tester) async {
    await pumpScreen(tester);
    await fill(tester);
    await selectPosition(tester, 'Guidance Staff');

    final button = find.byType(PrimaryButton);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.tap(button); // a second tap before the first save resolves
    await tester.pumpAndSettle();

    expect(firestoreService.calls, hasLength(1), reason: 'only one write, despite two taps');
  });

  testWidgets('pre-fills already-entered fields for a partially completed profile', (tester) async {
    appState.setCurrentUser(incompleteUser(
      firstName: 'Juan',
      lastName: 'Dela Cruz',
      middleInitial: 'D.',
      displayName: 'Juan Dela Cruz',
      // Position still missing -- this is exactly what makes the account
      // incomplete despite already having a name.
    ));
    await pumpScreen(tester);

    final firstNameField = tester.widget<TextFormField>(find.byKey(const Key('profileSetup.firstName')));
    expect(firstNameField.controller!.text, 'Juan');
    final lastNameField = tester.widget<TextFormField>(find.byKey(const Key('profileSetup.lastName')));
    expect(lastNameField.controller!.text, 'Dela Cruz');
  });

  testWidgets('there is no Cancel/Skip action, and the back gesture is blocked (PopScope canPop: false)',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Skip'), findsNothing);

    final popScope = tester.widget<PopScope>(find.byType(PopScope));
    expect(popScope.canPop, isFalse);
  });

  testWidgets(
      'an account already holding a custom position (e.g. one a System Admin added) keeps it pre-filled '
      'and can be re-saved -- it is never discarded just for being outside the original three', (tester) async {
    appState.setCurrentUser(incompleteUser(
      firstName: 'Juan',
      lastName: 'Dela Cruz',
      middleInitial: 'D.',
      displayName: 'Juan Dela Cruz',
      guidancePosition: 'auditing',
    ));
    await pumpScreen(tester);

    // GuidancePositions.ensureIncludes adds a synthetic entry for the raw
    // stored value so the dropdown can show it as selected without
    // crashing, even though the fake's loaded list is just the 3 defaults.
    expect(find.text('auditing'), findsOneWidget);

    await submit(tester);
    expect(firestoreService.calls.single.guidancePosition, 'auditing');
  });

  testWidgets('a newly-added position (returned by the configuration load) appears in the dropdown',
      (tester) async {
    firestoreService.positions = [
      ...GuidancePositions.defaults,
      const GuidancePosition(value: 'auditing', label: 'Auditing'),
    ];
    await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('profileSetup.position')));
    await tester.pumpAndSettle();
    expect(find.text('Auditing'), findsWidgets);
  });

  testWidgets(
      'Profile Setup does not depend on the position configuration having loaded -- the form is usable '
      'and validates synchronously even before that future resolves', (tester) async {
    // No pumpAndSettle here: only enough pumps to build the widget once,
    // deliberately not draining the microtask queue the position load's
    // Future lives on.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        initialRoute: '/profile-setup',
        onGenerateRoute: (settings) => MaterialPageRoute(
          builder: (_) => ProfileSetupScreen(firestoreService: firestoreService),
        ),
      ),
    );
    await tester.pump();

    // The form (and its synchronous, Firestore-config-independent
    // validation -- UserModel.isProfileComplete never reads Firestore) is
    // already fully present and interactive on this very first frame.
    expect(find.byKey(const Key('profileSetup.firstName')), findsOneWidget);
    expect(find.byType(PrimaryButton), findsOneWidget);

    // Let any pending timers/futures settle so the test harness doesn't
    // warn about a pending Future after the test body returns.
    await tester.pumpAndSettle();
  });
}
