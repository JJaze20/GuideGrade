import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_alignment_check.dart';

/// Regression coverage for the rejection-reason -> user-facing-category
/// mapping the temporary opt-in live diagnostic overlay displays (see
/// ExamScanningScreen's `_diagnosticsEnabled` / `_DiagnosticOverlayPainter`).
/// The mapping itself is plain string logic with no opencv_dart dependency
/// (omr_alignment_check.dart is the platform-independent, no-native-deps
/// half of the OMR decoder -- shared verbatim by both the native and Web
/// builds), so this is worth locking down on its own regardless of the
/// heavier native detector logic around it.
void main() {
  group('categorizeRejectionReason', () {
    test('maps contrast straight through', () {
      expect(categorizeRejectionReason('contrast'), CornerRejectionCategory.contrast);
    });

    test('maps every shape-related raw reason to shape', () {
      for (final raw in ['area', 'aspect', 'fill_ratio', 'low_squareness']) {
        expect(
          categorizeRejectionReason(raw),
          CornerRejectionCategory.shape,
          reason: 'raw reason "$raw" should categorize as shape',
        );
      }
    });

    test('maps every geometry-related raw reason to position', () {
      for (final raw in ['inside_grid', 'geom_inconsistent', 'outscored']) {
        expect(
          categorizeRejectionReason(raw),
          CornerRejectionCategory.position,
          reason: 'raw reason "$raw" should categorize as position',
        );
      }
    });

    test('falls back to shape for an unrecognized raw reason rather than throwing', () {
      expect(categorizeRejectionReason('something_new'), CornerRejectionCategory.shape);
    });
  });
}
