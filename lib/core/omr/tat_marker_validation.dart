/// Size/shape checks for a TAT mark after the provisional page warp.
/// Contours are dilated by one pixel on each side before these checks.
bool tatMarkerShapeMatches({
  required double expectedSidePx,
  required double shortSide,
  required double longSide,
  required double extent,
}) => expectedSidePx > 0 && shortSide >= expectedSidePx * 0.7 &&
    longSide <= expectedSidePx * 1.3 + 2 &&
    longSide / shortSide <= 1.25 && extent >= 0.82;

bool tatMarkerMatchIsAmbiguous(double best, double runnerUp) =>
    runnerUp >= 0 && runnerUp >= best - 0.08;

/// Select only an orientation supported by several asymmetric section marks.
/// Side marks alone are symmetric and cannot determine reading direction.
int? selectTatOrientation(List<double> scores) {
  if (scores.isEmpty) return null;
  final ranked = List<int>.generate(scores.length, (i) => i)
    ..sort((a, b) => scores[b].compareTo(scores[a]));
  final best = ranked.first;
  if (scores[best] < 4) return null;
  if (ranked.length > 1 && scores[best] - scores[ranked[1]] < 1.5) {
    return null;
  }
  return best;
}
/// Which way up a portrait TAT v5 sheet is, from how many of its seven small
/// marks (all asymmetric: none lands on another when the sheet is turned 180
/// degrees) were found at their printed positions when the page was warped
/// as shot versus turned 180 degrees. Returns 0 for as shot, 1 for turned,
/// or null when neither reading is trustworthy (too few marks matched, or the
/// two readings are too close to call).
int? selectTatPortraitDirection({
  required int asShotCount,
  required double asShotScore,
  required int turnedCount,
  required double turnedScore,
}) {
  const minMarks = 3;
  final asShotValid = asShotCount >= minMarks && asShotScore.isFinite;
  final turnedValid = turnedCount >= minMarks && turnedScore.isFinite;
  if (!asShotValid && !turnedValid) return null;
  if (asShotValid && !turnedValid) return 0;
  if (turnedValid && !asShotValid) return 1;
  if ((asShotScore - turnedScore).abs() < 1.5) return null;
  return asShotScore > turnedScore ? 0 : 1;
}
