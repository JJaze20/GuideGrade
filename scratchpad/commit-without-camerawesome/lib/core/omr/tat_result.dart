// TAT admission scoring: the official percentage and the course-eligibility
// outcome for a combined TAT total score.
//
// PRESENTATION / DECISION-SUPPORT ONLY. This helper does not affect OMR
// scoring or persistence — it maps an already-computed TAT total score
// (0..160) to the values the Guidance Council's TAT admission rule needs.
//
// The Guidance Head's confirmed rule (authoritative for this app):
//   Test 1 max 60, Test 2 max 80, Test 3 max 20  ->  total max 160
//   total >= 48  (= 30% of 160)  ->  meets the TAT requirement
//   total <= 47  (< 30%)         ->  does not meet the TAT requirement
// The six courses covered by the requirement are English, Filipino,
// Mathematics, Science, Social Studies and Religious Education.
//
// This file has no Firebase / Supabase / database / filesystem / Flutter /
// network dependency; it is pure and deterministic.

/// The maximum combined TAT score — the denominator of the official TAT
/// percentage (Test 1 max 60 + Test 2 max 80 + Test 3 max 20).
const int _tatMaxScore = 160;

/// The smallest TAT total score that meets the TAT requirement
/// (`48 / 160 == 30%`).
const int _tatMinScoreToMeet = 48;

/// The official TAT percentage for [tatTotalOutOf160] (`total / 160 * 100`),
/// or `null` when the total is outside the valid `0..160` range.
///
/// Computed as `total * 100 / 160` — the same value as `total / 160 * 100`,
/// arranged so the whole-number cases are exact in double precision
/// (`0 -> 0.0`, `48 -> 30.0`, `80 -> 50.0`, `160 -> 100.0`).
double? tatPercentage(int tatTotalOutOf160) {
  if (tatTotalOutOf160 < 0 || tatTotalOutOf160 > _tatMaxScore) return null;
  return tatTotalOutOf160 * 100 / _tatMaxScore;
}

/// The TAT course-eligibility outcomes, per the Guidance Council rule.
/// There is exactly one threshold — do not add further categories, and do
/// not reuse `AdmissionCategory` / `QtmEligibility`.
enum TatEligibility {
  /// TAT total `>= 48` (`>= 30%`): meets the TAT requirement — may take all
  /// six TAT-required courses.
  meetsRequirement,

  /// TAT total `<= 47` (`< 30%`): does not meet the TAT requirement.
  doesNotMeetRequirement,
}

/// Classifies [tatTotalOutOf160] into its [TatEligibility] outcome, or
/// `null` when the total is outside the valid `0..160` range.
///
///  * `total >= 48`  (>= 30%)  → [TatEligibility.meetsRequirement]
///  * `total <= 47`  (< 30%)   → [TatEligibility.doesNotMeetRequirement]
TatEligibility? tatEligibility(int tatTotalOutOf160) {
  if (tatTotalOutOf160 < 0 || tatTotalOutOf160 > _tatMaxScore) return null;
  return tatTotalOutOf160 >= _tatMinScoreToMeet
      ? TatEligibility.meetsRequirement
      : TatEligibility.doesNotMeetRequirement;
}
