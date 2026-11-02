/// Admission Test admission-category bands.
///
/// PRESENTATION-ONLY. This helper does not affect scoring, persistence, or
/// any Phase 1–3 rule — it maps an already-computed Admission Test raw
/// score (0..72) to a display band. The Admission Test is the only exam
/// that has categories.
///
/// This file has no Firebase / Supabase / database / filesystem / Flutter /
/// network dependency.
enum AdmissionCategory { a, b, c, d }

/// The Admission Test category is decided by the examinee's **Total SAI**
/// (School Ability Index), per the Guidance Council's cut-off scores:
///
///  * A: 76 and below
///  * B: 77 to 84  (77, 78 and 79 belong to B)
///  * C: 85 to 89
///  * D: 90 and above
///
/// The Total SAI needs the birth date and exam date; an examinee without one
/// has no category ("Not classified"), never a guess. See `atAdmissionCategory`
/// in at_sai.dart.
AdmissionCategory admissionCategoryFromSai(int totalSai) {
  if (totalSai <= 76) return AdmissionCategory.a;
  if (totalSai <= 84) return AdmissionCategory.b;
  if (totalSai <= 89) return AdmissionCategory.c;
  return AdmissionCategory.d;
}

/// The Total SAI range printed for each category.
String admissionSaiRange(AdmissionCategory category) => switch (category) {
  AdmissionCategory.a => '76 and below',
  AdmissionCategory.b => '77 - 84',
  AdmissionCategory.c => '85 - 89',
  AdmissionCategory.d => '90 and above',
};

/// Legacy: maps an Admission Test RAW score (out of 72) to a band. The
/// official category is now decided by the Total SAI
/// ([admissionCategoryFromSai]); this raw-score rule is no longer shown
/// anywhere to the user.
///
/// Maps an Admission Test raw score (out of 72) to its [AdmissionCategory],
/// or `null` when outside the valid 0–72 range.
///
/// Categories use raw scores, without converting to percentages:
///
///  * `0`–`54`  → [AdmissionCategory.a]
///  * `55`–`60` → [AdmissionCategory.b]
///  * `61`–`64` → [AdmissionCategory.c]
///  * `65`–`72` → [AdmissionCategory.d]
///  * `< 0` or `> 72` → `null`
AdmissionCategory? admissionCategory(int rawScoreOutOf72) {
  if (rawScoreOutOf72 < 0 || rawScoreOutOf72 > 72) return null;
  if (rawScoreOutOf72 <= 54) return AdmissionCategory.a;
  if (rawScoreOutOf72 <= 60) return AdmissionCategory.b;
  if (rawScoreOutOf72 <= 64) return AdmissionCategory.c;
  return AdmissionCategory.d; // 65–72
}
