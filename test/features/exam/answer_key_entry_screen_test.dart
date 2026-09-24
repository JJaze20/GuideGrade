import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/exam/screens/answer_key_entry_screen.dart';
import 'package:guidegrade/models/activity_model.dart';
import 'package:guidegrade/models/answer_key.dart';

/// The local (unsynced) answer key the officer has on this device.
const _localAnswers = {'Test I|1': 'A', 'Test I|2': 'B'};

/// The cloud copy — differs from local (extra item, different Test I|1).
CloudAnswerKeyRead _defaultCloud() => CloudAnswerKeyRead.found(
      version: 5,
      answers: const {'Test I|1': 'C', 'Test I|2': 'B', 'Test II|1': 'D'},
      updatedByName: 'Officer Cruz',
      updatedAt: '2026-05-04T08:30:00.000Z',
    );

/// In-memory [LocalStorageService] — no SharedPreferences, no platform channel.
class _FakeLocalStorage implements LocalStorageService {
  final List<Map<String, AnswerKey>> savedAnswerKeys = [];

  /// When set, `saveAnswerKeys` throws it (simulates a failed local write).
  Object? throwOnSaveAnswerKeys;

  /// When set, `saveAnswerKeys` waits on this before completing (lets a test
  /// observe the screen while local persistence is still in flight).
  Completer<void>? gateSaveAnswerKeys;

  @override
  Future<void> saveAnswerKeys(Map<String, AnswerKey> answerKeys) async {
    final gate = gateSaveAnswerKeys;
    if (gate != null) await gate.future;
    final err = throwOnSaveAnswerKeys;
    if (err != null) throw err;
    savedAnswerKeys.add(Map.of(answerKeys));
  }

  @override
  Future<Map<String, AnswerKey>> loadAnswerKeys() async =>
      savedAnswerKeys.isEmpty ? {} : Map.of(savedAnswerKeys.last);

  @override
  Future<List<ActivityModel>> loadActivities() async => [];

  @override
  Future<void> saveActivities(List<ActivityModel> activities) async {}
}

/// [AppState] with the answer-key conflict surface faked out: no
/// [SyncManager] / [SyncQueue] (whose real file I/O would hang the widget
/// binding's fake-async zone). It records what the screen asked it to do so
/// the tests can assert the UI wiring without a real cloud or queue.
class _FakeAppState extends AppState {
  _FakeAppState({required super.batchRepository, required super.localStorage});

  AnswerKeySyncStatus status = AnswerKeySyncStatus.upToDate;
  CloudAnswerKeyRead cloudRead = _defaultCloud();

  final List<String> effects = [];
  int adoptCalls = 0;
  int forcePushCalls = 0;
  int? lastExpectedVersion;
  int? lastAdoptVersion;
  Map<String, String>? lastAdoptAnswers;
  DateTime? lastAdoptUpdatedAt;

  /// Test hook: change the reported status and rebuild dependents.
  void setStatus(AnswerKeySyncStatus next) {
    status = next;
    notifyListeners();
  }

  @override
  AnswerKeySyncStatus answerKeySyncStatusFor(String examCode) => status;

  @override
  Future<CloudAnswerKeyRead?> readCloudAnswerKey(String examCode) async {
    effects.add('read:$examCode');
    return cloudRead;
  }

  @override
  Future<void> adoptAnswerKeyFromCloud(
    String examCode, {
    required int cloudVersion,
    required Map<String, String> answers,
    required DateTime updatedAt,
  }) async {
    adoptCalls++;
    lastAdoptVersion = cloudVersion;
    lastAdoptAnswers = Map.of(answers);
    lastAdoptUpdatedAt = updatedAt;
    effects.add('adopt:$examCode:$cloudVersion');
    answerKeys[examCode] =
        AnswerKey(examCode: examCode, correctChoices: Map.of(answers));
    status = AnswerKeySyncStatus.upToDate;
    notifyListeners();
  }

  @override
  Future<void> prepareAnswerKeyForcePush(
    String examCode,
    int expectedCloudVersion,
  ) async {
    forcePushCalls++;
    lastExpectedVersion = expectedCloudVersion;
    effects.add('force:$examCode:$expectedCloudVersion');
    status = AnswerKeySyncStatus.pending;
    notifyListeners();
  }
}

void main() {
  late Directory tempDir;
  late _FakeLocalStorage fakeStorage;
  late _FakeAppState appState;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ak_screen_test_');
    fakeStorage = _FakeLocalStorage();
    appState = _FakeAppState(
      batchRepository:
          LocalBatchRepository(rootOverride: Directory('${tempDir.path}/repo')),
      localStorage: fakeStorage,
    );
    appState.answerKeys['AT'] =
        AnswerKey(examCode: 'AT', correctChoices: Map.of(_localAnswers));
  });

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {/* AppState.dispose may touch unused camera handles */}
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {/* Windows may briefly hold a handle */}
  });

  // -- helpers -----------------------------------------------------------

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppStateScope(
          notifier: appState,
          child: const AnswerKeyEntryScreen(),
        ),
      ),
    );
    await tester.pump();
  }

  Finder banner() => find.byKey(const Key('answerKeyConflictBanner'));
  Finder inDialog(Finder matching) =>
      find.descendant(of: find.byType(AlertDialog), matching: matching);
  Finder bannerButton(String label) => find.descendant(
        of: banner(),
        matching: find.widgetWithText(TextButton, label),
      );

  Map<String, String> localKey() => appState.answerKeys['AT']!.correctChoices;

  // -- tests -----------------------------------------------------------

  for (final code in ['AT', 'QTM', 'TAT']) {
    testWidgets('$code uses configured items without changing the scan exam',
        (tester) async {
      appState.setActiveExamCode('AT');
      await tester.pumpWidget(MaterialApp(
        home: AppStateScope(
          notifier: appState,
          child: AnswerKeyEntryScreen(examCode: code),
        ),
      ));
      final template = omrTemplates[code]!;
      final count = template.sections.fold<int>(0, (n, s) => n + s.itemCount);
      expect(find.textContaining('/$count answered'), findsOneWidget);
      final section = template.sections.first;
      final item = section.items.keys.first;
      expect(find.byKey(ValueKey('editQuestion:${section.name}|$item')), findsOneWidget);
      expect(find.text('Answer Key — $code'), findsOneWidget);
      expect(appState.activeExamCode, 'AT');
    });
  }

  testWidgets('question text can be applied, cancelled, cleared and saved',
      (tester) async {
    await pumpScreen(tester);
    final edit = find.byKey(const ValueKey('editQuestion:Section 1|1'));
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('questionTextField')), 'Booklet question 1');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Booklet question 1'), findsOneWidget);
    expect(fakeStorage.savedAnswerKeys, isEmpty);

    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('questionTextField')), 'Cancelled edit');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Booklet question 1'), findsOneWidget);

    // Force the first save to fail so the screen remains open for a retry.
    fakeStorage.throwOnSaveAnswerKeys = StateError('disk full');
    await tester.tap(find.text('SAVE ANSWER KEY'));
    await tester.pumpAndSettle();
    expect(appState.answerKeys['AT']!.questionTexts, isEmpty);
    expect(find.text('Booklet question 1'), findsOneWidget);

    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('questionTextField')), '');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Booklet question 1'), findsNothing);
    await tester.tap(edit);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('questionTextField')), 'Saved question');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    fakeStorage.throwOnSaveAnswerKeys = null;
    await tester.tap(find.text('SAVE ANSWER KEY'));
    await tester.pumpAndSettle();
    final saved = fakeStorage.savedAnswerKeys.last['AT']!;
    expect(saved.questionTexts, {'Section 1|1': 'Saved question'});
    expect(saved.correctChoices, _localAnswers);
  });

  test('cloud adoption preserves device-local question text', () async {
    final state = AppState(
      batchRepository: appState.batchRepository,
      localStorage: fakeStorage,
      connectivityStream: const Stream<List<ConnectivityResult>>.empty(),
    );
    addTearDown(state.dispose);
    state.answerKeys['TAT'] = const AnswerKey(
      examCode: 'TAT',
      correctChoices: {'Test I|1': 'A'},
      questionTexts: {'Test I|1': 'Keep this question'},
    );
    await state.adoptAnswerKeyFromCloud(
      'TAT',
      cloudVersion: 2,
      answers: {'Test I|1': 'B'},
      updatedAt: DateTime.utc(2026),
    );
    final saved = fakeStorage.savedAnswerKeys.last['TAT']!;
    expect(saved.correctChoices, {'Test I|1': 'B'});
    expect(saved.questionTexts, {'Test I|1': 'Keep this question'});
  });

  testWidgets('1. a conflict status shows the persistent banner', (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    expect(banner(), findsOneWidget);
    expect(
      find.text(
          'This answer key was changed elsewhere and could not be synchronized.'),
      findsOneWidget,
    );
    expect(bannerButton('Review'), findsOneWidget);
    expect(bannerButton('Keep cloud'), findsOneWidget);
    expect(bannerButton('Replace cloud'), findsOneWidget);
    // Human wording only — no internal codes leak.
    expect(find.text('Conflict'), findsOneWidget);
    expect(find.textContaining('blockedConflict'), findsNothing);
    expect(find.textContaining('answer_key_changed'), findsNothing);
  });

  testWidgets('2. a non-conflict status shows no banner', (tester) async {
    appState.status = AnswerKeySyncStatus.upToDate;
    await pumpScreen(tester);
    expect(banner(), findsNothing);

    appState.setStatus(AnswerKeySyncStatus.pending);
    await tester.pump();
    expect(banner(), findsNothing);
    expect(find.text('Syncing'), findsOneWidget);
  });

  testWidgets('3. Keep cloud reads the cloud key and asks to confirm',
      (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    await tester.tap(bannerButton('Keep cloud'));
    await tester.pumpAndSettle();

    expect(appState.effects, ['read:AT']);
    expect(
      find.text('Discard your local answer-key changes and use the cloud version?'),
      findsOneWidget,
    );
    expect(inDialog(find.textContaining('Cloud version: 5')), findsOneWidget);
    expect(inDialog(find.textContaining('Officer Cruz')), findsOneWidget);
    // Not committed yet.
    expect(appState.adoptCalls, 0);
    expect(localKey(), _localAnswers);
  });

  testWidgets('4. confirming Keep cloud adopts the cloud key into the editor',
      (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    await tester.tap(bannerButton('Keep cloud'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Use cloud version'));
    await tester.pumpAndSettle();

    expect(appState.adoptCalls, 1);
    expect(appState.lastAdoptVersion, 5);
    expect(appState.lastAdoptAnswers,
        {'Test I|1': 'C', 'Test I|2': 'B', 'Test II|1': 'D'});
    expect(appState.lastAdoptUpdatedAt, DateTime.utc(2026, 5, 4, 8, 30));
    expect(appState.forcePushCalls, 0); // Keep cloud never force-pushes
    // Editor reloaded from the adopted local key (2 -> 3 answered).
    expect(find.textContaining(RegExp(r'\b3/\d+ answered')), findsOneWidget);
    expect(localKey(), {'Test I|1': 'C', 'Test I|2': 'B', 'Test II|1': 'D'});
  });

  testWidgets('5. after Keep cloud the conflict banner is gone', (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    await tester.tap(bannerButton('Keep cloud'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Use cloud version'));
    await tester.pumpAndSettle();

    expect(appState.status, AnswerKeySyncStatus.upToDate);
    expect(banner(), findsNothing);
  });

  testWidgets('6. Review is read-only (no editable controls in the dialog)',
      (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    await tester.tap(bannerButton('Review'));
    await tester.pumpAndSettle();

    expect(find.text('Review answer-key differences'), findsOneWidget);
    expect(inDialog(find.text('YOUR ANSWERS')), findsOneWidget);
    expect(inDialog(find.text('CLOUD ANSWERS')), findsOneWidget);
    expect(inDialog(find.textContaining('Cloud version: 5')), findsOneWidget);
    expect(inDialog(find.byType(TextField)), findsNothing);
    expect(inDialog(find.byType(Checkbox)), findsNothing);
    expect(inDialog(find.byType(Switch)), findsNothing);
    expect(inDialog(find.byType(Radio<String>)), findsNothing);
    // Opening Review changed nothing.
    expect(appState.adoptCalls, 0);
    expect(appState.forcePushCalls, 0);
  });

  testWidgets('7. opening then cancelling Review changes no data', (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);
    final before = Map<String, String>.of(localKey());

    await tester.tap(bannerButton('Review'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.widgetWithText(TextButton, 'Cancel')));
    await tester.pumpAndSettle();

    expect(localKey(), before);
    expect(appState.status, AnswerKeySyncStatus.conflict);
    expect(appState.adoptCalls, 0);
    expect(appState.forcePushCalls, 0);
    expect(banner(), findsOneWidget);
  });

  testWidgets('8. Replace cloud requires a second, destructive confirmation',
      (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    await tester.tap(bannerButton('Replace cloud'));
    await tester.pumpAndSettle();

    // First dialog: cloud info only.
    expect(find.text('Cloud answer key'), findsOneWidget);
    expect(find.text('Replace the cloud answer key?'), findsNothing);
    expect(appState.forcePushCalls, 0);

    await tester.tap(inDialog(find.widgetWithText(TextButton, 'Continue')));
    await tester.pumpAndSettle();

    // Second dialog: explicit destructive warning + cloud facts.
    expect(find.text('Replace the cloud answer key?'), findsOneWidget);
    expect(
      find.textContaining('permanently overwrite the newer cloud answer key '
          'with your local answer key'),
      findsOneWidget,
    );
    expect(inDialog(find.textContaining('Cloud version: 5')), findsOneWidget);
    expect(
        find.widgetWithText(FilledButton, 'Replace cloud key'), findsOneWidget);
    expect(appState.forcePushCalls, 0); // still nothing requested
  });

  testWidgets('9. confirming Replace cloud requests a force push with the '
      'expected cloud version', (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    await tester.tap(bannerButton('Replace cloud'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.widgetWithText(TextButton, 'Continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace cloud key'));
    await tester.pumpAndSettle();

    expect(appState.forcePushCalls, 1);
    expect(appState.lastExpectedVersion, 5);
    expect(appState.effects, ['read:AT', 'force:AT:5']);
  });

  testWidgets('10. Replace cloud does not change the local key and claims no '
      'success', (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    await tester.tap(bannerButton('Replace cloud'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.widgetWithText(TextButton, 'Continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace cloud key'));
    await tester.pumpAndSettle();

    expect(appState.adoptCalls, 0);
    expect(localKey(), _localAnswers); // untouched
    // Status is "Syncing", not a completed/synchronized claim.
    expect(appState.status, AnswerKeySyncStatus.pending);
    expect(find.text('Syncing'), findsOneWidget);
    expect(find.textContaining('finishes the next time the device syncs'),
        findsOneWidget);
    expect(find.textContaining('Synchronized'), findsNothing);
  });

  testWidgets('11. a cloud-read failure shows a sanitized error and keeps the '
      'conflict', (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    appState.cloudRead =
        const CloudAnswerKeyRead.failed(SyncOutcome.transient('network'));
    await pumpScreen(tester);

    await tester.tap(bannerButton('Keep cloud'));
    await tester.pumpAndSettle();

    expect(
      find.text('Discard your local answer-key changes and use the cloud version?'),
      findsNothing,
    );
    expect(find.textContaining('Could not load the cloud answer key'),
        findsOneWidget);
    expect(find.textContaining('network'), findsNothing); // no raw code
    expect(appState.adoptCalls, 0);
    expect(appState.forcePushCalls, 0);
    expect(appState.status, AnswerKeySyncStatus.conflict);
    expect(localKey(), _localAnswers);
    expect(banner(), findsOneWidget);
  });

  testWidgets('12. the screen only ever asks AppState to read or force-push — '
      'never a direct push/upload/delete', (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    // Review (cancel) then a full Replace cloud.
    await tester.tap(bannerButton('Review'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.widgetWithText(TextButton, 'Cancel')));
    await tester.pumpAndSettle();

    await tester.tap(bannerButton('Replace cloud'));
    await tester.pumpAndSettle();
    await tester.tap(inDialog(find.widgetWithText(TextButton, 'Continue')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Replace cloud key'));
    await tester.pumpAndSettle();

    expect(appState.effects, ['read:AT', 'read:AT', 'force:AT:5']);
    expect(appState.adoptCalls, 0);
  });

  testWidgets('13. cancelling any resolution path loses no local data',
      (tester) async {
    appState.status = AnswerKeySyncStatus.conflict;
    await pumpScreen(tester);

    Future<void> openAndCancel(String open, String cancelLabel) async {
      await tester.tap(bannerButton(open));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.widgetWithText(TextButton, cancelLabel)));
      await tester.pumpAndSettle();
      expect(localKey(), _localAnswers);
      expect(appState.status, AnswerKeySyncStatus.conflict);
      expect(appState.adoptCalls, 0);
      expect(appState.forcePushCalls, 0);
      expect(banner(), findsOneWidget);
    }

    await openAndCancel('Keep cloud', 'Cancel');
    await openAndCancel('Replace cloud', 'Cancel');
    await openAndCancel('Review', 'Cancel');

    expect(fakeStorage.savedAnswerKeys, isEmpty);
  });

  // -- SAVE ANSWER KEY handler (Phase 10F-1) ---------------------------

  group('SAVE ANSWER KEY awaits local persistence', () {
    /// Pushes the screen on top of a launcher route so a successful SAVE can
    /// pop back to something. [AppStateScope] is installed above the
    /// Navigator (via `builder`) so the pushed route can still reach it.
    Future<void> pushScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1600);
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
                      builder: (_) => const AnswerKeyEntryScreen(),
                    ),
                  ),
                  child: const Text('open key screen'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open key screen'));
      await tester.pumpAndSettle();
      expect(find.text('SAVE ANSWER KEY'), findsOneWidget);
    }

    testWidgets('14. a successful save persists locally then pops the screen',
        (tester) async {
      await pushScreen(tester);

      await tester.tap(find.text('SAVE ANSWER KEY'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull); // no unhandled Future
      expect(fakeStorage.savedAnswerKeys, isNotEmpty);
      expect(fakeStorage.savedAnswerKeys.last['AT']!.correctChoices,
          _localAnswers);
      expect(find.text('SAVE ANSWER KEY'), findsNothing); // popped
      expect(find.text('open key screen'), findsOneWidget); // back at launcher
    });

    testWidgets('15. a failed local save keeps the screen open and shows a '
        'SnackBar', (tester) async {
      fakeStorage.throwOnSaveAnswerKeys =
          const FileSystemException('prefs unavailable');
      await pushScreen(tester);

      await tester.tap(find.text('SAVE ANSWER KEY'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull); // exception was caught, not leaked
      expect(
        find.text('Could not save the answer key. Please try again.'),
        findsOneWidget,
      );
      expect(find.text('SAVE ANSWER KEY'), findsOneWidget); // still open
      expect(find.text('open key screen'), findsNothing); // not popped
      expect(fakeStorage.savedAnswerKeys, isEmpty);
    });

    testWidgets('16. the screen stays put until local persistence resolves',
        (tester) async {
      final gate = Completer<void>();
      fakeStorage.gateSaveAnswerKeys = gate;
      await pushScreen(tester);

      await tester.tap(find.text('SAVE ANSWER KEY'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Persistence is still blocked -> handler is still awaiting, no pop.
      expect(find.text('SAVE ANSWER KEY'), findsOneWidget);
      expect(find.text('open key screen'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(fakeStorage.savedAnswerKeys, isNotEmpty);
      expect(find.text('SAVE ANSWER KEY'), findsNothing); // now popped
      expect(tester.takeException(), isNull);
    });
  });
}
