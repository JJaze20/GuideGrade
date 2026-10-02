import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/local_batch.dart';

void main() {
  final scannedAt = DateTime.utc(2026, 8, 31, 9, 15);

  group('LocalScanResult — TAT breakdown round-trip', () {
    test('toJson -> fromJson preserves every TAT field', () {
      final original = LocalScanResult(
        rawScore: 60, // TAT headline = tatTotal
        totalGraded: 130,
        totalItems: 130,
        percentage: 0,
        status: 'Graded',
        scannedAt: scannedAt,
        processedByUid: 'uid-1',
        processedByName: 'Officer J',
        tatTest1Correct: 25,
        tatTest1Wrong: 0,
        tatTest1Score: 50,
        tatTest2Correct: 10,
        tatTest2Wrong: 10,
        tatTest2Score: 0,
        tatTest3Correct: 15,
        tatTest3Wrong: 5,
        tatTest3Score: 10,
        tatTotal: 60,
      );

      final restored = LocalScanResult.fromJson(original.toJson());

      expect(restored.rawScore, 60);
      expect(restored.totalItems, 130);
      expect(restored.status, 'Graded');
      expect(restored.tatTest1Correct, 25);
      expect(restored.tatTest1Wrong, 0);
      expect(restored.tatTest1Score, 50);
      expect(restored.tatTest2Correct, 10);
      expect(restored.tatTest2Wrong, 10);
      expect(restored.tatTest2Score, 0);
      expect(restored.tatTest3Correct, 15);
      expect(restored.tatTest3Wrong, 5);
      expect(restored.tatTest3Score, 10);
      expect(restored.tatTotal, 60);
      expect(restored.hasTatBreakdown, isTrue);
    });

    test('a non-TAT result serializes without any tat* keys', () {
      final at = LocalScanResult(
        rawScore: 60,
        totalGraded: 72,
        totalItems: 72,
        percentage: 83.33,
        status: 'Graded',
        scannedAt: scannedAt,
        processedByUid: 'uid-1',
        processedByName: 'Officer J',
      );

      final json = at.toJson();

      expect(json.keys.where((k) => k.startsWith('tat')), isEmpty);
      expect(at.hasTatBreakdown, isFalse);

      final restored = LocalScanResult.fromJson(json);
      expect(restored.rawScore, 60);
      expect(restored.percentage, 83.33);
      expect(restored.tatTotal, isNull);
      expect(restored.hasTatBreakdown, isFalse);
    });
  });

  group('LocalScanResult — backward compatibility with old batch.json', () {
    test('an old record with none of the TAT fields still loads', () {
      // Exactly the shape written before the breakdown existed.
      final oldJson = <String, dynamic>{
        'rawScore': 45,
        'totalGraded': 60,
        'totalItems': 60,
        'percentage': 75.0,
        'status': 'Graded',
        'scannedAt': scannedAt.toIso8601String(),
        'processedByUid': 'uid-legacy',
        'processedByName': 'Legacy User',
      };

      final result = LocalScanResult.fromJson(oldJson);

      expect(result.rawScore, 45);
      expect(result.totalItems, 60);
      expect(result.percentage, 75.0);
      expect(result.status, 'Graded');
      expect(result.isGraded, isTrue);
      expect(result.tatTest1Correct, isNull);
      expect(result.tatTest1Score, isNull);
      expect(result.tatTest2Score, isNull);
      expect(result.tatTest3Score, isNull);
      expect(result.tatTotal, isNull);
      expect(result.hasTatBreakdown, isFalse);
    });

    test('an old record missing scalar fields still falls back safely', () {
      final result = LocalScanResult.fromJson(<String, dynamic>{
        'scannedAt': scannedAt.toIso8601String(),
      });

      expect(result.rawScore, 0);
      expect(result.totalGraded, 0);
      expect(result.totalItems, 0);
      expect(result.percentage, 0);
      expect(result.status, 'Ungraded');
      expect(result.processedByName, 'Unknown');
      expect(result.tatTotal, isNull);
    });
  });
}
