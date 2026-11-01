import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/at_categories.dart';
import 'package:guidegrade/core/omr/at_sai.dart';
import 'package:guidegrade/features/guidance_web/widgets/at_score_table.dart';

AtCategoryScores _scores({int vrTotal = 24}) => AtCategoryScores({
  AtCategory.vc: const AtCategoryScore(AtCategory.vc, 6, 12),
  AtCategory.vr: AtCategoryScore(AtCategory.vr, 11, vrTotal),
  AtCategory.fr: const AtCategoryScore(AtCategory.fr, 7, 18),
  AtCategory.qr: const AtCategoryScore(AtCategory.qr, 10, 18),
});

String? _note(
  AtScoreProfile p, {
  bool linked = true,
  bool birth = true,
  bool exam = true,
}) => atScoreNote(
  p,
  hasLinkedExaminee: linked,
  hasBirthDate: birth,
  hasExamDate: exam,
);

void main() {
  final birth = DateTime(2008, 2, 5);
  final exam = DateTime(2026, 11, 1);

  test('no note when the SAI is given', () {
    final p = computeAtScoreProfile(
      _scores(),
      birthDate: birth,
      examDate: exam,
    );
    expect(_note(p), isNull);
  });

  test('missing dates say exactly what is missing', () {
    final none = computeAtScoreProfile(_scores());
    expect(
      _note(none, birth: false, exam: false),
      'Add the birth date and the exam date (Edit Examinee) to see the SAI.',
    );
    expect(
      _note(none, birth: true, exam: false),
      'Add the exam date (Edit Examinee) to see the SAI.',
    );
    expect(
      _note(none, birth: false, exam: true),
      'Add the birth date (Edit Examinee) to see the SAI.',
    );
  });

  test('an unlinked scan is told to link it first', () {
    final p = computeAtScoreProfile(_scores());
    expect(_note(p, linked: false), contains('Link this scan'));
  });

  test('a birth date after the exam date is explained', () {
    final p = computeAtScoreProfile(
      _scores(),
      birthDate: DateTime(2026, 12, 1),
      examDate: exam,
    );
    expect(_note(p), contains('after the exam date'));
  });

  test('under 17 states the age and why there is no SAI', () {
    final p = computeAtScoreProfile(
      _scores(),
      birthDate: DateTime(2010, 6, 1),
      examDate: exam,
    );
    expect(_note(p), contains('16 years 5 months'));
    expect(_note(p), contains('start at age 17'));
  });

  test('an answer key that is not 36 / 36 is explained', () {
    final p = computeAtScoreProfile(
      _scores(vrTotal: 30),
      birthDate: birth,
      examDate: exam,
    );
    expect(_note(p), contains('36 Verbal and 36 Nonverbal'));
  });
}
