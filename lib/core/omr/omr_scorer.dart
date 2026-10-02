import '../../models/answer_key.dart';
import '../../models/omr_scan_result.dart';

/// A decoded item combined with the answer key's correct choice for it, if
/// any answer key covers this exam.
class ScoredItem {
  final String sectionName;
  final int itemNumber;
  final String? markedChoice;
  final bool isAmbiguous;
  final String? correctChoice;

  const ScoredItem({
    required this.sectionName,
    required this.itemNumber,
    required this.markedChoice,
    required this.isAmbiguous,
    required this.correctChoice,
  });

  bool get isBlank => markedChoice == null && !isAmbiguous;

  /// Null when this item isn't covered by the answer key (ungraded).
  bool? get isCorrect => correctChoice == null ? null : (!isAmbiguous && markedChoice == correctChoice);
}

class ScoredResult {
  final String examCode;
  final List<ScoredItem> items;

  /// Carried straight through from the decoded [OmrScanResult] so a
  /// viewer (ScannedImageViewerScreen's graded overlay) can reconstruct
  /// the exact mesh correction used to decode [items] — see
  /// [OmrScanResult.templateVersion]/[OmrScanResult.meshInteriorMeasuredFrac].
  final String? templateVersion;
  final Map<String, (double, double)>? meshInteriorMeasuredFrac;

  /// Carried through from [OmrScanResult.meshVerdict] so a viewer can warn
  /// that this sheet's geometry was never trustworthy — see
  /// [OmrScanResult.geometryWarning].
  final String? meshVerdict;

  /// Carried through from [OmrScanResult.meshRescued]: this capture was
  /// accepted only because the interior-mark mesh recovered a sheet whose
  /// planar warp check failed. See that field's doc comment.
  final bool meshRescued;

  const ScoredResult({
    required this.examCode,
    required this.items,
    this.templateVersion,
    this.meshInteriorMeasuredFrac,
    this.meshVerdict,
    this.meshRescued = false,
  });

  /// The retake hint for this scan's geometry, or null when it is sound.
  String? get geometryWarning => geometryWarningFor(meshVerdict);

  int get rawScore => items.where((i) => i.isCorrect == true).length;

  int get totalGraded => items.where((i) => i.correctChoice != null).length;

  double get percentage => totalGraded == 0 ? 0 : rawScore / totalGraded * 100;
}

/// Combines a decoded [result] with [answerKey] (if any exists for its
/// exam code) into per-item correctness plus a raw score. With no answer
/// key, every item's [ScoredItem.correctChoice] is null — ungraded, not
/// wrong.
ScoredResult scoreOmrResult(OmrScanResult result, AnswerKey? answerKey) {
  final items = result.items
      .map(
        (item) => ScoredItem(
          sectionName: item.sectionName,
          itemNumber: item.itemNumber,
          markedChoice: item.markedChoice,
          isAmbiguous: item.isAmbiguous,
          correctChoice: answerKey?.choiceFor(item.sectionName, item.itemNumber),
        ),
      )
      .toList();
  return ScoredResult(
    examCode: result.examCode,
    items: items,
    templateVersion: result.templateVersion,
    meshInteriorMeasuredFrac: result.meshInteriorMeasuredFrac,
    meshVerdict: result.meshVerdict,
    meshRescued: result.meshRescued,
  );
}
