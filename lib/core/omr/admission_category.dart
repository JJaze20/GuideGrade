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
