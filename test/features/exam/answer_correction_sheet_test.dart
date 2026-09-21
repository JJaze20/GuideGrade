import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/features/exam/widgets/answer_correction_sheet.dart';
import 'package:guidegrade/models/answer_correction.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

AnswerEditTarget _target({AnswerCorrection? active, AnswerCorrection? earlier, String? key = 'A'}) {
  const detected = OmrItemResult(sectionName: 'Test II', itemNumber: 5, markedChoice: 'F', isAmbiguous: false);
  return AnswerEditTarget(
    sectionName: 'Test II',
    itemNumber: 5,
    detected: detected,
    current: active?.corrected ?? CorrectedAnswer.fromDetected(detected),
    keyChoice: key,
    choices: const ['T', 'F'],
    active: active,
    fromEarlierCapture: earlier,
  );
}

AnswerCorrection _c({int revision = 0}) => AnswerCorrection(
      id: 'x',
      scanId: 's',
      sectionName: 'Test II',
      itemNumber: 5,
      captureRevision: revision,
      action: CorrectionAction.set,
      original: const CorrectedAnswer.choice('F'),
      corrected: const CorrectedAnswer.choice('T'),
      correctedAt: DateTime.utc(2026),
    );

void main() {
  Future<void> open(
    WidgetTester tester,
    AnswerEditTarget target, {
    required Future<void> Function(CorrectedAnswer, String?, String) onSave,
    Future<void> Function(String)? onReset,
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAnswerCorrectionSheet(
                  context,
                  target: target,
                  onSave: onSave,
                  onReset: onReset ?? (_) async {},
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

  testWidgets('shows section, question number, detected answer, key and explains the yellow ring', (tester) async {
    await open(tester, _target(), onSave: (_, __, ___) async {});
    expect(find.text('Test II · Question 5'), findsOneWidget);
    expect(find.text('F'), findsWidgets);
    expect(find.textContaining('yellow ring'), findsOneWidget);
    expect(find.textContaining('NOT what the student marked'), findsOneWidget);
    expect(find.text('Blank'), findsOneWidget);
    expect(find.text('Multiple marks'), findsOneWidget);
  });

  testWidgets('choosing the key answer is an explicit selection: Save is disabled until something changes', (tester) async {
    await open(tester, _target(), onSave: (_, __, ___) async {});
    expect(tester.widget<FilledButton>(find.byKey(const Key('answerCorrection.save'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('answerCorrection.choice.T')));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.byKey(const Key('answerCorrection.save'))).onPressed, isNotNull);
  });

  testWidgets('repeated Save taps send exactly one request with one stable id', (tester) async {
    final gate = Completer<void>();
    final calls = <String>[];
    await open(tester, _target(), onSave: (v, r, id) async {
      calls.add(id);
      await gate.future;
    });
    await tester.tap(find.byKey(const Key('answerCorrection.choice.T')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('answerCorrection.save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('answerCorrection.save')), warnIfMissed: false);
    await tester.pump();
    expect(calls, hasLength(1));
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('a failed save keeps the sheet open, shows the message and a retry reuses the same id', (tester) async {
    final ids = <String>[];
    var fail = true;
    await open(tester, _target(), onSave: (v, r, id) async {
      ids.add(id);
      if (fail) throw StateError('This sheet was rescanned after the editor opened.');
    });
    await tester.tap(find.byKey(const Key('answerCorrection.choice.Blank')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('answerCorrection.save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('answerCorrection.error')), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const Key('answerCorrection.save')));
    await tester.pumpAndSettle();
    expect(ids, hasLength(2));
    expect(ids.first, ids.last);
  });

  testWidgets('Reset to detected answer appears only when a correction is active', (tester) async {
    await open(tester, _target(), onSave: (_, __, ___) async {});
    expect(find.byKey(const Key('answerCorrection.reset')), findsNothing);
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pumpAndSettle();

    String? resetId;
    await open(tester, _target(active: _c()), onSave: (_, __, ___) async {}, onReset: (id) async => resetId = id);
    await tester.tap(find.byKey(const Key('answerCorrection.reset')));
    await tester.pumpAndSettle();
    expect(resetId, isNotNull);
  });

  testWidgets('a correction from before a rescan is explained and not applied', (tester) async {
    await open(tester, _target(earlier: _c()), onSave: (_, __, ___) async {});
    expect(find.byKey(const Key('answerCorrection.earlierCapture')), findsOneWidget);
    expect(find.textContaining('not applied to the new scan'), findsOneWidget);
  });
}
