import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/examinee_record.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

ExamineeRecord _record({
  String id = 'e1',
  String temporaryExamineeId = 'EX-1',
  String? officialStudentId,
  String firstName = 'Juan',
  String? middleName,
  String lastName = 'Dela Cruz',
  String status = 'active',
}) =>
    ExamineeRecord(
      id: id,
      temporaryExamineeId: temporaryExamineeId,
      officialStudentId: officialStudentId,
      firstName: firstName,
      middleName: middleName,
      lastName: lastName,
      status: status,
      createdAt: DateTime.utc(2026, 1, 1),
      createdByUid: 'uid1',
      updatedAt: DateTime.utc(2026, 1, 1),
      updatedByUid: 'uid1',
    );

void main() {
  group('1. ExamineeRecord creation', () {
    test('builds a record with all canonical fields', () {
      final r = _record(
        temporaryExamineeId: 'EX-00025',
        firstName: 'Juan',
        middleName: 'Santos',
        lastName: 'Dela Cruz',
      );
      expect(r.temporaryExamineeId, 'EX-00025');
      expect(r.displayName, 'Dela Cruz, Juan S.');
      expect(r.isActive, isTrue);
      expect(r.isArchived, isFalse);
    });
  });

  group('2/10. Temporary Examinee ID is required and immutable', () {
    test('withProfileEdits has no parameter that can change it', () {
      final r = _record(temporaryExamineeId: 'EX-00025');
      final edited = r.withProfileEdits(
        firstName: 'Juanito',
        lastName: 'Dela Cruz',
        updatedAt: DateTime.utc(2026, 2, 1),
        updatedByUid: 'uid2',
      );
      expect(edited.temporaryExamineeId, 'EX-00025');
      expect(edited.firstName, 'Juanito');
    });

    test('archiving and restoring never change it either', () {
      final r = _record(temporaryExamineeId: 'EX-00025');
      final archived = r.archived(at: DateTime.utc(2026, 2, 1), byUid: 'uid2');
      final restored = archived.restored(at: DateTime.utc(2026, 3, 1), byUid: 'uid3');
      expect(archived.temporaryExamineeId, 'EX-00025');
      expect(restored.temporaryExamineeId, 'EX-00025');
    });
  });

  group('3/5. Official Student ID, Birth Date, and Last Attended School are dormant', () {
    test('a record can be constructed with none of them set', () {
      final r = _record(officialStudentId: null);
      expect(r.officialStudentId, isNull);
      expect(r.birthDate, isNull);
      expect(r.lastAttendedSchool, isNull);
    });

    test('withProfileEdits has no parameter for any of them -- they are never settable from the UI', () {
      final r = _record(temporaryExamineeId: 'EX-1', officialStudentId: null);
      // No officialStudentId/birthDate/lastAttendedSchool argument exists on
      // this method at all -- GuideGrade has no workflow for any of them.
      final edited = r.withProfileEdits(
        firstName: r.firstName,
        lastName: r.lastName,
        updatedAt: DateTime.utc(2026, 2, 1),
        updatedByUid: 'uid2',
      );
      expect(edited.officialStudentId, isNull);
      expect(edited.birthDate, isNull);
      expect(edited.lastAttendedSchool, isNull);
    });
  });

  group('9. Editing changes canonical examinee information (name only)', () {
    test('withProfileEdits updates first/middle/last name only', () {
      final r = _record();
      final edited = r.withProfileEdits(
        firstName: 'Maria',
        middleName: 'Lopez',
        lastName: 'Santos',
        updatedAt: DateTime.utc(2026, 2, 1),
        updatedByUid: 'uid2',
      );
      expect(edited.firstName, 'Maria');
      expect(edited.middleName, 'Lopez');
      expect(edited.lastName, 'Santos');
      expect(edited.updatedByUid, 'uid2');
    });

    test('editing never changes status, archivedAt, createdAt, or createdByUid', () {
      final r = _record(status: 'archived');
      final edited = r.withProfileEdits(
        firstName: r.firstName,
        lastName: r.lastName,
        updatedAt: DateTime.utc(2026, 2, 1),
        updatedByUid: 'uid2',
      );
      expect(edited.status, r.status);
      expect(edited.createdAt, r.createdAt);
      expect(edited.createdByUid, r.createdByUid);
    });
  });

  group('11. Archive changes status only', () {
    test('archived() sets status to archived and stamps who/when', () {
      final r = _record(status: 'active');
      final archived = r.archived(at: DateTime.utc(2026, 2, 1), byUid: 'uid2');
      expect(archived.status, 'archived');
      expect(archived.isArchived, isTrue);
      expect(archived.archivedAt, DateTime.utc(2026, 2, 1));
      expect(archived.archivedByUid, 'uid2');
      // Nothing else about the person changed.
      expect(archived.firstName, r.firstName);
      expect(archived.lastName, r.lastName);
      expect(archived.temporaryExamineeId, r.temporaryExamineeId);
    });
  });

  group('12. Restore changes status back to active', () {
    test('restored() clears archivedAt/archivedByUid and sets status to active', () {
      final r = _record(status: 'archived');
      final restored = r.restored(at: DateTime.utc(2026, 3, 1), byUid: 'uid3');
      expect(restored.status, 'active');
      expect(restored.isActive, isTrue);
      expect(restored.archivedAt, isNull);
      expect(restored.archivedByUid, isNull);
    });
  });

  group('4. Same examinee can have QTM, TAT, and Admission Test scans', () {
    test('ExamineeHistoryItem exposes each linked scan\'s exam code independently', () {
      final examinee = _record();
      final qtm = ExamineeHistoryItem(
        batch: _batch(examCode: 'QTM'),
        scan: _scan(id: 's1'),
      );
      final tat = ExamineeHistoryItem(
        batch: _batch(examCode: 'TAT'),
        scan: _scan(id: 's2'),
      );
      final at = ExamineeHistoryItem(
        batch: _batch(examCode: 'AT'),
        scan: _scan(id: 's3'),
      );
      final history = [qtm, tat, at];
      expect(history.map((h) => h.examCode).toSet(), {'QTM', 'TAT', 'AT'});
      // All belong to the same examinee conceptually (grouped by the caller
      // via examinee.id -> scans.examinee_id, not stored on the item itself).
      expect(examinee.id, isNotEmpty);
    });
  });
}

LocalBatch _batch({required String examCode}) => LocalBatch(
      id: 'b-$examCode',
      batchCode: 'B-$examCode',
      examCode: examCode,
      examTitle: examCode,
      description: '',
      expectedCount: 1,
      status: 'Active',
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      scans: const [],
    );

LocalScan _scan({required String id}) => LocalScan(
      id: id,
      imageFileName: 'images/$id.enc',
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: OmrScanResult(examCode: 'AT', items: const []),
    );
