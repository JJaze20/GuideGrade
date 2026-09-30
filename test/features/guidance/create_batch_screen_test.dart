import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/guidance/screens/create_batch_screen.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/user.dart';

/// Minimal [FirebaseAuth] stand-in — only [currentUser] is real, so batch
/// creation can run in a widget test with no Firebase initialised.
class _FakeFirebaseAuth implements FirebaseAuth {
  _FakeFirebaseAuth(this._user);
  final User? _user;

  @override
  User? get currentUser => _user;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal [User] stand-in: a uid and a possibly-null client displayName —
/// the exact shape that produced `created_by_name = "Unknown"` for Account B.
class _FakeUser implements User {
  _FakeUser({required this.uid, this.displayName});

  @override
  final String uid;

  @override
  final String? displayName;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records the identity fields handed to [createBatch]; no other method of
/// the interface is exercised by this screen path.
class _RecordingBatchRepository implements BatchRepository {
  String? capturedCreatedByName;
  String? capturedCreatedByUid;
  String? capturedDescription;
  int? capturedExpectedCount;

  /// Seeded by a test to simulate an existing batch already using the
  /// currently-generated batch code -- exercises the real collision-retry
  /// path in `_createBatch()` rather than reaching for a private-method hack.
  List<LocalBatch> existingBatches = const [];

  @override
  Future<List<LocalBatch>> getBatches() async => existingBatches;

  @override
  Future<LocalBatch> createBatch({
    required String batchCode,
    required String examCode,
    required String examTitle,
    required String description,
    required int expectedCount,
    required String createdByUid,
    required String createdByName,
  }) async {
    capturedCreatedByUid = createdByUid;
    capturedCreatedByName = createdByName;
    capturedDescription = description;
    capturedExpectedCount = expectedCount;
    final now = DateTime.now();
    return LocalBatch(
      id: 'b_test',
      batchCode: batchCode,
      examCode: examCode,
      examTitle: examTitle,
      description: description,
      expectedCount: expectedCount,
      status: 'Draft',
      createdByUid: createdByUid,
      createdByName: createdByName,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

UserModel _userModel({
  required String displayName,
  String userId = 'uid-b',
}) =>
    UserModel(
      userId: userId,
      email: 'x@example.com',
      displayName: displayName,
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    );

void main() {
  late _RecordingBatchRepository repo;
  late AppState appState;

  setUp(() {
    repo = _RecordingBatchRepository();
    appState = AppState(batchRepository: repo);
    appState.setCurrentUser(
      _userModel(displayName: 'Present Name B', userId: 'uid-b'),
    );
  });

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
  });

  /// Pumps the screen (exam pre-locked so no dropdown interaction is needed).
  Future<void> pumpScreen(WidgetTester tester, {required FirebaseAuth auth}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppStateScope(notifier: appState, child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        CreateBatchScreen(initialExamCode: 'AT', auth: auth),
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

  Future<void> tapCreate(WidgetTester tester) async {
    final createButton = find.widgetWithText(ElevatedButton, 'Create Batch');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pumpAndSettle();
  }

  /// Pumps the screen then immediately taps "Create Batch" -- the shape the
  /// two existing regression tests below already rely on.
  Future<void> createBatch(WidgetTester tester, {required FirebaseAuth auth}) async {
    await pumpScreen(tester, auth: auth);
    await tapCreate(tester);
  }

  /// Reads the currently-displayed Batch Code from the read-only field.
  String batchCodeShown(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('createBatch.batchCode'))).data!;

  /// A minimal existing batch whose only relevant property is [batchCode] --
  /// used to seed a collision with whatever code CreateBatchScreen currently
  /// has generated.
  LocalBatch existingBatchWith(String batchCode) {
    final now = DateTime.now();
    return LocalBatch(
      id: 'existing',
      batchCode: batchCode,
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: '',
      expectedCount: 30,
      status: 'Draft',
      createdByUid: 'other-uid',
      createdByName: 'Other User',
      createdAt: now,
      updatedAt: now,
    );
  }

  testWidgets(
      'createdByName is taken from AppState.currentUser.displayName when the '
      'Firebase Auth client displayName is null (Account B regression)',
      (tester) async {
    final auth = _FakeFirebaseAuth(_FakeUser(uid: 'uid-b', displayName: null));

    await createBatch(tester, auth: auth);

    expect(repo.capturedCreatedByName, 'Present Name B');
    expect(repo.capturedCreatedByName, isNot('Unknown'));
  });

  testWidgets(
      'createdByUid is still taken from Firebase Auth (only the name source '
      'changed)', (tester) async {
    final auth = _FakeFirebaseAuth(_FakeUser(uid: 'uid-b', displayName: null));

    await createBatch(tester, auth: auth);

    expect(repo.capturedCreatedByUid, 'uid-b');
  });

  // --- Batch Code read-only display (P2-7 regression) -------------------

  group('Batch Code is a read-only display value, not a TextEditingController',
      () {
    testWidgets('A. renders the generated batch code', (tester) async {
      final auth = _FakeFirebaseAuth(_FakeUser(uid: 'uid-b', displayName: 'B'));
      await pumpScreen(tester, auth: auth);

      expect(batchCodeShown(tester), matches(RegExp(r'^B-\d{6}-\d{3}$')));
    });

    testWidgets('B. the batch code is rendered as plain read-only text, not '
        'inside an editable TextField/TextFormField', (tester) async {
      final auth = _FakeFirebaseAuth(_FakeUser(uid: 'uid-b', displayName: 'B'));
      await pumpScreen(tester, auth: auth);

      final batchCodeText = find.byKey(const Key('createBatch.batchCode'));
      expect(batchCodeText, findsOneWidget);
      expect(
        find.ancestor(of: batchCodeText, matching: find.byType(TextField)),
        findsNothing,
      );
      expect(
        find.ancestor(of: batchCodeText, matching: find.byType(TextFormField)),
        findsNothing,
      );
    });

    testWidgets('C. a batch-code collision regenerates the code and the '
        'display reflects the new value', (tester) async {
      final auth = _FakeFirebaseAuth(_FakeUser(uid: 'uid-b', displayName: 'B'));
      await pumpScreen(tester, auth: auth);

      final originalCode = batchCodeShown(tester);
      // Seeds an existing batch using the code currently shown -- this
      // exercises the real _createBatch() collision-retry path.
      repo.existingBatches = [existingBatchWith(originalCode)];

      await tapCreate(tester);

      expect(find.text('Batch code already exists. Generated a new code.'),
          findsOneWidget);
      expect(batchCodeShown(tester), isNot(originalCode));
      expect(repo.capturedCreatedByName, isNull,
          reason: 'the collision blocks this attempt -- createBatch is '
              'never actually called');
    });

    testWidgets('D. Description and Expected Answer Sheets remain editable '
        'and are submitted correctly', (tester) async {
      final auth = _FakeFirebaseAuth(_FakeUser(uid: 'uid-b', displayName: 'B'));
      await pumpScreen(tester, auth: auth);

      // TextFormField's own internal implementation is itself built from a
      // TextField, so find.byType(TextField) also matches the Expected
      // Answer Sheets field's internals -- Description's own bare TextField
      // is declared earlier in build()'s children, so it is deterministically
      // first in a depth-first widget-tree walk.
      await tester.enterText(find.byType(TextField).first, 'BSIT - 1A');
      await tester.enterText(find.byType(TextFormField), '45');
      await tapCreate(tester);

      expect(repo.capturedDescription, 'BSIT - 1A');
      expect(repo.capturedExpectedCount, 45);
    });
  });
}
