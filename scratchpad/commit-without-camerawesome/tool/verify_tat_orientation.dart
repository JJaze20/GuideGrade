import '../lib/core/omr/tat_marker_validation.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

void main() {
  // Upright, either vertical reading direction, and upside-down captures.
  for (var turn = 0; turn < 4; turn++) {
    final scores = List<double>.filled(4, 0);
    scores[turn] = 5.8;
    check(selectTatOrientation(scores) == turn, 'quarter turn $turn');
  }
  check(selectTatOrientation([0, 0, 0, 0]) == null, 'missing marks');
  check(selectTatOrientation([3, 0, 0, 0]) == null, 'insufficient evidence');
  check(selectTatOrientation([5, 4.5, 0, 0]) == null, 'ambiguous direction');
  check(selectTatOrientation([0, 4.2, 1, 0]) == 1, 'partial but decisive');
  check(selectTatOrientation([1, 0, 5.5, 2]) == 2, 'false candidates');
  print('TAT orientation selection checks passed. Native image detection and device capture still require testing.');
}
