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

  @override
  Future<List<LocalBatch>> getBatches() async => const [];

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

  /// Pumps the screen (exam pre-locked so no dropdown interaction is needed),
  /// then taps "Create Batch".
  Future<void> createBatch(WidgetTester tester, {required FirebaseAuth auth}) async {
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

    final createButton = find.widgetWithText(ElevatedButton, 'Create Batch');
    await tester.ensureVisible(createButton);
    await tester.tap(createButton);
    await tester.pumpAndSettle();
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
}
