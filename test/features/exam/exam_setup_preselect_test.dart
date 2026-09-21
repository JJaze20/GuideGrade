import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/exam/screens/exam_setup_screen.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/shared/widgets/primary_button.dart';

/// Serves a fixed list of batches; the Select Batch screen reads nothing else.
class _FakeRepo implements BatchRepository {
  _FakeRepo(this.batches);
  final List<LocalBatch> batches;

  @override
  Future<List<LocalBatch>> getBatchesByExamCode(String examCode) async =>
      [for (final b in batches) if (b.examCode == examCode) b];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalBatch _batch(String id, String code, {String exam = 'AT', DateTime? updated}) => LocalBatch(
      id: id,
      batchCode: code,
      examCode: exam,
      examTitle: 'x',
      description: '',
      expectedCount: 10,
      status: 'Active',
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: DateTime.utc(2026),
      updatedAt: updated ?? DateTime.utc(2026),
    );

void main() {
  late AppState appState;

  Future<void> open(WidgetTester tester, List<LocalBatch> batches, {String? preselect}) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appState = AppState(batchRepository: _FakeRepo(batches));
    appState.setActiveExamCode('AT');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: ExamSetupScreen(preselectBatchId: preselect),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {}
  });

  bool startEnabled(WidgetTester tester) =>
      tester.widget<PrimaryButton>(find.widgetWithText(PrimaryButton, 'START SCANNING')).onPressed != null;

  testWidgets('the batch pressed on the home screen is already selected', (tester) async {
    await open(
      tester,
      [
        _batch('b1', 'B-NEWER', updated: DateTime.utc(2026, 3)),
        _batch('b2', 'B-PRESSED', updated: DateTime.utc(2026, 2)),
        _batch('b3', 'B-OLDER', updated: DateTime.utc(2026, 1)),
      ],
      preselect: 'b2',
    );
    expect(startEnabled(tester), isTrue, reason: 'a batch is selected, so scanning can start');
  });

  testWidgets('with no batch pressed nothing is preselected', (tester) async {
    await open(tester, [_batch('b1', 'B-1'), _batch('b2', 'B-2')]);
    expect(startEnabled(tester), isFalse);
  });

  testWidgets('a batch for another exam is not preselected', (tester) async {
    await open(tester, [_batch('b1', 'B-1', exam: 'QTM'), _batch('b2', 'B-2')], preselect: 'b1');
    expect(startEnabled(tester), isFalse, reason: 'b1 is not an AT batch, so it is not in the list');
  });

  testWidgets('the user can still pick a different batch afterwards', (tester) async {
    await open(tester, [_batch('b1', 'B-ONE'), _batch('b2', 'B-TWO')], preselect: 'b1');
    expect(startEnabled(tester), isTrue);
    await tester.tap(find.text('Batch B-TWO'));
    await tester.pumpAndSettle();
    expect(startEnabled(tester), isTrue);
  });
}
