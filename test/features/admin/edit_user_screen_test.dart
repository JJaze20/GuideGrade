import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/core/services/logging_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/admin/screens/edit_user_screen.dart';
import 'package:guidegrade/models/guidance_position.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/user.dart';
import 'package:guidegrade/shared/widgets/primary_button.dart';

class _FakeBatchRepository implements BatchRepository {
  @override
  Future<List<LocalBatch>> getBatches() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFirestoreService implements FirestoreService {
  _FakeFirestoreService(this.stored, [List<GuidancePosition>? positions])
      : _positions = positions ?? GuidancePositions.defaults;

  final UserModel stored;
  final updates = <UserModel>[];
  List<GuidancePosition> _positions;
  final addedLabels = <String>[];
  final removedValues = <String>[];
  final deactivateCalls = <String>[];
  final activateCalls = <String>[];

  /// Position values Position Management should report as "assigned to a
  /// user" -- empty by default.
  final Set<String> assignedValues = {};

  @override
  Future<UserModel?> getUserById(String userId) async => stored;

  @override
  Future<void> updateUser(UserModel user) async => updates.add(user);

  @override
  Future<void> deactivateUser(String userId) async => deactivateCalls.add(userId);

  @override
  Future<void> activateUser(String userId) async => activateCalls.add(userId);

  @override
  Future<List<GuidancePosition>> loadGuidancePositions() async => _positions;

  @override
  Future<void> ensureDefaultGuidancePositionsSeeded() async {}

  @override
  Future<GuidancePosition> addGuidancePosition(String label, List<GuidancePosition> existingPositions) async {
    final error = GuidancePositions.validateNewLabel(label, existingPositions);
    if (error != null) throw ArgumentError(error);
    final added = GuidancePositions.build(label);
    addedLabels.add(label);
    _positions = [..._positions, added];
    return added;
  }

  @override
  Future<bool> isGuidancePositionAssigned(String value) async => assignedValues.contains(value);

  @override
  Future<void> removeGuidancePosition(String value) async {
    removedValues.add(value);
    _positions = [..._positions]..removeWhere((p) => p.value == value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLoggingService implements LoggingService {
  @override
  Future<void> logUserActivated(UserModel actor,
          {required String targetUserId, required String targetUserEmail}) async {}

  @override
  Future<void> logUserDeactivated(UserModel actor,
          {required String targetUserId, required String targetUserEmail}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserModel _staff({
  String? first,
  String? mi,
  String? last,
  String? position = 'guidance_staff',
  String displayName = 'J. Dela Cruz',
}) =>
    UserModel(
      userId: 'staff-1',
      email: 'staff@ndmu.edu.ph',
      displayName: displayName,
      role: 'guidance_council',
      guidancePosition: position,
      isActive: true,
      createdAt: DateTime.utc(2026),
      institution: 'NDMU',
      firstName: first,
      middleInitial: mi,
      lastName: last,
    );

/// Matches the `admin-1` user set as `appState.currentUser` in `setUp` --
/// opening EditUserScreen with this as the target user is what makes
/// `_isEditingSelf` true.
UserModel _admin() => UserModel(
      userId: 'admin-1',
      email: 'admin@ndmu.edu.ph',
      displayName: 'Admin',
      role: 'system_admin',
      isActive: true,
      createdAt: DateTime.utc(2026),
    );

void main() {
  late AppState appState;

  setUp(() {
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

  Future<_FakeFirestoreService> openScreen(
    WidgetTester tester,
    UserModel user, {
    List<GuidancePosition>? positions,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firestore = _FakeFirestoreService(user, positions);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: EditUserScreen(
          user: user,
          firestoreService: firestore,
          loggingService: _FakeLoggingService(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return firestore;
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text;

  Future<void> save(WidgetTester tester) async {
    final button = find.byType(PrimaryButton);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('loads the existing structured name and Display Name independently', (tester) async {
    await openScreen(tester, _staff(first: 'Juan', mi: 'D.', last: 'Dela Cruz'));
    expect(textOf(tester, 'editUser.firstName'), 'Juan');
    expect(textOf(tester, 'editUser.middleInitial'), 'D.');
    expect(textOf(tester, 'editUser.lastName'), 'Dela Cruz');
    expect(textOf(tester, 'editUser.displayName'), 'J. Dela Cruz');
  });

  testWidgets('saves updated name fields (middle initial normalized) without touching Display Name', (tester) async {
    final firestore = await openScreen(tester, _staff(first: 'Juan', mi: 'D.', last: 'Dela Cruz'));

    await tester.enterText(find.byKey(const Key('editUser.firstName')), '  Jose ');
    await tester.enterText(find.byKey(const Key('editUser.middleInitial')), 'm');
    await tester.enterText(find.byKey(const Key('editUser.lastName')), 'Santos');
    await save(tester);

    final saved = firestore.updates.single;
    expect(saved.firstName, 'Jose');
    expect(saved.middleInitial, 'M.');
    expect(saved.lastName, 'Santos');
    expect(saved.displayName, 'J. Dela Cruz', reason: 'Display Name is never derived from the name fields');
    expect(saved.institution, 'NDMU');
    expect(saved.guidancePosition, 'guidance_staff');
    expect(saved.isActive, isTrue);
  });

  testWidgets('Display Name can be edited on its own', (tester) async {
    final firestore = await openScreen(tester, _staff(first: 'Juan', mi: 'D.', last: 'Dela Cruz'));

    await tester.enterText(find.byKey(const Key('editUser.displayName')), 'Sir Juan');
    await save(tester);

    final saved = firestore.updates.single;
    expect(saved.displayName, 'Sir Juan');
    expect(saved.firstName, 'Juan');
    expect(saved.middleInitial, 'D.');
    expect(saved.lastName, 'Dela Cruz');
  });

  testWidgets('a legacy user without a structured name loads with empty fields and can still be saved', (tester) async {
    final firestore = await openScreen(tester, _staff());
    expect(textOf(tester, 'editUser.firstName'), isEmpty);
    expect(textOf(tester, 'editUser.middleInitial'), isEmpty);
    expect(textOf(tester, 'editUser.lastName'), isEmpty);

    await tester.enterText(find.byKey(const Key('editUser.displayName')), 'Renamed Legacy');
    await save(tester);

    final saved = firestore.updates.single;
    expect(saved.displayName, 'Renamed Legacy');
    expect(saved.firstName, isNull);
    expect(saved.middleInitial, isNull);
    expect(saved.lastName, isNull);
    expect(saved.toFirestore().containsKey('firstName'), isFalse, reason: 'no empty name fields are written');
  });

  testWidgets('a legacy user can be given a full structured name', (tester) async {
    final firestore = await openScreen(tester, _staff());

    await tester.enterText(find.byKey(const Key('editUser.firstName')), 'Juan');
    await tester.enterText(find.byKey(const Key('editUser.middleInitial')), 'D');
    await tester.enterText(find.byKey(const Key('editUser.lastName')), 'Dela Cruz');
    await save(tester);

    final saved = firestore.updates.single;
    expect(saved.firstName, 'Juan');
    expect(saved.middleInitial, 'D.');
    expect(saved.lastName, 'Dela Cruz');
    expect(saved.displayName, 'J. Dela Cruz');
  });

  testWidgets('a half-filled name on a legacy user is rejected', (tester) async {
    final firestore = await openScreen(tester, _staff());

    await tester.enterText(find.byKey(const Key('editUser.firstName')), 'Juan');
    await save(tester);

    expect(find.text('Middle Initial is required'), findsOneWidget);
    expect(find.text('Last Name is required'), findsOneWidget);
    expect(firestore.updates, isEmpty);
  });

  testWidgets('a user that already has a name cannot blank First or Last Name, or use a full middle name', (tester) async {
    final firestore = await openScreen(tester, _staff(first: 'Juan', mi: 'D.', last: 'Dela Cruz'));

    await tester.enterText(find.byKey(const Key('editUser.firstName')), '');
    await tester.enterText(find.byKey(const Key('editUser.middleInitial')), 'Dela');
    await tester.enterText(find.byKey(const Key('editUser.lastName')), '  ');
    await save(tester);

    expect(find.text('First Name is required'), findsOneWidget);
    expect(find.text('Enter a single letter, e.g. D or D.'), findsOneWidget);
    expect(find.text('Last Name is required'), findsOneWidget);
    expect(firestore.updates, isEmpty);
  });

  testWidgets(
      'a user already holding a custom position (not one of the original three) keeps it selected, '
      'even though the loaded configuration only returns the three defaults', (tester) async {
    await openScreen(tester, _staff(position: 'auditing'));

    // GuidancePositions.ensureIncludes must add a synthetic "auditing" entry
    // so the dropdown's own assertion (initialValue must match an item)
    // doesn't crash, and so the account's real stored value is still shown
    // as selected rather than silently reset to nothing.
    expect(find.text('auditing'), findsOneWidget);
  });

  testWidgets('the "+" action opens Position Management here too, and adding a position still works',
      (tester) async {
    final firestore = await openScreen(tester, _staff());

    await tester.tap(find.byKey(const Key('editUser.addPosition')));
    await tester.pumpAndSettle();
    expect(find.text('Position Management'), findsOneWidget);

    await tester.tap(find.byKey(const Key('positionManagement.add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('addGuidancePosition.label')), 'Auditing');
    await tester.tap(find.byKey(const Key('addGuidancePosition.add')));
    await tester.pumpAndSettle();

    expect(firestore.addedLabels, ['Auditing']);

    await tester.tap(find.byKey(const Key('positionManagement.close')));
    await tester.pumpAndSettle();

    // Edit User's own dropdown receives the updated position list too.
    await tester.tap(find.byKey(const Key('editUser.position')));
    await tester.pumpAndSettle();
    expect(find.text('Auditing'), findsWidgets);
    await tester.tap(find.text('Auditing').last);
    await tester.pumpAndSettle();
    await save(tester);

    expect(firestore.updates.single.guidancePosition, 'auditing');
  });

  testWidgets('deleting the position currently assigned to the user being edited is blocked', (tester) async {
    // _staff() defaults to guidancePosition: 'guidance_staff' -- a REAL,
    // concrete assignment check against the exact user this screen is
    // editing, not a synthetic scenario.
    final staff = _staff();
    final firestore = await openScreen(tester, staff);
    firestore.assignedValues.add('guidance_staff');

    await tester.tap(find.byKey(const Key('editUser.addPosition')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('positionManagement.delete.guidance_staff')));
    await tester.pumpAndSettle();

    expect(find.text('Cannot Delete This Position'), findsOneWidget);
    expect(firestore.removedValues, isEmpty);
  });

  // --- Display Name is optional, matching Create User (regression) ----

  testWidgets(
      'a user with a blank Display Name (not yet completed Mobile Profile Setup) can still '
      'be edited and saved by System Admin -- Display Name is optional here too, matching '
      'Create User', (tester) async {
    final firestore = await openScreen(tester, _staff(displayName: ''));

    // An unrelated field (Institution) can be changed and saved without
    // ever having to type a Display Name. Institution has no fieldKey of
    // its own in EditUserScreen -- it's the last plain TextFormField in
    // the form (firstName, middleInitial, lastName, displayName, then
    // institution; Position is a DropdownButtonFormField, not a
    // TextFormField, so it doesn't affect this ordering).
    await tester.enterText(find.byType(TextFormField).last, 'NDMU Annex');
    await save(tester);

    expect(find.text('This field is required'), findsNothing);
    final saved = firestore.updates.single;
    expect(saved.displayName, isEmpty);
    expect(saved.institution, 'NDMU Annex');
  });

  testWidgets('existing behavior for a populated Display Name is unchanged -- it can still be '
      'edited and is still saved verbatim', (tester) async {
    final firestore = await openScreen(tester, _staff());

    await tester.enterText(find.byKey(const Key('editUser.displayName')), 'Sir Juan');
    await save(tester);

    expect(find.text('This field is required'), findsNothing);
    expect(firestore.updates.single.displayName, 'Sir Juan');
  });

  // --- Self-protection (P2-5 regression) -------------------------------

  group('self-protection: the signed-in admin can never deactivate/re-role '
      'their own account from this screen', () {
    testWidgets('1. self account: the warning banner is shown and the '
        'Deactivate/Activate button is disabled', (tester) async {
      await openScreen(tester, _admin());

      expect(
        find.text('This is your own account. Role changes and deactivation '
            'are disabled here to prevent losing access.'),
        findsOneWidget,
      );
      final button = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Deactivate Account'));
      expect(button.onPressed, isNull);
    });

    testWidgets('2. another user: no self-account banner, and the Deactivate '
        'button is enabled', (tester) async {
      await openScreen(tester, _staff());

      expect(
        find.text('This is your own account. Role changes and deactivation '
            'are disabled here to prevent losing access.'),
        findsNothing,
      );
      final button = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Deactivate Account'));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('3. self account: interacting with the disabled control never '
        'reaches deactivateUser', (tester) async {
      final firestore = await openScreen(tester, _admin());

      await tester.tap(find.widgetWithText(OutlinedButton, 'Deactivate Account'));
      await tester.pumpAndSettle();

      expect(firestore.deactivateCalls, isEmpty);
      expect(firestore.activateCalls, isEmpty);
    });

    testWidgets('4. another user: the existing deactivate flow still reaches '
        'deactivateUser', (tester) async {
      final firestore = await openScreen(tester, _staff());

      await tester.tap(find.widgetWithText(OutlinedButton, 'Deactivate Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Deactivate'));
      await tester.pumpAndSettle();

      expect(firestore.deactivateCalls, ['staff-1']);
    });

    testWidgets('5a. role is read-only for the self (system_admin) account -- '
        'no editable role control exists', (tester) async {
      await openScreen(tester, _admin());

      expect(find.text('System Admin'), findsOneWidget);
      expect(find.byKey(const Key('editUser.role')), findsNothing);
      // system_admin has no Guidance Position section either -- there is no
      // dropdown of any kind on this screen for a self-viewed admin account.
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    });

    testWidgets('5b. role is read-only for another (guidance_council) account '
        '-- the only dropdown present is Guidance Position, never role',
        (tester) async {
      await openScreen(tester, _staff());

      expect(find.text('Guidance Council'), findsOneWidget);
      expect(find.byKey(const Key('editUser.role')), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(find.byKey(const Key('editUser.position')), findsOneWidget);
    });
  });
}
