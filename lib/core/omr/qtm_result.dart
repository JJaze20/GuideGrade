// QTM admission scoring: the official percentage and the course-eligibility
// band for a QTM raw score.
//
// PRESENTATION / DECISION-SUPPORT ONLY. This helper does not affect OMR
// scoring or persistence — it maps an already-computed QTM raw score
// (0..60) to the values the Guidance Council's QTM admission rule needs.
// QTM is the only exam with these eligibility bands.
//
// This file has no Firebase / Supabase / database / filesystem / Flutter /
// network dependency; it is pure and deterministic.

/// The fixed number of items on a QTM sheet — the denominator of the
/// official QTM percentage (never answer-key coverage).
const int _qtmItemCount = 60;

/// The official QTM percentage for [rawScoreOutOf60] (`raw / 60 * 100`), or
/// `null` when the raw score is outside the valid `0..60` range.
///
/// Computed as `raw * 100 / 60` — the same value as `raw / 60 * 100`,
/// arranged so the whole-number cases are exact in double precision
/// (`0 -> 0.0`, `15 -> 25.0`, `18 -> 30.0`, `30 -> 50.0`, `60 -> 100.0`).
double? qtmPercentage(int rawScoreOutOf60) {
  if (rawScoreOutOf60 < 0 || rawScoreOutOf60 > _qtmItemCount) return null;
  return rawScoreOutOf60 * 100 / _qtmItemCount;
}

/// The QTM course-eligibility outcomes, per the Guidance Council rule.
enum QtmEligibility {
  /// QTM percentage `>= 30%` (`raw >= 18`): qualifies for every
  /// QTM-required course, **including** BSCS.
  allCoursesIncludingBscs,

  /// QTM percentage `25%`–`29%` (`raw` 15..17): qualifies for every
  /// QTM-required course **except** BSCS.
  allCoursesExceptBscs,

  /// QTM percentage `< 25%` (`raw < 15`): does not meet the QTM
  /// requirement.
  notEligible,
}

/// Classifies [rawScoreOutOf60] into its [QtmEligibility] band, or `null`
/// when the raw score is outside the valid `0..60` range.
///
/// Because QTM has exactly 60 items, the percentage cut points (25% and
/// 30%, both inclusive) are exactly the raw-score cut points `>= 15` and
/// `>= 18`:
///
///  * `raw >= 18`   (>= 30%)    → [QtmEligibility.allCoursesIncludingBscs]
///  * `raw` 15..17  (25%–29%)   → [QtmEligibility.allCoursesExceptBscs]
///  * `raw < 15`    (< 25%)     → [QtmEligibility.notEligible]
QtmEligibility? qtmEligibility(int rawScoreOutOf60) {
  if (rawScoreOutOf60 < 0 || rawScoreOutOf60 > _qtmItemCount) return null;
  if (rawScoreOutOf60 >= 18) return QtmEligibility.allCoursesIncludingBscs;
  if (rawScoreOutOf60 >= 15) return QtmEligibility.allCoursesExceptBscs;
  return QtmEligibility.notEligible;
}
