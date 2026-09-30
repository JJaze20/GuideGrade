import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/features/admin/screens/user_management_screen.dart';
import 'package:guidegrade/models/user.dart';

/// Never reaches real Firestore. [usersStream] is a single, long-lived
/// StreamController -- the whole point of these tests is to prove
/// UserManagementScreen only ever calls [usersStream] once and keeps
/// listening to that one stream, so [emit] can be used to simulate a
/// real-time Firestore update landing later.
class _FakeFirestoreService implements FirestoreService {
  _FakeFirestoreService(List<UserModel> initialUsers) {
    _controller.add(initialUsers);
  }

  final _controller = StreamController<List<UserModel>>();
  int usersStreamCallCount = 0;

  @override
  Stream<List<UserModel>> usersStream() {
    usersStreamCallCount++;
    return _controller.stream;
  }

  void emit(List<UserModel> users) => _controller.add(users);

  void emitError(Object error) => _controller.addError(error);

  void close() => _controller.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserModel _user({
  required String id,
  required String displayName,
  required String email,
  String role = 'guidance_council',
  bool isActive = true,
}) =>
    UserModel(
      userId: id,
      email: email,
      displayName: displayName,
      role: role,
      isActive: isActive,
      createdAt: DateTime.utc(2026),
    );

void main() {
  late _FakeFirestoreService firestoreService;

  final jeric = _user(id: 'u1', displayName: 'Jeric Ryan Caday', email: 'jeric@ndmu.edu.ph');
  final maria = _user(id: 'u2', displayName: 'Maria Santos', email: 'maria@ndmu.edu.ph');
  final admin = _user(
    id: 'u3',
    displayName: 'System Admin',
    email: 'admin@ndmu.edu.ph',
    role: 'system_admin',
  );
  final inactiveStaff = _user(
    id: 'u4',
    displayName: 'Old Staff',
    email: 'old@ndmu.edu.ph',
    isActive: false,
  );

  tearDown(() {
    firestoreService.close();
  });

  Future<void> pumpScreen(WidgetTester tester, List<UserModel> initialUsers) async {
    firestoreService = _FakeFirestoreService(initialUsers);
    await tester.pumpWidget(
      MaterialApp(
        home: UserManagementScreen(firestoreService: firestoreService),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('A. the initial user list loads and displays correctly', (tester) async {
    await pumpScreen(tester, [jeric, maria]);

    expect(find.text('Jeric Ryan Caday'), findsOneWidget);
    expect(find.text('jeric@ndmu.edu.ph'), findsOneWidget);
    expect(find.text('Maria Santos'), findsOneWidget);
  });

  testWidgets('B. search filters by display name', (tester) async {
    await pumpScreen(tester, [jeric, maria]);

    await tester.enterText(find.byType(TextField), 'Maria');
    await tester.pumpAndSettle();

    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('Jeric Ryan Caday'), findsNothing);
  });

  testWidgets('C. search filters by email', (tester) async {
    await pumpScreen(tester, [jeric, maria]);

    await tester.enterText(find.byType(TextField), 'maria@ndmu');
    await tester.pumpAndSettle();

    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('Jeric Ryan Caday'), findsNothing);
  });

  testWidgets('D. multi-word search works normally, e.g. "Jeric Ryan"', (tester) async {
    await pumpScreen(tester, [jeric, maria]);

    // Typed one word at a time, exactly as a real user would, including the
    // space between words -- this is exactly the interaction the reported
    // bug broke.
    await tester.enterText(find.byType(TextField), 'Jeric');
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Jeric Ryan');
    await tester.pump();

    expect(find.text('Jeric Ryan Caday'), findsOneWidget);
    expect(find.text('Maria Santos'), findsNothing);
  });

  testWidgets(
      'E. typing multiple characters does NOT bring back the loading spinner once the initial stream has loaded',
      (tester) async {
    await pumpScreen(tester, [jeric, maria]);
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'already past the initial load');

    var typed = '';
    for (final ch in 'Jeric Ryan'.split('')) {
      typed += ch; // incremental, like a real user typing one key at a time
      await tester.enterText(find.byType(TextField), typed);
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'typing up to "$typed" must never re-show the loading spinner or drop the search field',
      );
      // The search field itself must stay mounted throughout -- if
      // StreamBuilder ever reset to ConnectionState.waiting, the whole
      // Column (including this TextField) would be replaced by the spinner
      // above, and this would fail.
      expect(find.byType(TextField), findsOneWidget);
    }
  });

  testWidgets('F. usersStream() is requested only once for the screen lifetime', (tester) async {
    await pumpScreen(tester, [jeric, maria]);
    expect(firestoreService.usersStreamCallCount, 1);

    await tester.enterText(find.byType(TextField), 'Jeric Ryan');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Active'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Guidance Council'));
    await tester.pumpAndSettle();

    expect(
      firestoreService.usersStreamCallCount,
      1,
      reason: 'StreamBuilder must keep reusing the one stable stream, not request a new one per keystroke/filter',
    );
  });

  testWidgets('G. existing role and status filters still work', (tester) async {
    await pumpScreen(tester, [jeric, admin, inactiveStaff]);

    await tester.tap(find.widgetWithText(FilterChip, 'System Admin'));
    await tester.pumpAndSettle();
    expect(find.text('System Admin'), findsWidgets, reason: 'both the chip label and the matched user show this text');
    expect(find.text('Jeric Ryan Caday'), findsNothing);
    expect(find.text('Old Staff'), findsNothing);

    // Back to Role: All, then filter Status: Inactive.
    await tester.tap(find.widgetWithText(FilterChip, 'All').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Inactive'));
    await tester.pumpAndSettle();

    expect(find.text('Old Staff'), findsOneWidget);
    expect(find.text('Jeric Ryan Caday'), findsNothing);
  });

  testWidgets('H. a real-time stream update still updates the displayed user list', (tester) async {
    await pumpScreen(tester, [jeric]);
    expect(find.text('Maria Santos'), findsNothing);

    // Simulates another admin creating a user elsewhere -- a fresh snapshot
    // arriving on the SAME long-lived subscription, exactly what a real
    // Firestore .snapshots() listener would deliver.
    firestoreService.emit([jeric, maria]);
    await tester.pumpAndSettle();

    expect(find.text('Maria Santos'), findsOneWidget);
    expect(find.text('Jeric Ryan Caday'), findsOneWidget);
  });

  testWidgets('I. a permission-denied stream error shows an '
      'authorization-specific message', (tester) async {
    await pumpScreen(tester, [jeric]);

    firestoreService.emitError(FirebaseException(plugin: 'firestore', code: 'permission-denied'));
    await tester.pumpAndSettle();

    expect(find.textContaining('permission'), findsOneWidget);
    expect(find.text('Could not load users'), findsNothing);
  });

  testWidgets('J. an unavailable/network stream error shows a '
      'connectivity-specific message', (tester) async {
    await pumpScreen(tester, [jeric]);

    firestoreService.emitError(FirebaseException(plugin: 'firestore', code: 'unavailable'));
    await tester.pumpAndSettle();

    expect(find.textContaining('server'), findsOneWidget);
    expect(find.text('Could not load users'), findsNothing);
  });
}
