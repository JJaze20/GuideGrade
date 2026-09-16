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
