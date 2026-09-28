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
        ' fills only the BLANK fields and PRESERVES the id -- a typed name is never overwritten', () {
      final result = resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(firstName: '', lastName: 'Cruz', examineeNumber: 'EX-OLD'),
        ocrLastNameGuess: 'Dela Cruz',
        ocrFirstNameGuess: 'Juan',
        generateId: () => 'EX-SHOULD-NOT-BE-USED',
      );
      expect(result, isNotNull);
      expect(result!.examineeNumber, 'EX-OLD');
      expect(result.lastName, 'Cruz', reason: 'already typed by a person: kept');
      expect(result.firstName, 'Juan', reason: 'was blank: filled from OCR');
    });

    test('an unnamed sheet (id, no names) gets every name OCR read, with its id unchanged', () {
      final result = resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(firstName: '', lastName: '', examineeNumber: 'EX-OLD'),
        ocrLastNameGuess: 'Dela Cruz',
        ocrFirstNameGuess: 'Juan',
        ocrMiddleNameGuess: 'M',
        generateId: () => 'EX-SHOULD-NOT-BE-USED',
      );
      expect(result!.examineeNumber, 'EX-OLD');
      expect(result.lastName, 'Dela Cruz');
      expect(result.firstName, 'Juan');
      expect(result.middleName, 'M');
    });

    test('a field OCR could not read is never blanked, and other details are carried over', () {
      final result = resolveRescanExaminee(
        existingExaminee: ExamineeInfo(
          firstName: 'Ana',
          lastName: '',
          examineeNumber: 'EX-OLD',
          birthDate: DateTime(2010, 3, 4),
          manualAge: 15,
          lastSchool: 'NDMU High',
        ),
        ocrLastNameGuess: 'Reyes', // OCR read the last name only
        generateId: () => 'EX-SHOULD-NOT-BE-USED',
      );
      expect(result!.firstName, 'Ana', reason: 'not blanked just because OCR read nothing for it');
      expect(result.lastName, 'Reyes');
      expect(result.birthDate, DateTime(2010, 3, 4));
      expect(result.manualAge, 15);
      expect(result.lastSchool, 'NDMU High');
    });

    test('OCR that would add nothing new returns null (tag left exactly as it is)', () {
      final result = resolveRescanExaminee(
        existingExaminee: const ExamineeInfo(firstName: 'Ana', lastName: '', examineeNumber: 'EX-OLD'),
        ocrFirstNameGuess: 'Someone', // first is already typed; last unread
        generateId: () => 'EX-SHOULD-NOT-BE-USED',
      );
      expect(result, isNull);
    });

    test('a legacy sheet with no id keeps its details (not rebuilt from scratch) while gaining an id', () {
      final result = resolveRescanExaminee(
        existingExaminee: ExamineeInfo(
          firstName: 'Ana',
          lastName: 'Cruz',
          examineeNumber: '',
          birthDate: DateTime(2010, 3, 4),
          lastSchool: 'NDMU High',
        ),
        ocrLastNameGuess: 'Other',
        generateId: () => 'EX-NEW',
      );
      expect(result!.examineeNumber, 'EX-NEW');
      expect(result.lastName, 'Cruz');
      expect(result.birthDate, DateTime(2010, 3, 4));
      expect(result.lastSchool, 'NDMU High');
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

  group('rescanWillFillNamesFromOcr (what the comparison panel announces)', () {
    test('true only when confirming would actually write OCR names into blank fields', () {
      expect(
        rescanWillFillNamesFromOcr(
          existing: const ExamineeInfo(firstName: '', lastName: '', examineeNumber: 'EX-1'),
          ocrLastName: 'Reyes',
        ),
        isTrue,
      );
    });

    test('false for a sheet that already has a full name, or when OCR read nothing', () {
      expect(
        rescanWillFillNamesFromOcr(
          existing: const ExamineeInfo(firstName: 'Ana', lastName: 'Cruz', examineeNumber: 'EX-1'),
          ocrLastName: 'Other',
          ocrFirstName: 'Names',
        ),
        isFalse,
      );
      expect(
        rescanWillFillNamesFromOcr(
          existing: const ExamineeInfo(firstName: '', lastName: '', examineeNumber: 'EX-1'),
        ),
        isFalse,
      );
    });

    test('agrees with what resolveRescanExaminee returns for the same inputs', () {
      const existing = ExamineeInfo(firstName: 'Ana', lastName: '', examineeNumber: 'EX-1');
      final resolved = resolveRescanExaminee(
        existingExaminee: existing,
        ocrLastNameGuess: 'Reyes',
        generateId: () => 'x',
      );
      expect(resolved!.lastName, 'Reyes');
      expect(rescanWillFillNamesFromOcr(existing: existing, ocrLastName: 'Reyes'), isTrue);
    });
  });
}
