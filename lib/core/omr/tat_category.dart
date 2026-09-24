/// TAT category bands, per the Guidance Council's TAT category template,
/// applied to the official TAT total out of 160 (see `tat_result.dart`).
///
/// PRESENTATION-ONLY, like `admission_category.dart` / `qtm_category.dart`.
/// The template's percentage labels are converted to score bands on the
/// 160-point maximum: 90% = 144, 85% = 136, 80% = 128, 76% = 121.6.
enum TatCategory { a, b, c, d }

/// Maps a TAT total (out of 160) to its [TatCategory], or `null` for the
/// unclassified gap (122-127, between "76% and below" and 80%) and for totals
/// outside 0..160.
///
///  * `0`-`121`   -> [TatCategory.a]   (76% and below)
///  * `122`-`127` -> `null` (gap)
///  * `128`-`135` -> [TatCategory.b]   (80%-84%)
///  * `136`-`143` -> [TatCategory.c]   (85%-89%)
///  * `144`-`160` -> [TatCategory.d]   (90% and above)
TatCategory? tatCategory(int totalOutOf160) {
  if (totalOutOf160 < 0 || totalOutOf160 > 160) return null;
  if (totalOutOf160 <= 121) return TatCategory.a;
  if (totalOutOf160 <= 127) return null;
  if (totalOutOf160 <= 135) return TatCategory.b;
  if (totalOutOf160 <= 143) return TatCategory.c;
  return TatCategory.d;
}
