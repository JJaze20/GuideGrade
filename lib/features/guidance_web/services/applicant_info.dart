import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart' show ExamineeInfo;

/// The applicant details shown next to an examination result: age, sex and
/// last school attended. Pure and display-oriented -- every value is read
/// from the examinee's own record (entered on the Web Console) and nothing is
/// guessed: a field that was never entered is simply null.
class ApplicantInfo {
  const ApplicantInfo({
    this.ageYears,
    this.ageOnScanDate = false,
    this.sex,
    this.school,
  });

  /// Whole years, or null when the birth date is not known (or is after the
  /// date used).
  final int? ageYears;

  /// True when no exam date was entered, so the age is counted on the day the
  /// sheet was scanned instead. Shown, never hidden.
  final bool ageOnScanDate;

  /// "Male" / "Female" as entered, or null.
  final String? sex;

  /// Last school attended as entered, or null.
  final String? school;

  /// "18 years", "18 years (on scan date)", or null when there is no age.
  String? get ageText {
    final years = ageYears;
    if (years == null) return null;
    final base = years == 1 ? '1 year' : '$years years';
    return ageOnScanDate ? '$base (on scan date)' : base;
  }
}

/// The details for [examinee] on [examDate], or on the local day of
/// [scanDate] when no exam date was entered. A null [examinee] (an unlinked
/// scan) has no details.
ApplicantInfo applicantInfoFor({
  required ExamineeRecord? examinee,
  DateTime? examDate,
  required DateTime scanDate,
}) {
  if (examinee == null) return const ApplicantInfo();
  String? clean(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  final birth = examinee.birthDate;
  int? years;
  if (birth != null) {
    final on = examDate ?? scanDate.toLocal();
    years = ExamineeInfo.ageFromBirthDate(birth, on);
  }
  return ApplicantInfo(
    ageYears: years,
    ageOnScanDate: years != null && examDate == null,
    sex: clean(examinee.gender),
    school: clean(examinee.lastAttendedSchool),
  );
}
