import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

void main() {
  final capturedAt = DateTime.utc(2026, 9, 15, 19, 18);
  const decoded = OmrScanResult(examCode: 'AT', items: []);

  group('LocalScan — name-crop fields', () {
    test('toJson -> fromJson round-trips the three crop filenames', () {
      final original = LocalScan(
        id: 's_1',
        imageFileName: 'images/s_1.enc',
        capturedAt: capturedAt,
        decoded: decoded,
        nameCropLastFileName: 'images/s_1_name_last.enc',
        nameCropFirstFileName: 'images/s_1_name_first.enc',
        nameCropMiddleFileName: 'images/s_1_name_mi.enc',
      );

      final restored = LocalScan.fromJson(original.toJson());

      expect(restored.nameCropLastFileName, 'images/s_1_name_last.enc');
      expect(restored.nameCropFirstFileName, 'images/s_1_name_first.enc');
      expect(restored.nameCropMiddleFileName, 'images/s_1_name_mi.enc');
    });

    test('a scan with no crops round-trips them as null', () {
      final original = LocalScan(
        id: 's_2',
        imageFileName: 'images/s_2.enc',
        capturedAt: capturedAt,
        decoded: decoded,
      );

      final restored = LocalScan.fromJson(original.toJson());

      expect(restored.nameCropLastFileName, isNull);
      expect(restored.nameCropFirstFileName, isNull);
      expect(restored.nameCropMiddleFileName, isNull);
    });

    test('an older batch.json predating this feature (and still carrying '
        'the now-removed ocr*Guess keys) parses without error, with the '
        'crop fields simply absent', () {
      final legacyJson = {
        'id': 's_legacy',
        'imageFileName': 'images/s_legacy.enc',
        'rectifiedImageFileName': null,
        'capturedAt': capturedAt.toIso8601String(),
        'decoded': decoded.toJson(),
        'result': null,
        'examinee': {
          'firstName': 'Juan',
          'lastName': 'Dela Cruz',
          'middleName': '',
          'examineeNumber': 'X-1',
        },
        // Unknown keys from before this feature/the OCR removal — must be
        // silently ignored, not cause a parse failure.
        'ocrLastNameGuess': 'Dela Cruz',
        'ocrFirstNameGuess': 'Juan',
        'ocrMiddleNameGuess': null,
      };

      final restored = LocalScan.fromJson(legacyJson);

      expect(restored.id, 's_legacy');
      expect(restored.examinee!.displayName, 'Dela Cruz, Juan');
      expect(restored.nameCropLastFileName, isNull);
      expect(restored.nameCropFirstFileName, isNull);
      expect(restored.nameCropMiddleFileName, isNull);
    });

    test('copyWith preserves the crop filenames untouched', () {
      final original = LocalScan(
        id: 's_3',
        imageFileName: 'images/s_3.enc',
        capturedAt: capturedAt,
        decoded: decoded,
        nameCropLastFileName: 'images/s_3_name_last.enc',
      );

      final tagged = original.copyWith(
        examinee: const ExamineeInfo(firstName: 'A', lastName: 'B', examineeNumber: '1'),
      );

      expect(tagged.nameCropLastFileName, 'images/s_3_name_last.enc');
    });
  });

  group('ExamineeInfo — optional name, still keyed on examinee number', () {
    test('isEmpty is false when only the examinee number is set', () {
      const info = ExamineeInfo(firstName: '', lastName: '', examineeNumber: '12345');
      expect(info.isEmpty, isFalse);
      expect(info.isComplete, isFalse);
    });

    test('isComplete still requires first, last, and number all non-blank', () {
      const nameOnly = ExamineeInfo(firstName: 'Juan', lastName: 'Dela Cruz', examineeNumber: '');
      expect(nameOnly.isComplete, isFalse);

      const full = ExamineeInfo(firstName: 'Juan', lastName: 'Dela Cruz', examineeNumber: 'X-1');
      expect(full.isComplete, isTrue);
    });
  });
}
