import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/home/screens/staff_home_screen.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/user.dart';

class _FakeBatchRepository implements BatchRepository {
  _FakeBatchRepository([this.batches = const []]);
  final List<LocalBatch> batches;

  @override
  Future<List<LocalBatch>> getBatches() async => batches;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalBatch _batch({String id = 'b1', String status = 'Active'}) => LocalBatch(
      id: id,
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: 'Morning Session',
      expectedCount: 10,
      status: status,
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  late AppState appState;

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
  });

  Future<void> pumpScreen(WidgetTester tester, {List<LocalBatch> batches = const []}) async {
    appState = AppState(batchRepository: _FakeBatchRepository(batches));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: const StaffHomeScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('1. a signed-in user with a real displayName sees it in the welcome card',
      (tester) async {
    await pumpScreen(tester);
    appState.setCurrentUser(UserModel(
      userId: 'gc-1',
      email: 'staff@ndmu.edu.ph',
      displayName: 'Juan Dela Cruz',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Juan Dela Cruz'), findsOneWidget);
    expect(find.text('NDMU Staff Officer'), findsNothing);
  });

  testWidgets('2. a blank/null displayName falls back to "NDMU Staff Officer"',
      (tester) async {
    await pumpScreen(tester);
    // No currentUser at all (nobody signed in yet, or a session with a
    // Firestore doc that has no displayName) -- both are "blank" cases.
    expect(find.text('NDMU Staff Officer'), findsOneWidget);

    appState.setCurrentUser(UserModel(
      userId: 'gc-2',
      email: 'blank@ndmu.edu.ph',
      displayName: '   ',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ));
    await tester.pumpAndSettle();

    expect(find.text('NDMU Staff Officer'), findsOneWidget);
  });

  testWidgets('3. welcome card shows the signed-in role instead of the location',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('Your workspace'), findsNothing);
    expect(find.text('Marbel, PH'), findsNothing);

    appState.setCurrentUser(UserModel(
      userId: 'gc-1',
      email: 'staff@ndmu.edu.ph',
      displayName: 'Juan Dela Cruz',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Guidance Council'), findsOneWidget);
    expect(find.text('Juan Dela Cruz'), findsOneWidget);
    expect(find.text('Marbel, PH'), findsNothing);
  });

  testWidgets('4. batch loading and the empty state still work, unaffected by the name fix',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('No batches yet'), findsOneWidget);
  });

  testWidgets('5. an existing batch still renders in the registry, unaffected by the name fix',
      (tester) async {
    await pumpScreen(tester, batches: [_batch()]);
    expect(find.text('Morning Session'), findsOneWidget);
    expect(find.text('No batches yet'), findsNothing);
  });
}
