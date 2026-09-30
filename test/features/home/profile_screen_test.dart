import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/home/screens/profile_screen.dart';
import 'package:guidegrade/models/guidance_position.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/user.dart';

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
/// `profile_setup_screen_test.dart`'s `_FakeFirestoreService` already uses.
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
  late AppState appState;
  late _FakeFirestoreService firestoreService;

  setUp(() {
    appState = AppState(batchRepository: _FakeBatchRepository());
    firestoreService = _FakeFirestoreService();
  });

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    // Tall enough that the edit form (5 fields + Save/Cancel) is fully on
    // screen without scrolling -- the same fix `profile_setup_screen_test`
    // already uses, since the default 800x600 test viewport puts the lower
    // fields/buttons off-screen and tap() can't hit them there.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: ProfileScreen(firestoreService: firestoreService),
      ),
    );
    await tester.pumpAndSettle();
  }

  UserModel completeUser({
    String userId = 'gc-1',
    String email = 'staff@ndmu.edu.ph',
    String displayName = 'Juan Dela Cruz',
    String? firstName = 'Juan',
    String? middleInitial = 'D.',
    String? lastName = 'Dela Cruz',
    String? guidancePosition = 'guidance_head',
  }) =>
      UserModel(
        userId: userId,
        email: email,
        displayName: displayName,
        role: 'guidance_council',
        guidancePosition: guidancePosition,
        isActive: true,
        createdAt: DateTime.utc(2026),
        firstName: firstName,
        middleInitial: middleInitial,
        lastName: lastName,
      );

  Future<void> enterEditMode(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('profile.editButton')));
    await tester.pumpAndSettle();
  }

  Future<void> selectPosition(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const Key('profile.position')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> tapSave(WidgetTester tester) async {
    final button = find.byKey(const Key('profile.saveButton'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('shows the Firestore UserModel.displayName, not a fallback, for a signed-in user',
      (tester) async {
    appState.setCurrentUser(UserModel(
      userId: 'gc-1',
      email: 'staff@ndmu.edu.ph',
      displayName: 'Juan Dela Cruz',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ));
    await pumpScreen(tester);

    // 'Juan Dela Cruz' appears twice: once as the header name, and again in
    // the Profile Information card's own Display Name row.
    expect(find.text('Juan Dela Cruz'), findsNWidgets(2));
    expect(find.text('staff@ndmu.edu.ph'), findsOneWidget);
    expect(find.text('NDMU Staff Officer'), findsNothing);
  });

  testWidgets('falls back to the placeholder when displayName is blank', (tester) async {
    appState.setCurrentUser(UserModel(
      userId: 'gc-1',
      email: 'staff@ndmu.edu.ph',
      displayName: '   ',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ));
    await pumpScreen(tester);

    expect(find.text('NDMU Staff Officer'), findsOneWidget);
  });

  testWidgets('falls back to the placeholder when nobody is signed in', (tester) async {
    await pumpScreen(tester);
    expect(find.text('NDMU Staff Officer'), findsOneWidget);
  });

  testWidgets('shows First Name, Middle Initial, Last Name, Display Name and Position', (tester) async {
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);

    expect(find.text('First Name'), findsOneWidget);
    expect(find.text('Juan'), findsOneWidget);
    expect(find.text('Middle Initial'), findsOneWidget);
    expect(find.text('D.'), findsOneWidget);
    expect(find.text('Last Name'), findsOneWidget);
    expect(find.text('Dela Cruz'), findsOneWidget);
    expect(find.text('Display Name'), findsOneWidget);
    // 'Juan Dela Cruz' already appears once as the header name -- Display
    // Name reuses the exact same string, so this account is shown twice.
    expect(find.text('Juan Dela Cruz'), findsNWidgets(2));
    expect(find.text('Position'), findsOneWidget);
    expect(find.text('Guidance Head'), findsOneWidget);
  });

  testWidgets('shows "Not set" for missing First Name, Middle Initial, Last Name and Position',
      (tester) async {
    appState.setCurrentUser(UserModel(
      userId: 'gc-2',
      email: 'staff2@ndmu.edu.ph',
      displayName: 'Maria Santos',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ));
    await pumpScreen(tester);

    expect(find.text('Not set'), findsNWidgets(4));
    // Header name + Display Name row -- same reasoning as the test above.
    expect(find.text('Maria Santos'), findsNWidgets(2));
  });

  testWidgets('the Edit action is not shown when nobody is signed in', (tester) async {
    await pumpScreen(tester);
    expect(find.byKey(const Key('profile.editButton')), findsNothing);
  });

  testWidgets('tapping Edit opens edit mode pre-filled with the current values', (tester) async {
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);
    await enterEditMode(tester);

    final firstNameField = tester.widget<TextFormField>(find.byKey(const Key('profile.firstName')));
    expect(firstNameField.controller!.text, 'Juan');
    final lastNameField = tester.widget<TextFormField>(find.byKey(const Key('profile.lastName')));
    expect(lastNameField.controller!.text, 'Dela Cruz');
    final middleInitialField = tester.widget<TextFormField>(find.byKey(const Key('profile.middleInitial')));
    expect(middleInitialField.controller!.text, 'D.');
    final displayNameField = tester.widget<TextFormField>(find.byKey(const Key('profile.displayName')));
    expect(displayNameField.controller!.text, 'Juan Dela Cruz');
  });

  testWidgets('the Position dropdown in edit mode offers only the three canonical choices', (tester) async {
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);
    await enterEditMode(tester);

    await tester.tap(find.byKey(const Key('profile.position')));
    await tester.pumpAndSettle();
    expect(find.text('Guidance Head'), findsWidgets);
    expect(find.text('Psychometrician'), findsWidgets);
    expect(find.text('Guidance Staff'), findsWidgets);
  });

  testWidgets('a valid edit is saved via FirestoreService.updateOwnProfile and reflected immediately',
      (tester) async {
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);
    await enterEditMode(tester);

    await tester.enterText(find.byKey(const Key('profile.firstName')), 'Maria');
    await tester.enterText(find.byKey(const Key('profile.lastName')), 'Santos');
    await tester.enterText(find.byKey(const Key('profile.middleInitial')), 'L.');
    await tester.enterText(find.byKey(const Key('profile.displayName')), 'Maria Santos');
    await selectPosition(tester, 'Psychometrician');
    await tapSave(tester);

    expect(firestoreService.calls, hasLength(1));
    final call = firestoreService.calls.single;
    expect(call.firstName, 'Maria');
    expect(call.lastName, 'Santos');
    expect(call.middleInitial, 'L.');
    expect(call.displayName, 'Maria Santos');
    expect(call.guidancePosition, 'psychometrician');

    // AppState.currentUser reflects the change immediately -- no re-login.
    final updated = appState.currentUser!;
    expect(updated.userId, 'gc-1', reason: 'same account, never a new one');
    expect(updated.firstName, 'Maria');
    expect(updated.guidancePosition, 'psychometrician');

    // Back in the read-only view, showing the newly saved values.
    expect(find.byKey(const Key('profile.saveButton')), findsNothing);
    expect(find.text('Maria'), findsOneWidget);
    expect(find.text('Psychometrician'), findsOneWidget);
  });

  testWidgets('missing First Name in edit mode is rejected using the same validation as Profile Setup',
      (tester) async {
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);
    await enterEditMode(tester);

    await tester.enterText(find.byKey(const Key('profile.firstName')), '   ');
    await tapSave(tester);

    expect(find.text('First Name is required'), findsOneWidget);
    expect(firestoreService.calls, isEmpty);
  });

  testWidgets('an invalid Middle Initial in edit mode is rejected', (tester) async {
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);
    await enterEditMode(tester);

    await tester.enterText(find.byKey(const Key('profile.middleInitial')), 'Dela');
    await tapSave(tester);

    expect(find.text('Enter a single letter, e.g. D or D.'), findsOneWidget);
    expect(firestoreService.calls, isEmpty);
  });

  testWidgets('a save failure keeps entered data and shows an error, without leaving edit mode',
      (tester) async {
    firestoreService.errorToThrow = Exception('network down');
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);
    await enterEditMode(tester);

    await tester.enterText(find.byKey(const Key('profile.firstName')), 'Maria');
    await tapSave(tester);

    expect(find.textContaining('Could not save'), findsOneWidget);
    final firstNameField = tester.widget<TextFormField>(find.byKey(const Key('profile.firstName')));
    expect(firstNameField.controller!.text, 'Maria', reason: 'entered data is preserved after a failed save');
    expect(appState.currentUser!.firstName, 'Juan', reason: 'AppState is untouched until a save succeeds');
  });

  testWidgets('Cancel discards changes and does not save', (tester) async {
    appState.setCurrentUser(completeUser());
    await pumpScreen(tester);
    await enterEditMode(tester);

    await tester.enterText(find.byKey(const Key('profile.firstName')), 'Something Else');
    await tester.tap(find.byKey(const Key('profile.cancelButton')));
    await tester.pumpAndSettle();

    expect(firestoreService.calls, isEmpty);
    expect(appState.currentUser!.firstName, 'Juan', reason: 'unchanged -- Cancel never wrote anything');
    // Back to the read-only view, still showing the original value.
    expect(find.byKey(const Key('profile.firstName')), findsNothing);
    expect(find.text('Juan'), findsOneWidget);
  });

  testWidgets('a custom position (e.g. one a System Admin added) displays its configured label, not "Not set"',
      (tester) async {
    firestoreService.positions = [
      ...GuidancePositions.defaults,
      const GuidancePosition(value: 'auditing', label: 'Auditing'),
    ];
    appState.setCurrentUser(completeUser(guidancePosition: 'auditing'));
    await pumpScreen(tester);

    expect(find.text('Auditing'), findsOneWidget);
    expect(find.text('Not set'), findsNothing);
  });

  testWidgets(
      'a custom position not (yet) recognized by the loaded configuration shows the raw stored value '
      'instead of "Not set" -- it is present, just unrecognized here', (tester) async {
    // firestoreService.positions is left at the 3 defaults -- "auditing" is
    // not among them, simulating a stale/failed configuration read.
    appState.setCurrentUser(completeUser(guidancePosition: 'auditing'));
    await pumpScreen(tester);

    expect(find.text('auditing'), findsOneWidget);
    expect(find.text('Not set'), findsNothing);
  });

  testWidgets('an existing custom position remains selected when entering edit mode', (tester) async {
    firestoreService.positions = [
      ...GuidancePositions.defaults,
      const GuidancePosition(value: 'auditing', label: 'Auditing'),
    ];
    appState.setCurrentUser(completeUser(guidancePosition: 'auditing'));
    await pumpScreen(tester);
    await enterEditMode(tester);

    expect(find.text('Auditing'), findsOneWidget, reason: 'shown as the dropdown\'s current selection');

    await tapSave(tester);
    expect(firestoreService.calls.single.guidancePosition, 'auditing', reason: 'unchanged, but still saveable');
  });
}
