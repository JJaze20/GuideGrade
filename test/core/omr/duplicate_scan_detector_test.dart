import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/duplicate_scan_detector.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

OmrScanResult _sheet(List<String?> choices, {String examCode = 'AT'}) {
  return OmrScanResult(
    examCode: examCode,
    items: [
      for (var i = 0; i < choices.length; i++)
        OmrItemResult(sectionName: 'Section 1', itemNumber: i + 1, markedChoice: choices[i]),
    ],
  );
}

void main() {
  group('looksLikeDuplicateScan', () {
    test('flags two sheets with identical marks', () {
      final a = _sheet(['A', 'B', 'C', 'D', 'A', 'B', 'C', 'D', 'A', 'B']);
      final b = _sheet(['A', 'B', 'C', 'D', 'A', 'B', 'C', 'D', 'A', 'B']);
      expect(looksLikeDuplicateScan(a, b), isTrue);
    });

    test('tolerates a couple of differing items (decode noise)', () {
      // Use a longer sheet so a couple of differences still clears
      // kDuplicateMatchThreshold (a short 10-item sheet would drop too far
      // below 95% from just 2 disagreements).
      final long = List<String?>.generate(40, (i) => ['A', 'B', 'C', 'D'][i % 4]);
      final aLong = _sheet(long);
      final bLong = _sheet([...long]..[3] = 'A'..[7] = null);
      expect(looksLikeDuplicateScan(aLong, bLong), isTrue);
    });

    test('does not flag two genuinely different sheets', () {
      final a = _sheet(['A', 'B', 'C', 'D', 'A', 'B', 'C', 'D', 'A', 'B']);
      final b = _sheet(['B', 'A', 'D', 'C', 'B', 'A', 'D', 'C', 'B', 'A']);
      expect(looksLikeDuplicateScan(a, b), isFalse);
    });

    test('never flags two mostly-blank sheets, even if their blanks agree', () {
      final a = _sheet([null, null, null, null, null, null, null, null, null, 'A']);
      final b = _sheet([null, null, null, null, null, null, null, null, null, 'A']);
      expect(looksLikeDuplicateScan(a, b), isFalse);
    });
  });

  group('findDuplicateScanPairs', () {
    test('finds the matching pair among several distinct sheets', () {
      final s1 = _sheet(['A', 'B', 'C', 'D', 'A', 'B', 'C', 'D', 'A', 'B']);
      final s2 = _sheet(['B', 'A', 'D', 'C', 'B', 'A', 'D', 'C', 'B', 'A']);
      final s3 = _sheet(['A', 'B', 'C', 'D', 'A', 'B', 'C', 'D', 'A', 'B']); // duplicate of s1
      final matches = findDuplicateScanPairs([s1, s2, s3]);
      expect(matches, hasLength(1));
      expect(matches.single.indexA, 0);
      expect(matches.single.indexB, 2);
    });

    test('returns nothing when no pair matches', () {
      final s1 = _sheet(['A', 'B', 'C', 'D']);
      final s2 = _sheet(['B', 'A', 'D', 'C']);
      expect(findDuplicateScanPairs([s1, s2]), isEmpty);
    });
  });
}
