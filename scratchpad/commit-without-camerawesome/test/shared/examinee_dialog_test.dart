import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/shared/widgets/examinee_dialog.dart';

void main() {
  Future<ExamineeDialogResult?> open(
    WidgetTester tester, {
    ExamineeInfo? initial,
    DateTime? examDate,
    VoidCallback? onReviewAnswers,
  }) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ExamineeDialogResult? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showExamineeDialog(
                    context,
                    initial: initial,
                    examDate: examDate ?? DateTime(2026, 6, 15),
                    onReviewAnswers: onReviewAnswers,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('saves with only an examinee number: every new detail is optional', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('examineeDialog.examineeNumber')), '101');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('age can be entered alone when the birth date is unknown', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('examineeDialog.examineeNumber')), '101');
    await tester.enterText(find.byKey(const Key('examineeDialog.age')), '17');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('an out-of-range age shows a helpful message and blocks saving', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('examineeDialog.examineeNumber')), '101');
    await tester.enterText(find.byKey(const Key('examineeDialog.age')), '2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter an age from'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('with a birth date the age is derived and read-only (no second editable age)', (tester) async {
    await open(
      tester,
      initial: ExamineeInfo(
        firstName: 'A',
        lastName: 'B',
        examineeNumber: '1',
        birthDate: DateTime(2010, 6, 15),
      ),
    );
    expect(find.byKey(const Key('examineeDialog.age')), findsNothing);
    expect(find.byKey(const Key('examineeDialog.ageDerived')), findsOneWidget);
    expect(find.text('16'), findsOneWidget, reason: 'age on the 2026-06-15 exam date');
  });

  testWidgets('the answers section is separate and only shown when review is available', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('examineeDialog.reviewAnswers')), findsNothing);
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();

    var reviewed = false;
    await open(tester, onReviewAnswers: () => reviewed = true);
    await tester.ensureVisible(find.byKey(const Key('examineeDialog.reviewAnswers')));
    await tester.tap(find.byKey(const Key('examineeDialog.reviewAnswers')));
    await tester.pump();
    expect(reviewed, isTrue);
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the identity form stays open underneath');
  });
}
