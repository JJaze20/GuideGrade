import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/core/services/user_provisioning_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/admin/screens/create_user_screen.dart';
import 'package:guidegrade/models/guidance_position.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/user.dart';
import 'package:guidegrade/shared/widgets/primary_button.dart';

class _Call {
  _Call({
    required this.email,
    required this.displayName,
    required this.firstName,
    required this.middleInitial,
    required this.lastName,
    required this.guidancePosition,
  });

  final String email;
  final String displayName;
  final String firstName;
  final String middleInitial;
  final String lastName;
  final String? guidancePosition;
}

class _FakeProvisioningService implements UserProvisioningService {
  final calls = <_Call>[];

  @override
  Future<UserModel> createGuidanceCouncilUser({
    required String email,
    String displayName = '',
    String firstName = '',
    String middleInitial = '',
    String lastName = '',
    required UserModel actor,
    String? guidancePosition,
    String institution = 'NDMU',
  }) async {
    calls.add(_Call(
      email: email,
      displayName: displayName,
      firstName: firstName,
      middleInitial: middleInitial,
      lastName: lastName,
      guidancePosition: guidancePosition,
    ));
    return UserModel(
      userId: 'new',
      email: email,
      displayName: displayName,
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    );
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

/// Never reaches real Firestore -- returns a fixed position list, and
/// records every [addGuidancePosition] call so tests can assert on it
/// without touching Firebase.
class _FakeFirestoreService implements FirestoreService {
  _FakeFirestoreService([List<GuidancePosition>? positions]) : _positions = positions ?? GuidancePositions.defaults;

  List<GuidancePosition> _positions;
  final addedLabels = <String>[];
  Object? addErrorToThrow;

  @override
  Future<List<GuidancePosition>> loadGuidancePositions() async => _positions;

  @override
  Future<void> ensureDefaultGuidancePositionsSeeded() async {}

  @override
  Future<GuidancePosition> addGuidancePosition(String label, List<GuidancePosition> existingPositions) async {
    if (addErrorToThrow != null) throw addErrorToThrow!;
    final error = GuidancePositions.validateNewLabel(label, existingPositions);
    if (error != null) throw ArgumentError(error);
    final added = GuidancePositions.build(label);
    addedLabels.add(label);
    _positions = [..._positions, added];
    return added;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _FakeProvisioningService service;
  late _FakeFirestoreService firestoreService;
  late AppState appState;

  setUp(() {
    service = _FakeProvisioningService();
    firestoreService = _FakeFirestoreService();
    appState = AppState(batchRepository: _FakeBatchRepository());
    appState.setCurrentUser(UserModel(
      userId: 'admin-1',
      email: 'admin@ndmu.edu.ph',
      displayName: 'Admin',
      role: 'system_admin',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ));
  });

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
  });

  Future<void> openScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => CreateUserScreen(
                      provisioningService: service,
                      firestoreService: firestoreService,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> fill(
    WidgetTester tester, {
    String first = 'Juan',
    String mi = 'D.',
    String last = 'Dela Cruz',
    String display = 'J. Dela Cruz',
    String email = 'staff@ndmu.edu.ph',
  }) async {
    await tester.enterText(find.byKey(const Key('createUser.firstName')), first);
    await tester.enterText(find.byKey(const Key('createUser.middleInitial')), mi);
    await tester.enterText(find.byKey(const Key('createUser.lastName')), last);
    await tester.enterText(find.byKey(const Key('createUser.displayName')), display);
    await tester.enterText(find.byKey(const Key('createUser.email')), email);
  }

  Future<void> submit(WidgetTester tester) async {
    final button = find.byType(PrimaryButton);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('shows First Name, Middle Initial, Last Name and keeps Display Name', (tester) async {
    await openScreen(tester);
    expect(find.text('First Name'), findsOneWidget);
    expect(find.text('Middle Initial'), findsOneWidget);
    expect(find.text('Last Name'), findsOneWidget);
    expect(find.text('Display Name'), findsOneWidget);
  });

  testWidgets('a blank First Name is rejected', (tester) async {
    await openScreen(tester);
    await fill(tester, first: '   ');
    await submit(tester);
    expect(find.text('First Name is required'), findsOneWidget);
    expect(service.calls, isEmpty);
  });

  testWidgets('a blank Last Name is rejected', (tester) async {
    await openScreen(tester);
    await fill(tester, last: '');
    await submit(tester);
    expect(find.text('Last Name is required'), findsOneWidget);
    expect(service.calls, isEmpty);
  });

  testWidgets('a blank Middle Initial is rejected', (tester) async {
    await openScreen(tester);
    await fill(tester, mi: '');
    await submit(tester);
    expect(find.text('Middle Initial is required'), findsOneWidget);
    expect(service.calls, isEmpty);
  });

  testWidgets('a full middle name (or digits) is rejected as Middle Initial', (tester) async {
    for (final bad in ['Dela', '1', 'D..']) {
      await openScreen(tester);
      await fill(tester, mi: bad);
      await submit(tester);
      expect(find.text('Enter a single letter, e.g. D or D.'), findsOneWidget, reason: '"$bad"');
      expect(service.calls, isEmpty, reason: '"$bad"');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('"J" and "J." are both accepted and stored as "J."', (tester) async {
    for (final ok in ['J', 'J.']) {
      service.calls.clear();
      await openScreen(tester);
      await fill(tester, mi: ok);
      await submit(tester);
      expect(service.calls, hasLength(1), reason: '"$ok"');
      // The screen hands the raw text over; the service normalizes it.
      expect(UserNameRules.normalizeMiddleInitial(service.calls.single.middleInitial), 'J.');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('Display Name is passed through unchanged and independent of the name fields', (tester) async {
    await openScreen(tester);
    await fill(tester, first: 'Juan', mi: 'D.', last: 'Dela Cruz', display: 'Ma\'am Jane');
    await submit(tester);

    final call = service.calls.single;
    expect(call.displayName, 'Ma\'am Jane');
    expect(call.firstName, 'Juan');
    expect(call.middleInitial, 'D.');
    expect(call.lastName, 'Dela Cruz');
    expect(call.email, 'staff@ndmu.edu.ph');
    expect(call.guidancePosition, isNull, reason: 'Position is optional now and no longer defaults to a value');
  });

  testWidgets('leaving the WHOLE personal profile blank (name, Display Name, Position) is accepted -- '
      'the account holder completes it themselves on Mobile Profile Setup', (tester) async {
    await openScreen(tester);
    await tester.enterText(find.byKey(const Key('createUser.email')), 'staff@ndmu.edu.ph');
    await submit(tester);

    expect(service.calls, hasLength(1));
    final call = service.calls.single;
    expect(call.firstName, isEmpty);
    expect(call.middleInitial, isEmpty);
    expect(call.lastName, isEmpty);
    expect(call.displayName, isEmpty);
    expect(call.guidancePosition, isNull);
    expect(find.text('First Name is required'), findsNothing);
    expect(find.text('Last Name is required'), findsNothing);
    expect(find.text('Middle Initial is required'), findsNothing);
  });

  testWidgets('Position can be selected from the three canonical choices', (tester) async {
    await openScreen(tester);
    await fill(tester);
    await tester.tap(find.byKey(const Key('createUser.position')));
    await tester.pumpAndSettle();
    expect(find.text('Guidance Head'), findsWidgets);
    expect(find.text('Psychometrician'), findsWidgets);
    expect(find.text('Guidance Staff'), findsWidgets);
    await tester.tap(find.text('Psychometrician').last);
    await tester.pumpAndSettle();
    await submit(tester);

    expect(service.calls.single.guidancePosition, 'psychometrician');
  });

  testWidgets('typing the name does not fill in the Display Name', (tester) async {
    await openScreen(tester);
    await tester.enterText(find.byKey(const Key('createUser.firstName')), 'Juan');
    await tester.enterText(find.byKey(const Key('createUser.lastName')), 'Dela Cruz');
    await tester.pump();

    final display = tester.widget<TextFormField>(find.byKey(const Key('createUser.displayName')));
    expect(display.controller!.text, isEmpty);
  });

  testWidgets('a System Admin can add a new position through the "+" action, and it becomes selectable',
      (tester) async {
    await openScreen(tester);

    await tester.tap(find.byKey(const Key('createUser.addPosition')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('addGuidancePosition.label')), 'Auditing');
    await tester.tap(find.byKey(const Key('addGuidancePosition.add')));
    await tester.pumpAndSettle();

    expect(firestoreService.addedLabels, ['Auditing']);

    await tester.tap(find.byKey(const Key('createUser.position')));
    await tester.pumpAndSettle();
    expect(find.text('Auditing'), findsWidgets);
    await tester.tap(find.text('Auditing').last);
    await tester.pumpAndSettle();
    await fill(tester);
    await submit(tester);

    expect(service.calls.single.guidancePosition, 'auditing');
  });

  testWidgets('cancelling the "+" dialog adds nothing', (tester) async {
    await openScreen(tester);

    await tester.tap(find.byKey(const Key('createUser.addPosition')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addGuidancePosition.cancel')));
    await tester.pumpAndSettle();

    expect(firestoreService.addedLabels, isEmpty);
  });

  testWidgets('a blank position name is rejected without adding anything', (tester) async {
    await openScreen(tester);

    await tester.tap(find.byKey(const Key('createUser.addPosition')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('addGuidancePosition.add')));
    await tester.pumpAndSettle();

    expect(find.text('Position name is required'), findsOneWidget);
    expect(firestoreService.addedLabels, isEmpty);
  });

  testWidgets('adding a position that duplicates an existing label shows an error', (tester) async {
    await openScreen(tester);

    await tester.tap(find.byKey(const Key('createUser.addPosition')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('addGuidancePosition.label')), 'Guidance Head');
    await tester.tap(find.byKey(const Key('addGuidancePosition.add')));
    await tester.pumpAndSettle();

    expect(find.text('A position with this name already exists'), findsOneWidget);
    expect(firestoreService.addedLabels, isEmpty);
  });
}
