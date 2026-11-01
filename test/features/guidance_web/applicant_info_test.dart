import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/features/guidance_web/services/applicant_info.dart';
import 'package:guidegrade/models/examinee_record.dart';

ExamineeRecord _examinee({
  DateTime? birthDate,
  String? gender,
  String? school,
}) => ExamineeRecord(
  id: 'e1',
  temporaryExamineeId: 'EX-000001',
  firstName: 'Juan',
  lastName: 'Dela Cruz',
  birthDate: birthDate,
  lastAttendedSchool: school,
  gender: gender,
  status: 'active',
  createdAt: DateTime.utc(2026, 1, 1),
  createdByUid: 'u',
  updatedAt: DateTime.utc(2026, 1, 1),
  updatedByUid: 'u',
);

void main() {
  final scan = DateTime.utc(2026, 10, 28, 7, 20);

  test('an unlinked scan has no details', () {
    final info = applicantInfoFor(examinee: null, scanDate: scan);
    expect(info.ageYears, isNull);
    expect(info.ageText, isNull);
    expect(info.sex, isNull);
    expect(info.school, isNull);
  });

  test(
    'the age is counted on the exam date, not on the scan date or today',
    () {
      final info = applicantInfoFor(
        examinee: _examinee(birthDate: DateTime(2008, 2, 5)),
        examDate: DateTime(2026, 2, 4), // the day before the 18th birthday
        scanDate: scan,
      );
      expect(info.ageYears, 17);
      expect(info.ageText, '17 years');
      expect(info.ageOnScanDate, isFalse);
    },
  );

  test('on the birthday the examinee has turned a year older', () {
    final info = applicantInfoFor(
      examinee: _examinee(birthDate: DateTime(2008, 2, 5)),
      examDate: DateTime(2026, 2, 5),
      scanDate: scan,
    );
    expect(info.ageText, '18 years');
  });

  test('with no exam date the scan date is used, and the text says so', () {
    final info = applicantInfoFor(
      examinee: _examinee(birthDate: DateTime(2008, 2, 5)),
      scanDate: scan,
    );
    expect(info.ageYears, 18);
    expect(info.ageOnScanDate, isTrue);
    expect(info.ageText, '18 years (on scan date)');
  });

  test('no birth date means no age (never guessed)', () {
    final info = applicantInfoFor(
      examinee: _examinee(gender: 'Male'),
      examDate: DateTime(2026, 11, 1),
      scanDate: scan,
    );
    expect(info.ageYears, isNull);
    expect(info.ageText, isNull);
    expect(info.ageOnScanDate, isFalse);
  });

  test('a birth date after the exam date gives no age', () {
    final info = applicantInfoFor(
      examinee: _examinee(birthDate: DateTime(2026, 12, 1)),
      examDate: DateTime(2026, 11, 1),
      scanDate: scan,
    );
    expect(info.ageYears, isNull);
  });

  test(
    'sex and school are passed through, trimmed, and blanks become null',
    () {
      final filled = applicantInfoFor(
        examinee: _examinee(gender: ' Female ', school: '  Marbel NHS '),
        scanDate: scan,
      );
      expect(filled.sex, 'Female');
      expect(filled.school, 'Marbel NHS');

      final blank = applicantInfoFor(
        examinee: _examinee(gender: '  ', school: ''),
        scanDate: scan,
      );
      expect(blank.sex, isNull);
      expect(blank.school, isNull);
    },
  );

  test('one year old reads as "1 year"', () {
    final info = applicantInfoFor(
      examinee: _examinee(birthDate: DateTime(2025, 6, 1)),
      examDate: DateTime(2026, 11, 1),
      scanDate: scan,
    );
    expect(info.ageText, '1 year');
  });
}
