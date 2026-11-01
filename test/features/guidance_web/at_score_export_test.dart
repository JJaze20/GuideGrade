import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/at_categories.dart';
import 'package:guidegrade/core/omr/at_sai.dart';
import 'package:guidegrade/features/guidance_web/export/at_score_export.dart';

AtCategoryScores _scores({
  int vc = 6,
  int vr = 11,
  int fr = 7,
  int qr = 10,
  int vrTotal = 24,
}) => AtCategoryScores({
  AtCategory.vc: AtCategoryScore(AtCategory.vc, vc, 12),
  AtCategory.vr: AtCategoryScore(AtCategory.vr, vr, vrTotal),
  AtCategory.fr: AtCategoryScore(AtCategory.fr, fr, 18),
  AtCategory.qr: AtCategoryScore(AtCategory.qr, qr, 18),
});

String _fmt(DateTime d) => '${d.year}-${d.month}-${d.day}';

void main() {
  final birth = DateTime(2008, 2, 5);
  final exam = DateTime(2026, 11, 1);

  test('the specification example', () {
    final out = buildExportScaledScores(
      computeAtScoreProfile(_scores(), birthDate: birth, examDate: exam),
      birthDate: birth,
      examDate: exam,
      formatDate: _fmt,
    );
    expect(out.rows.map((r) => (r.label, r.raw, r.scaled, r.sai)), [
      ('Total', '34 / 72', '637', '89'),
      ('Verbal', '17 / 36', '645', '92'),
      ('Nonverbal', '17 / 36', '630', '89'),
    ]);
    expect(
      out.basis,
      'Age on the exam date: 18 years 8 months - Table 24, 6-8 months',
    );
    expect(out.dates, 'Born 2008-2-5 - Exam 2026-11-1');
    expect(out.note, isNull);
  });

  test('a raw score of 0 prints a dash for the scaled score, 50 for the SAI', () {
    final out = buildExportScaledScores(
      computeAtScoreProfile(
        _scores(vc: 0, vr: 0),
        birthDate: birth,
        examDate: exam,
      ),
      birthDate: birth,
      examDate: exam,
      formatDate: _fmt,
    );
    final verbal = out.rows[1];
    expect([verbal.raw, verbal.scaled, verbal.sai], ['0 / 36', '-', '50']);
    expect(out.note, 'A raw score of 0 has no scaled score; its SAI is 50.');
  });

  test('under 17 gives scaled scores, no SAI, and says why', () {
    final young = DateTime(2010, 6, 1);
    final out = buildExportScaledScores(
      computeAtScoreProfile(_scores(), birthDate: young, examDate: exam),
      birthDate: young,
      examDate: exam,
      formatDate: _fmt,
    );
    expect(out.rows.first.scaled, '637');
    expect(out.rows.first.sai, '-');
    expect(out.basis, isNull);
    expect(
      out.note,
      'SAI not given: the age on the exam date is 16 years 5 months, and the '
      'SAI tables start at age 17.',
    );
  });

  test('a birth date after the exam date is explained', () {
    final late = DateTime(2026, 12, 1);
    final out = buildExportScaledScores(
      computeAtScoreProfile(_scores(), birthDate: late, examDate: exam),
      birthDate: late,
      examDate: exam,
      formatDate: _fmt,
    );
    expect(out.note, 'SAI not given: the birth date is after the exam date.');
  });

  test('both dates missing: the note names both and no dates line is printed', () {
    final out = buildExportScaledScores(
      computeAtScoreProfile(_scores()),
      formatDate: _fmt,
    );
    expect(
      out.note,
      'SAI not given: the birth date and the exam date have not been entered.',
    );
    expect(out.dates, isNull);
    expect(out.basis, isNull);
  });

  test('an answer key that is not 36 Verbal / 36 Nonverbal prints no conversions', () {
    final out = buildExportScaledScores(
      computeAtScoreProfile(
        _scores(vrTotal: 30),
        birthDate: birth,
        examDate: exam,
      ),
      birthDate: birth,
      examDate: exam,
      formatDate: _fmt,
    );
    expect(out.rows.map((r) => r.scaled), ['-', '-', '-']);
    expect(out.rows.map((r) => r.sai), ['-', '-', '-']);
    expect(out.rows.first.raw, '34 / 72'); // the raw scores are still reported
    expect(
      out.note,
      'Scaled scores and SAI not given: the answer key does not have exactly '
      '36 Verbal and 36 Nonverbal items.',
    );
  });
}
