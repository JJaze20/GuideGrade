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
    ValueChanged<ExamineeDialogResult?>? onSaved,
    Set<String> otherNumbers = const {},
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
                    otherNumbers: otherNumbers,
                  );
                  onSaved?.call(result);
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

  testWidgets('only the four identity fields are editable', (tester) async {
    await open(tester);
    expect(find.byType(TextFormField), findsNWidgets(4));
    for (final field in ['lastName','firstName','middleName','examineeNumber']) {
      expect(find.byKey(Key('examineeDialog.$field')), findsOneWidget);
    }
    for (final field in ['birthDate','age','ageDerived','lastSchool']) {
      expect(find.byKey(Key('examineeDialog.$field')), findsNothing);
    }
  });

  testWidgets('required and duplicate examinee numbers still block saving', (tester) async {
    await open(tester, otherNumbers: {'101'});
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Required'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('examineeDialog.examineeNumber')), '101');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Already used by another sheet in this batch'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('editing a full middle name preserves hidden saved details', (tester) async {
    ExamineeDialogResult? saved;
    await open(
      tester,
      initial: ExamineeInfo(
        firstName: 'A',
        lastName: 'B',
        examineeNumber: '1',
        birthDate: DateTime(2010, 6, 15),
        manualAge: 16,
        lastSchool: 'Existing school',
      ),
      onSaved: (result) => saved = result,
    );
    await tester.enterText(find.byKey(const Key('examineeDialog.middleName')), 'Maria del Carmen');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved?.info?.middleName, 'Maria del Carmen');
    expect(saved?.info?.birthDate, DateTime(2010, 6, 15));
    expect(saved?.info?.manualAge, 16);
    expect(saved?.info?.lastSchool, 'Existing school');
    expect(saved?.info?.examineeNumber, '1');
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
