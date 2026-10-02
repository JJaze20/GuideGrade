import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/shared/widgets/examinee_dialog.dart';

void main() {
  testWidgets('saving with a blank name but a filled examinee number succeeds', (tester) async {
    ExamineeDialogResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                captured = await showExamineeDialog(context, sheetLabel: 'Sheet 1');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Last/First/Middle Name are left blank -- only the examinee number is
    // filled in, mirroring a counselor who doesn't know the name yet.
    await tester.enterText(find.byKey(const Key('examineeDialog.examineeNumber')), 'X-1001');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.cleared, isFalse);
    expect(captured!.info!.firstName, '');
    expect(captured!.info!.lastName, '');
    expect(captured!.info!.examineeNumber, 'X-1001');
    // The dialog itself is gone -- Save actually completed instead of being
    // blocked by a validator.
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('saving with a blank examinee number is still blocked', (tester) async {
    ExamineeDialogResult? captured;
    var resultSet = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                captured = await showExamineeDialog(context, sheetLabel: 'Sheet 1');
                resultSet = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('examineeDialog.lastName')), 'Dela Cruz');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Examinee Number is still required -- the dialog must still be open,
    // and showExamineeDialog's Future must not have resolved yet.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Required'), findsOneWidget);
    expect(resultSet, isFalse);
    expect(captured, isNull);
  });
}
