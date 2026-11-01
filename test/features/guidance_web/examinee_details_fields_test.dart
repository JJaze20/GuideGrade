import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/features/guidance_web/widgets/examinee_details_fields.dart';

void main() {
  final today = DateTime(2026, 11, 1);

  group('ExamineeDetailsController.validate', () {
    test('empty details are fine -- every field is optional', () {
      final c = ExamineeDetailsController();
      expect(c.validate(now: today), isNull);
      c.dispose();
    });

    test('a normal birth date and exam date pass', () {
      final c = ExamineeDetailsController(
        birthDate: DateTime(2008, 2, 5),
        examDate: DateTime(2026, 10, 5),
      );
      expect(c.validate(now: today), isNull);
      c.dispose();
    });

    test('an exam date in the future is refused', () {
      final c = ExamineeDetailsController(examDate: DateTime(2026, 11, 2));
      expect(c.validate(now: today), contains('exam date'));
      c.dispose();
    });

    test('an exam date today is allowed', () {
      final c = ExamineeDetailsController(examDate: today);
      expect(c.validate(now: today), isNull);
      c.dispose();
    });

    test('a birth date in the future is refused', () {
      final c = ExamineeDetailsController(birthDate: DateTime(2027, 1, 1));
      expect(c.validate(now: today), contains('future'));
      c.dispose();
    });

    test('a birth date after the exam date is refused', () {
      final c = ExamineeDetailsController(
        birthDate: DateTime(2026, 10, 10),
        examDate: DateTime(2026, 10, 5),
      );
      expect(c.validate(now: today), contains('after the examination date'));
      c.dispose();
    });

    test('an impossible age (over 100) is refused', () {
      final c = ExamineeDetailsController(birthDate: DateTime(1900, 1, 1));
      expect(c.validate(now: today), contains('age over'));
      c.dispose();
    });

    test('times are dropped: only the calendar day is kept', () {
      final c = ExamineeDetailsController(
        birthDate: DateTime.utc(2008, 2, 5, 23, 59),
      );
      expect(c.birthDate, DateTime(2008, 2, 5));
      c.dispose();
    });
  });

  group('ExamineeDetailsController values', () {
    test('a blank school or gender reads as null', () {
      final c = ExamineeDetailsController(lastSchool: '   ', gender: '  ');
      expect(c.lastSchoolOrNull, isNull);
      expect(c.gender, isNull);
      c.dispose();
    });

    test('the school is trimmed', () {
      final c = ExamineeDetailsController(lastSchool: '  Marbel NHS ');
      expect(c.lastSchoolOrNull, 'Marbel NHS');
      c.dispose();
    });

    test('dates are shown as "Mon d, yyyy"', () {
      expect(formatDetailDate(DateTime(2026, 10, 5)), 'Oct 5, 2026');
    });
  });

  testWidgets('a stored gender that is not in the list is still shown', (
    tester,
  ) async {
    final c = ExamineeDetailsController(gender: 'Non-binary');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ExamineeDetailsFields(controller: c)),
      ),
    );
    expect(find.text('Non-binary'), findsOneWidget);
  });

  testWidgets('the exam date field only appears when asked for', (
    tester,
  ) async {
    final c = ExamineeDetailsController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ExamineeDetailsFields(controller: c)),
      ),
    );
    expect(find.text('Exam date (Admission Test)'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExamineeDetailsFields(controller: c, showExamDate: true),
        ),
      ),
    );
    expect(find.text('Exam date (Admission Test)'), findsOneWidget);
  });
}
