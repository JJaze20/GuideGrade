/// Content-based "is this the same physical sheet scanned twice" check.
///
/// Compares two already-decoded [OmrScanResult]s item-by-item and flags a
/// likely duplicate when their marks agree almost everywhere. This needs no
/// image comparison and no new data — every decoded sheet already carries
/// [OmrItemResult.markedChoice] per item. Two independent photos of the same
/// physical sheet read as marked almost identically; two different
/// students' sheets essentially never do, even on a short exam.
///
/// Deliberately pure Dart (no OpenCV), same layer as `omr_scorer.dart`.
library;

import '../../models/omr_scan_result.dart';

/// Minimum fraction of items that must be actually marked (non-blank) on
/// *both* sides before two results are even compared. Guards against two
/// mostly-blank sheets (e.g. two students who left most of the sheet blank)
/// reading as a false "duplicate" purely because their blanks agree.
const double kDuplicateMinMarkedFraction = 0.3;

/// How much of two sheets' answers must agree, item-for-item, before
/// they're flagged as likely the same physical sheet scanned twice. Kept
/// below 1.0 deliberately — two independent captures of the same sheet can
/// still land on different reads for a handful of ambiguous/borderline
/// items, so this tolerates ordinary decode noise rather than only catching
/// byte-identical decodes.
const double kDuplicateMatchThreshold = 0.95;

/// Fraction of [result]'s items that have a non-null [OmrItemResult.markedChoice].
double markedFraction(OmrScanResult result) {
  if (result.items.isEmpty) return 0;
  final marked = result.items.where((i) => i.markedChoice != null).length;
  return marked / result.items.length;
}

String _itemKey(OmrItemResult item) => '${item.sectionName}|${item.itemNumber}';

/// Fraction of items present in both [a] and [b] (matched by section name +
/// item number) whose [OmrItemResult.markedChoice] agree exactly, including
/// agreeing on blank. Returns 0 when there's no overlapping item to compare.
double itemMatchFraction(OmrScanResult a, OmrScanResult b) {
  final bByKey = {for (final item in b.items) _itemKey(item): item.markedChoice};
  var compared = 0;
  var matched = 0;
  for (final item in a.items) {
    final key = _itemKey(item);
    if (!bByKey.containsKey(key)) continue;
    compared++;
    if (item.markedChoice == bByKey[key]) matched++;
  }
  if (compared == 0) return 0;
  return matched / compared;
}

/// Whether [a] and [b] look like the same physical sheet scanned twice:
/// both meaningfully marked ([kDuplicateMinMarkedFraction]) and agreeing on
/// at least [kDuplicateMatchThreshold] of their shared items.
bool looksLikeDuplicateScan(OmrScanResult a, OmrScanResult b) {
  if (markedFraction(a) < kDuplicateMinMarkedFraction) return false;
  if (markedFraction(b) < kDuplicateMinMarkedFraction) return false;
  return itemMatchFraction(a, b) >= kDuplicateMatchThreshold;
}

/// One matched pair, referencing positions in whatever list was passed to
/// [findDuplicateScanPairs].
class DuplicateScanMatch {
  final int indexA;
  final int indexB;
  final double matchFraction;

  const DuplicateScanMatch({
    required this.indexA,
    required this.indexB,
    required this.matchFraction,
  });
}

/// All pairs within [results] that look like the same physical sheet
/// scanned twice (see [looksLikeDuplicateScan]). O(n^2) over the list —
/// fine at the scale a single scan session or a single batch reaches
/// (tens to low hundreds of sheets).
List<DuplicateScanMatch> findDuplicateScanPairs(List<OmrScanResult> results) {
  final matches = <DuplicateScanMatch>[];
  for (var i = 0; i < results.length; i++) {
    if (markedFraction(results[i]) < kDuplicateMinMarkedFraction) continue;
    for (var j = i + 1; j < results.length; j++) {
      if (markedFraction(results[j]) < kDuplicateMinMarkedFraction) continue;
      final fraction = itemMatchFraction(results[i], results[j]);
      if (fraction >= kDuplicateMatchThreshold) {
        matches.add(DuplicateScanMatch(indexA: i, indexB: j, matchFraction: fraction));
      }
    }
  }
  return matches;
}
