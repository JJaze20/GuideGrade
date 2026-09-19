import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/guidance/screens/edit_batch_screen.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/shared/widgets/form_field_decoration.dart';

/// Records what Edit Batch saves; nothing else of the interface is used.
class _RecordingRepo implements BatchRepository {
  LocalBatch? saved;

  @override
  Future<LocalBatch> updateBatch(LocalBatch batch) async {
    saved = batch;
    return batch;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalBatch _batch({String status = 'Active', int expected = 10}) => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude Test',
      description: 'first',
      expectedCount: expected,
      status: status,
      createdByUid: 'u',
      createdByName: 'n',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  late _RecordingRepo repo;
  late AppState appState;

  setUp(() {
    repo = _RecordingRepo();
    appState = AppState(batchRepository: repo);
  });

  tearDown(() {
    try {
      appState.dispose();
    } catch (_) {}
  });

  Future<void> open(WidgetTester tester, LocalBatch batch) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: EditBatchScreen(batch: batch),
      ),
    );
    await tester.pumpAndSettle();
  }

  InputDecoration decorationOf(WidgetTester tester, Key key) {
    final field = tester.widget<TextField>(find.descendant(of: find.byKey(key), matching: find.byType(TextField)));
    return field.decoration!;
  }

  testWidgets('every input has a visible outline in the resting, focused, disabled and error states', (tester) async {
    await open(tester, _batch());
    for (final key in const [
      Key('editBatch.batchCode'),
      Key('editBatch.description'),
      Key('editBatch.expectedCount'),
    ]) {
      final d = decorationOf(tester, key);
      for (final border in [d.enabledBorder, d.focusedBorder, d.disabledBorder, d.errorBorder, d.focusedErrorBorder]) {
        final side = (border as OutlineInputBorder).borderSide;
        expect(side.style, BorderStyle.solid, reason: '$key has a drawn border');
        expect(side.width, greaterThanOrEqualTo(1.0));
      }
      expect(d.filled, isTrue);
    }
  });

  testWidgets('the resting border has at least 3:1 contrast against the field fill', (tester) async {
    final a = FormFieldStyle.restingBorder.computeLuminance();
    final b = FormFieldStyle.fill.computeLuminance();
    final ratio = (b + 0.05) / (a + 0.05);
    expect(ratio, greaterThanOrEqualTo(3.0));
  });

  testWidgets('required fields are marked and the status is read-only text, not a picker', (tester) async {
    await open(tester, _batch());
    expect(find.textContaining('*'), findsWidgets);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.byKey(const Key('editBatch.statusCard')), findsOneWidget);
    expect(find.textContaining('Current status: '), findsOneWidget);
  });

  testWidgets('an invalid expected count shows a helpful message and does not save', (tester) async {
    await open(tester, _batch());
    await tester.enterText(find.byKey(const Key('editBatch.expectedCount')), '0');
    await tester.pump();
    expect(find.textContaining('greater than zero'), findsWidgets);
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();
    expect(repo.saved, isNull);
    expect(find.textContaining('Draft'), findsWidgets, reason: 'the preview explains it would be Draft');
  });

  testWidgets('description and count stay editable on an Archived batch and saving passes no status choice', (tester) async {
    await open(tester, _batch(status: 'Archived'));
    await tester.enterText(find.byKey(const Key('editBatch.description')), 'edited');
    await tester.enterText(find.byKey(const Key('editBatch.expectedCount')), '12');
    await tester.tap(find.text('Save Changes'));
    await tester.pumpAndSettle();
    expect(repo.saved, isNotNull);
    expect(repo.saved!.description, 'edited');
    expect(repo.saved!.expectedCount, 12);
    expect(repo.saved!.status, 'Archived', reason: 'the repository, not the form, derives the new status');
  });
}
