import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/models/local_batch.dart';

/// Covers the automatic-Examinee-ID feature's pure, testable logic:
/// [generateExamineeId], [buildAutoExaminee] (new-scan path, used by
/// AppState.persistCapturedSessionToBatch), and [resolveRescanExaminee]
/// (retake path, used by AppState.finishRescan). Mirrors the existing
/// project pattern in scan_result_persistence_test.dart of testing the
/// shared pure helper rather than the full AppState method (which needs
/// Firebase auth, real captured files, and background OCR isolates).
void main() {
  group('generateExamineeId', () {
    test('never returns a blank string', () {
      expect(generateExamineeId().trim(), isNotEmpty);
    });

    test('two consecutive calls are always different, even at the same instant', () {
      final now = DateTime(2026, 1, 1);
      final a = generateExamineeId(now);
      final b = generateExamineeId(now);
      expect(a, isNot(equals(b)));
    });

    test('is never a fake placeholder like "UNKNOWN"', () {
      expect(generateExamineeId().toUpperCase(), isNot(contains('UNKNOWN')));
    });
  });

  group('buildAutoExaminee (new-scan path)', () {
    test('full OCR success: all three names saved, plus a generated id', () {
      final examinee = buildAutoExaminee(
        ocrLastNameGuess: 'Dela Cruz',
        ocrFirstNameGuess: 'Juan',
        ocrMiddleNameGuess: 'Santos',
        generateId: () => 'EX-1',
      );
      expect(examinee.lastName, 'Dela Cruz');
      expect(examinee.firstName, 'Juan');
      expect(examinee.middleName, 'Santos');
      expect(examinee.examineeNumber, 'EX-1');
    });

    test('partial OCR (last name only): last name saved, others blank -- never'
        ' a placeholder -- id still generated', () {
      final examinee = buildAutoExaminee(
        ocrLastNameGuess: 'Dela Cruz',
        generateId: () => 'EX-2',
      );
      expect(examinee.lastName, 'Dela Cruz');
      expect(examinee.firstName, '');
      expect(examinee.middleName, '');
      expect(examinee.examineeNumber, 'EX-2');
    });

    test('OCR reads nothing at all: names all blank, id is still generated'
        ' -- the scan must still save', () {
      final examinee = buildAutoExaminee(generateId: () => 'EX-3');
      expect(examinee.lastName, '');
      expect(examinee.firstName, '');
      expect(examinee.middleName, '');
      expect(examinee.examineeNumber, 'EX-3');
    });

    test('always calls generateId exactly once per scan', () {
      var calls = 0;
      buildAutoExaminee(generateId: () {
        calls++;
        return 'EX-4';
      });
      expect(calls, 1);
    });
  });

  group('resolveRescanExaminee (rescan path)', () {
    test('legacy scan with no existing examinee at all: generates a fresh id,'
        ' fills names from this pass\'s OCR', () {
      final result = resolveRescanExaminee(
        existingExaminee: null,
        ocrLastNameGuess: 'Dela Cruz',
        ocrFirstNameGuess: 'Juan',
        generateId: () => 'EX-NEW',
      );
      expect(result, isNotNull);
      expect(result!.examineeNumber, 'EX-NEW');
      expect(result.lastName, 'Dela Cruz');
      expect(result.firstName, 'Juan');
    });

    test('existing record has no generated id yet (blank examineeNumber): a'
        ' fresh id is generated even though the record itself is not null', () {
      final result = resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(firstName: '', lastName: 'Dela Cruz', examineeNumber: ''),
        generateId: () => 'EX-BACKFILL',
      );
      expect(result, isNotNull);
      expect(result!.examineeNumber, 'EX-BACKFILL');
      // No fresh OCR this pass -> falls back to the existing name.
      expect(result.lastName, 'Dela Cruz');
    });

    test('existing generated id, tag not yet complete, fresh OCR available:'
        ' refreshes the name but PRESERVES the existing id -- never a new one', () {
      final result = resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(firstName: '', lastName: 'Cruz', examineeNumber: 'EX-OLD'),
        ocrLastNameGuess: 'Dela Cruz',
        ocrFirstNameGuess: 'Juan',
        generateId: () => 'EX-SHOULD-NOT-BE-USED',
      );
      expect(result, isNotNull);
      expect(result!.examineeNumber, 'EX-OLD');
      expect(result.lastName, 'Dela Cruz');
      expect(result.firstName, 'Juan');
    });

    test('existing generated id, tag not yet complete, but NO fresh OCR this'
        ' pass: keeps the existing tag as-is (returns null, per replaceScan'
        ' contract)', () {
      final result = resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(firstName: '', lastName: 'Cruz', examineeNumber: 'EX-OLD'),
        generateId: () => 'EX-SHOULD-NOT-BE-USED',
      );
      expect(result, isNull);
    });

    test('existing FULLY complete tag: never touched, even with fresh OCR --'
        ' returns null (mismatch guard in finishRescan handles disagreement'
        ' separately)', () {
      final result = resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(
          firstName: 'Juan',
          lastName: 'Dela Cruz',
          examineeNumber: 'EX-CONFIRMED',
        ),
        ocrLastNameGuess: 'Someone Else',
        generateId: () => 'EX-SHOULD-NOT-BE-USED',
      );
      expect(result, isNull);
    });

    test('a rescan of an already-id\'d record never mints a second id merely'
        ' because a rescan happened', () {
      var generateCalls = 0;
      resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(firstName: '', lastName: 'Cruz', examineeNumber: 'EX-OLD'),
        ocrLastNameGuess: 'Dela Cruz',
        generateId: () {
          generateCalls++;
          return 'EX-NEW';
        },
      );
      expect(generateCalls, 0);
    });
  });
}
