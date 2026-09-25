import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/core/services/logging_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/admin/screens/edit_user_screen.dart';
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
  _FakeFirestoreService(this.stored);

  final UserModel stored;
  final updates = <UserModel>[];

  @override
  Future<UserModel?> getUserById(String userId) async => stored;

  @override
  Future<void> updateUser(UserModel user) async => updates.add(user);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLoggingService implements LoggingService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserModel _staff({String? first, String? mi, String? last}) => UserModel(
      userId: 'staff-1',
      email: 'staff@ndmu.edu.ph',
      displayName: 'J. Dela Cruz',
      role: 'guidance_council',
      guidancePosition: 'guidance_staff',
      isActive: true,
      createdAt: DateTime.utc(2026),
      institution: 'NDMU',
      firstName: first,
      middleInitial: mi,
      lastName: last,
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

  Future<_FakeFirestoreService> openScreen(WidgetTester tester, UserModel user) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final firestore = _FakeFirestoreService(user);
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
}
