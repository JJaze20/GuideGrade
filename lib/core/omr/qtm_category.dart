/// QTM category bands, per the Guidance Council's QTM category template.
///
/// PRESENTATION-ONLY, like `admission_category.dart`: maps an already-computed
/// QTM raw score (0..60) to a display letter. No Flutter / network / storage
/// dependency.
enum QtmCategory { a, b, c, d }

/// Maps a QTM raw score (out of 60) to its [QtmCategory], or `null` for the
/// unclassified gap (46–47, which the template leaves out) and for scores
/// outside 0..60.
///
///  * `0`–`45`  → [QtmCategory.a]   (template: "76% and below")
///  * `46`–`47` → `null` (gap)
///  * `48`–`50` → [QtmCategory.b]   (80%–84%)
///  * `51`–`53` → [QtmCategory.c]   (85%–89%)
///  * `54`–`60` → [QtmCategory.d]   (90% and above)
QtmCategory? qtmCategory(int rawScoreOutOf60) {
  if (rawScoreOutOf60 < 0 || rawScoreOutOf60 > 60) return null;
  if (rawScoreOutOf60 <= 45) return QtmCategory.a;
  if (rawScoreOutOf60 <= 47) return null;
  if (rawScoreOutOf60 <= 50) return QtmCategory.b;
  if (rawScoreOutOf60 <= 53) return QtmCategory.c;
  return QtmCategory.d;
}
