import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/supabase_sync_client.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/models/local_batch.dart';

/// Pure unit tests for the parts of [SupabaseSyncClient] that do not touch a
/// Supabase client, a network, or a platform channel: timestamp
/// serialization, Storage key construction, error classification, and the
/// answer-key row shape.
void main() {
  group('isoUtc', () {
    test('serializes a UTC instant with a trailing Z', () {
      final value = DateTime.utc(2026, 8, 31, 4, 5, 6);
      expect(SupabaseSyncClient.isoUtc(value), '2026-08-31T04:05:06.000Z');
    });

    test('converts a local DateTime to UTC (still ends with Z)', () {
      final local = DateTime(2026, 1, 2, 3, 4, 5);
      final serialized = SupabaseSyncClient.isoUtc(local);
      expect(serialized.endsWith('Z'), isTrue);
      expect(serialized, local.toUtc().toIso8601String());
    });
  });

  group('storage key construction', () {
    test('original / rectified / prefix are the agreed conventions', () {
      expect(
        SupabaseSyncClient.originalImageKey('b_1', 's_2'),
        'batches/b_1/scans/s_2/original.jpg',
      );
      expect(
        SupabaseSyncClient.rectifiedImageKey('b_1', 's_2'),
        'batches/b_1/scans/s_2/rectified.jpg',
      );
      expect(
        SupabaseSyncClient.batchStoragePrefix('b_1'),
        'batches/b_1/',
      );
    });
  });

  group('classifyPostgrestCode', () {
    test('RLS / data / constraint errors are permanent with their code', () {
      expect(SupabaseSyncClient.classifyPostgrestCode('42501'),
          const SyncOutcome.permanent('42501'));
      expect(SupabaseSyncClient.classifyPostgrestCode('22P02'),
          const SyncOutcome.permanent('22P02'));
      expect(SupabaseSyncClient.classifyPostgrestCode('23502'),
          const SyncOutcome.permanent('23502'));
      expect(SupabaseSyncClient.classifyPostgrestCode('23505'),
          const SyncOutcome.permanent('23505'));
      expect(SupabaseSyncClient.classifyPostgrestCode('23514'),
          const SyncOutcome.permanent('23514'));
      expect(SupabaseSyncClient.classifyPostgrestCode('400'),
          const SyncOutcome.permanent('400'));
      expect(SupabaseSyncClient.classifyPostgrestCode('422'),
          const SyncOutcome.permanent('422'));
    });

    test('rate limit and 5xx are transient', () {
      expect(SupabaseSyncClient.classifyPostgrestCode('429'),
          const SyncOutcome.transient('429'));
      expect(SupabaseSyncClient.classifyPostgrestCode('500'),
          const SyncOutcome.transient('5xx'));
      expect(SupabaseSyncClient.classifyPostgrestCode('503'),
          const SyncOutcome.transient('5xx'));
    });

    test('persistent auth failure (after refresh + retry) is permanent', () {
      expect(SupabaseSyncClient.classifyPostgrestCode('401'),
          const SyncOutcome.permanent('PGRST301'));
      expect(SupabaseSyncClient.classifyPostgrestCode('PGRST301'),
          const SyncOutcome.permanent('PGRST301'));
    });

    test('null / unrecognized PostgREST code is transient(unknown)', () {
      expect(SupabaseSyncClient.classifyPostgrestCode(null),
          const SyncOutcome.transient('unknown'));
      expect(SupabaseSyncClient.classifyPostgrestCode(''),
          const SyncOutcome.transient('unknown'));
      expect(SupabaseSyncClient.classifyPostgrestCode('weird value!!'),
          const SyncOutcome.transient('unknown'));
    });
  });

  group('classifyStorageStatus', () {
    test('403 / 400 / 413 are permanent', () {
      expect(SupabaseSyncClient.classifyStorageStatus('403', StorageOp.write),
          const SyncOutcome.permanent('storage_403'));
      expect(SupabaseSyncClient.classifyStorageStatus('400', StorageOp.write),
          const SyncOutcome.permanent('storage_400'));
      expect(SupabaseSyncClient.classifyStorageStatus('413', StorageOp.write),
          const SyncOutcome.permanent('storage_413'));
    });

    test('404 is success for read/delete/list but permanent for write', () {
      expect(SupabaseSyncClient.classifyStorageStatus('404', StorageOp.delete),
          const SyncOutcome.success());
      expect(SupabaseSyncClient.classifyStorageStatus('404', StorageOp.read),
          const SyncOutcome.success());
      expect(SupabaseSyncClient.classifyStorageStatus('404', StorageOp.list),
          const SyncOutcome.success());
      expect(SupabaseSyncClient.classifyStorageStatus('404', StorageOp.write),
          const SyncOutcome.permanent('storage_404'));
    });

    test('5xx / timeout-ish are transient', () {
      expect(SupabaseSyncClient.classifyStorageStatus('500', StorageOp.write),
          const SyncOutcome.transient('5xx'));
      expect(SupabaseSyncClient.classifyStorageStatus('429', StorageOp.write),
          const SyncOutcome.transient('429'));
      expect(SupabaseSyncClient.classifyStorageStatus(null, StorageOp.write),
          const SyncOutcome.transient('storage_unknown'));
    });

    test('persistent auth failure (after refresh + retry) is permanent', () {
      expect(SupabaseSyncClient.classifyStorageStatus('401', StorageOp.write),
          const SyncOutcome.permanent('storage_401'));
      expect(
          SupabaseSyncClient.classifyStorageStatus('PGRST301', StorageOp.list),
          const SyncOutcome.permanent('storage_401'));
    });
  });

  group('classifyUnexpectedError', () {
    test('an unrecognized exception type is permanent(unknown), not retried',
        () {
      expect(
          SupabaseSyncClient.classifyUnexpectedError(const FormatException('x')),
          const SyncOutcome.permanent('unknown'));
      expect(SupabaseSyncClient.classifyUnexpectedError(StateError('x')),
          const SyncOutcome.permanent('unknown'));
      expect(SupabaseSyncClient.classifyUnexpectedError(ArgumentError('x')),
          const SyncOutcome.permanent('unknown'));
    });
  });

  group('answerKeyRow', () {
    test('answers stay a flat "Section|Item" -> "Choice" map, not nested', () {
      final row = SupabaseSyncClient.answerKeyRow(
        examCode: 'AT',
        answers: const {'Test I|1': 'A', 'Test I|2': 'C'},
        version: 3,
        updatedByUid: 'uid-123',
        updatedByName: 'Officer',
        updatedAt: DateTime.utc(2026, 8, 31, 9, 0, 0),
      );

      expect(row['exam_code'], 'AT');
      expect(row['answers'], {'Test I|1': 'A', 'Test I|2': 'C'});
      expect(row['answers'], isA<Map<String, String>>());
      expect(row['version'], 3);
      expect(row['updated_by_uid'], 'uid-123');
      expect(row['updated_by_name'], 'Officer');
      expect(row['updated_at'], '2026-08-31T09:00:00.000Z');
      expect(row['schema_version'], isA<int>());
    });

    test('a null updated-by is preserved (not fabricated)', () {
      final row = SupabaseSyncClient.answerKeyRow(
        examCode: 'QTM',
        answers: const {},
        version: 1,
        updatedByUid: null,
        updatedByName: null,
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      expect(row['updated_by_uid'], isNull);
      expect(row['updated_by_name'], isNull);
      expect(row['answers'], isEmpty);
    });
  });

  group('answer-key conflict core (Phase 10E-1)', () {
    const localA = {'Test I|1': 'A', 'Test I|2': 'C'};
    final fixedNow = DateTime.utc(2026, 6, 1, 12);

    test('1. parseCloudAnswerKeyRow maps a full row to a found read with only '
        'version / answers / updated_by_name / updated_at', () {
      final read = SupabaseSyncClient.parseCloudAnswerKeyRow(<String, dynamic>{
        'version': 5,
        'answers': {'Test I|1': 'A', 'Test I|2': 'C'},
        'updated_by_name': 'Officer Dela Cruz',
        'updated_by_uid': 'firebase-uid-should-be-ignored',
        'updated_at': '2026-05-04T08:30:00.000Z',
        'schema_version': 1,
      });

      expect(read.exists, isTrue);
      expect(read.version, 5);
      expect(read.answers, {'Test I|1': 'A', 'Test I|2': 'C'});
      expect(read.answers, isA<Map<String, String>>());
      expect(read.updatedByName, 'Officer Dela Cruz');
      expect(read.updatedAt, '2026-05-04T08:30:00.000Z');
      expect(read.error, isNull);
    });

    test('2. parseCloudAnswerKeyRow(null) is an absent read, not an error',
        () {
      final read = SupabaseSyncClient.parseCloudAnswerKeyRow(null);
      expect(read.exists, isFalse);
      expect(read.version, isNull);
      expect(read.answers, isNull);
      expect(read.updatedByName, isNull);
      expect(read.updatedAt, isNull);
      expect(read.error, isNull);
    });

    test('3. lastPushed == null + local answers identical to cloud -> adopt '
        'the cloud version + timestamp as the baseline, no upsert', () {
      final d = SupabaseSyncClient.decideAnswerKeyPush(
        localAnswers: localA,
        meta: const {},
        lastPushedVersion: null,
        cloudVersion: 4,
        cloudAnswers: const {'Test I|1': 'A', 'Test I|2': 'C'},
        cloudUpdatedAt: DateTime.utc(2026, 3, 3, 8),
        now: fixedNow,
      );

      expect(d.action, AnswerKeyAction.adopt);
      expect(d.isAdopt, isTrue);
      expect(d.isUpsert, isFalse);
      expect(d.version, 4); // cloud version, not incremented
      expect(d.baselineUpdatedAt, DateTime.utc(2026, 3, 3, 8));
      expect(d.conflictCode, isNull);
    });

    test('4. lastPushed == null + local answers differ from cloud -> '
        'conflict("answer_key_changed"), never an overwrite', () {
      final d = SupabaseSyncClient.decideAnswerKeyPush(
        localAnswers: const {'Test I|1': 'A', 'Test I|2': 'D'},
        meta: const {},
        lastPushedVersion: null,
        cloudVersion: 4,
        cloudAnswers: const {'Test I|1': 'A', 'Test I|2': 'C'},
        cloudUpdatedAt: DateTime.utc(2026, 3, 3, 8),
        now: fixedNow,
      );

      expect(d.action, AnswerKeyAction.conflict);
      expect(d.isConflict, isTrue);
      expect(d.conflictCode, 'answer_key_changed');
      expect(d.version, isNull);
      expect(d.baselineUpdatedAt, isNull);
    });

    test('5. force + expectedCloudVersion == current cloud version -> upsert '
        'at cloud + 1', () {
      final d = SupabaseSyncClient.decideAnswerKeyPush(
        localAnswers: localA,
        meta: const {'force': 'true', 'expectedCloudVersion': '4'},
        lastPushedVersion: null,
        cloudVersion: 4,
        cloudAnswers: const {'Test I|1': 'Z'},
        cloudUpdatedAt: DateTime.utc(2026, 3, 3, 8),
        now: fixedNow,
      );

      expect(d.action, AnswerKeyAction.upsert);
      expect(d.isUpsert, isTrue);
      expect(d.version, 5);
      expect(d.baselineUpdatedAt, fixedNow);
      expect(d.conflictCode, isNull);
    });

    test('6. force + expectedCloudVersion != current cloud version -> '
        'conflict("answer_key_changed"), no upsert', () {
      final d = SupabaseSyncClient.decideAnswerKeyPush(
        localAnswers: localA,
        meta: const {'force': 'true', 'expectedCloudVersion': '4'},
        lastPushedVersion: null,
        cloudVersion: 6, // someone else advanced it since confirmation
        cloudAnswers: const {'Test I|1': 'Z'},
        cloudUpdatedAt: DateTime.utc(2026, 3, 3, 8),
        now: fixedNow,
      );

      expect(d.action, AnswerKeyAction.conflict);
      expect(d.conflictCode, 'answer_key_changed');
      expect(d.version, isNull);
    });

    test('7. force but the cloud row is gone -> conflict("answer_key_missing")',
        () {
      final d = SupabaseSyncClient.decideAnswerKeyPush(
        localAnswers: localA,
        meta: const {'force': 'true', 'expectedCloudVersion': '4'},
        lastPushedVersion: null,
        cloudVersion: null,
        cloudAnswers: null,
        cloudUpdatedAt: null,
        now: fixedNow,
      );

      expect(d.action, AnswerKeyAction.conflict);
      expect(d.conflictCode, 'answer_key_missing');
    });

    test('8. the force path consults ONLY force + expectedCloudVersion — any '
        'other meta key (e.g. a stray uid/email) is ignored', () {
      final clean = SupabaseSyncClient.decideAnswerKeyPush(
        localAnswers: localA,
        meta: const {'force': 'true', 'expectedCloudVersion': '4'},
        lastPushedVersion: null,
        cloudVersion: 4,
        cloudAnswers: const {'Test I|1': 'Z'},
        cloudUpdatedAt: null,
        now: fixedNow,
      );
      final polluted = SupabaseSyncClient.decideAnswerKeyPush(
        localAnswers: localA,
        meta: const {
          'force': 'true',
          'expectedCloudVersion': '4',
          'updated_by_uid': 'secret-uid',
          'email': 'officer@example.com',
        },
        lastPushedVersion: null,
        cloudVersion: 4,
        cloudAnswers: const {'Test I|1': 'Z'},
        cloudUpdatedAt: null,
        now: fixedNow,
      );

      expect(polluted.action, clean.action);
      expect(polluted.version, clean.version); // 5
      expect(polluted.baselineUpdatedAt, clean.baselineUpdatedAt);
    });
  });

  group('SyncOutcome', () {
    test('value equality holds for identical kind + code', () {
      expect(const SyncOutcome.permanent('42501'),
          const SyncOutcome.permanent('42501'));
      expect(const SyncOutcome.transient('network'),
          isNot(const SyncOutcome.permanent('network')));
      expect(const SyncOutcome.success().isSuccess, isTrue);
      expect(const SyncOutcome.success().code, isNull);
    });
  });

  group('examineeAuditColumns (Phase 9B-7E)', () {
    const tagMeta = {
      'operation': 'examinee_tag',
      'opAt': '2026-08-31T09:15:00.000Z',
    };
    const clearMeta = {
      'operation': 'examinee_clear',
      'opAt': '2026-08-31T10:00:00.000Z',
    };

    test('1. a normal push (no / unrecognized operation) touches nothing', () {
      expect(
        SupabaseSyncClient.examineeAuditColumns(
          meta: const {},
          isTagged: true,
          identityUid: 'uid-1',
          identityDisplayName: 'Officer',
        ),
        isEmpty,
      );
      expect(
        SupabaseSyncClient.examineeAuditColumns(
          meta: const {'operation': 'something_else'},
          isTagged: false,
          identityUid: 'uid-1',
          identityDisplayName: 'Officer',
        ),
        isEmpty,
      );
    });

    test('2. examinee_tag + a tagged local scan stamps all four columns', () {
      final cols = SupabaseSyncClient.examineeAuditColumns(
        meta: tagMeta,
        isTagged: true,
        identityUid: 'uid-1',
        identityDisplayName: 'Officer J',
      );
      expect(cols['tagged_by_uid'], 'uid-1');
      expect(cols['tagged_by_name'], 'Officer J');
      expect(cols['tagged_at'], '2026-08-31T09:15:00.000Z');
      expect(cols['examinee_updated_at'], '2026-08-31T09:15:00.000Z');
    });

    test('3. examinee_clear nulls tag identity/time, stamps examinee_updated_at',
        () {
      final cols = SupabaseSyncClient.examineeAuditColumns(
        meta: clearMeta,
        isTagged: false,
        identityUid: 'uid-1',
        identityDisplayName: 'Officer J',
      );
      expect(cols['tagged_by_uid'], isNull);
      expect(cols['tagged_by_name'], isNull);
      expect(cols['tagged_at'], isNull);
      expect(cols['examinee_updated_at'], '2026-08-31T10:00:00.000Z');
      expect(cols.keys.toSet(), {
        'tagged_by_uid',
        'tagged_by_name',
        'tagged_at',
        'examinee_updated_at',
      });
    });

    test('4. examinee_tag but the local scan is already cleared -> local wins',
        () {
      final cols = SupabaseSyncClient.examineeAuditColumns(
        meta: tagMeta, // label says tag ...
        isTagged: false, // ... but local state says cleared
        identityUid: 'uid-1',
        identityDisplayName: 'Officer J',
      );
      expect(cols['tagged_by_uid'], isNull);
      expect(cols['tagged_by_name'], isNull);
      expect(cols['tagged_at'], isNull);
      expect(cols['examinee_updated_at'], '2026-08-31T09:15:00.000Z');
    });

    test('5. missing / invalid opAt -> a valid UTC fallback timestamp', () {
      final fixed = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final missing = SupabaseSyncClient.examineeAuditColumns(
        meta: const {'operation': 'examinee_tag'},
        isTagged: true,
        identityUid: 'u',
        identityDisplayName: 'n',
        now: fixed,
      );
      expect(missing['tagged_at'], '2026-01-02T03:04:05.000Z');
      expect(missing['examinee_updated_at'], '2026-01-02T03:04:05.000Z');

      final invalid = SupabaseSyncClient.examineeAuditColumns(
        meta: const {'operation': 'examinee_clear', 'opAt': 'not-a-date'},
        isTagged: false,
        identityUid: 'u',
        identityDisplayName: 'n',
        now: fixed,
      );
      expect(invalid['examinee_updated_at'], '2026-01-02T03:04:05.000Z');
      // real fallback (no injected clock) is still a valid trailing-Z string
      final live = SupabaseSyncClient.examineeAuditColumns(
        meta: const {'operation': 'examinee_tag'},
        isTagged: true,
        identityUid: 'u',
        identityDisplayName: 'n',
      );
      expect((live['tagged_at'] as String).endsWith('Z'), isTrue);
    });

    test('6. a null identity does not throw; timestamps still stamped', () {
      final cols = SupabaseSyncClient.examineeAuditColumns(
        meta: tagMeta,
        isTagged: true,
        identityUid: null,
        identityDisplayName: null,
      );
      expect(cols['tagged_by_uid'], isNull);
      expect(cols['tagged_by_name'], isNull);
      expect(cols['tagged_at'], '2026-08-31T09:15:00.000Z');
      expect(cols['examinee_updated_at'], '2026-08-31T09:15:00.000Z');
    });
  });

  group('describeSocketException (physical-device transport diagnostics)', () {
    test('DNS / host-lookup failure: keeps osError code+message, masks the '
        'Supabase host, address=null port=null', () {
      final line = SupabaseSyncClient.describeSocketException(
        const SocketException(
          "Failed host lookup: 'hrrylkyikxjpujdieexc.supabase.co'",
          osError: OSError('No address associated with hostname', 7),
        ),
      );

      expect(line, startsWith('SocketException '));
      expect(line, contains('osErrorCode=7'));
      expect(line, contains('osErrorMessage="No address associated with hostname"'));
      expect(line, contains('address=null'));
      expect(line, contains('port=null'));
      // The project ref / host is masked, never printed verbatim.
      expect(line, contains('<supabase-host>'));
      expect(line, isNot(contains('hrrylkyikxjpujdieexc')));
      expect(line, isNot(contains('.supabase.co')));
    });

    test('refused connection: keeps osError code, the resolved IP address, '
        'and the port', () {
      final line = SupabaseSyncClient.describeSocketException(
        SocketException(
          'Connection refused',
          osError: const OSError('Connection refused', 111),
          address: InternetAddress('203.0.113.10'), // TEST-NET-3, not real
          port: 443,
        ),
      );

      expect(line, contains('message="Connection refused"'));
      expect(line, contains('osErrorCode=111'));
      expect(line, contains('address="203.0.113.10"'));
      expect(line, contains('port=443'));
    });

    test('no osError: reports osErrorCode=null osErrorMessage=null', () {
      final line = SupabaseSyncClient.describeSocketException(
        const SocketException('Connection reset by peer'),
      );

      expect(line, contains('message="Connection reset by peer"'));
      expect(line, contains('osErrorCode=null'));
      expect(line, contains('osErrorMessage=null'));
      expect(line, contains('address=null'));
      expect(line, contains('port=null'));
    });

    test('a token-shaped blob embedded in an OS string is redacted', () {
      final line = SupabaseSyncClient.describeSocketException(
        SocketException(
          'boom eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig-value-here-1234',
          osError: const OSError('sb_publishable_ABCDEFGHIJKLMNOPQRSTUV', -1),
        ),
      );

      expect(line, contains('<redacted>'));
      expect(line, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(line, isNot(contains('sb_publishable_ABCDEFGHIJKLMNOPQRSTUV')));
    });
  });

  group('scanIdentityColumns (examinee_all_or_nothing CHECK)', () {
    const trioKeys = {'first_name', 'last_name', 'examinee_number'};
    const identityKeys = {'first_name', 'last_name', 'examinee_number', 'middle_name'};

    test('1. a complete examinee sends all three identity fields', () {
      final cols = SupabaseSyncClient.scanIdentityColumns(
        const ExamineeInfo(
          firstName: 'JUAN',
          lastName: 'CRUZ',
          examineeNumber: '12345',
        ),
      );
      expect(cols.keys.toSet(), identityKeys);
      expect(cols['first_name'], 'JUAN');
      expect(cols['last_name'], 'CRUZ');
      expect(cols['examinee_number'], '12345');
      // No middle name given -> blank-to-null, valid on its own (middle_name
      // carries no CHECK constraint of its own).
      expect(cols['middle_name'], isNull);
      // -> all NOT NULL branch of the CHECK for the trio.
      expect(trioKeys.every((k) => cols[k] != null), isTrue);
    });

    test('2. a partial examinee (name, blank number) sends all three as null',
        () {
      final cols = SupabaseSyncClient.scanIdentityColumns(
        const ExamineeInfo(
          firstName: 'JUAN',
          lastName: 'CRUZ',
          middleName: 'SANTOS',
          examineeNumber: '', // OCR-suggested name, number not entered yet
        ),
      );
      expect(cols.keys.toSet(), identityKeys);
      expect(cols['first_name'], isNull);
      expect(cols['last_name'], isNull);
      expect(cols['examinee_number'], isNull);
      // middle_name follows the SAME tagged/untagged gate as the trio -- an
      // incomplete tag's middle name is never pushed either, even though it
      // isn't itself part of the all-or-nothing CHECK.
      expect(cols['middle_name'], isNull);
      // -> all NULL branch; the old code sent CRUZ/JUAN/null == SQLSTATE 23514.
    });

    test('APPROVED FIX — TEST 1 (incomplete/OCR-only): all four columns are null',
        () {
      final cols = SupabaseSyncClient.scanIdentityColumns(
        const ExamineeInfo(
          firstName: 'John',
          lastName: 'Doe',
          middleName: 'Smith',
          examineeNumber: '', // blank -> incomplete
        ),
      );
      expect(cols['first_name'], isNull);
      expect(cols['middle_name'], isNull);
      expect(cols['last_name'], isNull);
      expect(cols['examinee_number'], isNull);
    });

    test('APPROVED FIX — TEST 2 (complete tag): all four columns are populated,'
        ' including the previously-hardcoded middle_name', () {
      final cols = SupabaseSyncClient.scanIdentityColumns(
        const ExamineeInfo(
          firstName: 'John',
          middleName: 'Michael',
          lastName: 'Doe',
          examineeNumber: '12345',
        ),
      );
      expect(cols['first_name'], 'John');
      expect(cols['middle_name'], 'Michael');
      expect(cols['last_name'], 'Doe');
      expect(cols['examinee_number'], '12345');
    });

    test('2b. a whitespace-only examinee number is still treated as partial',
        () {
      final cols = SupabaseSyncClient.scanIdentityColumns(
        const ExamineeInfo(
          firstName: 'JUAN',
          lastName: 'CRUZ',
          examineeNumber: '   ',
        ),
      );
      expect(cols['first_name'], isNull);
      expect(cols['last_name'], isNull);
      expect(cols['examinee_number'], isNull);
    });

    test('3. a null examinee sends all four identity columns as null', () {
      final cols = SupabaseSyncClient.scanIdentityColumns(null);
      expect(cols.keys.toSet(), identityKeys);
      expect(cols['first_name'], isNull);
      expect(cols['last_name'], isNull);
      expect(cols['examinee_number'], isNull);
      expect(cols['middle_name'], isNull);
    });

    test('3b. a fully empty examinee sends all three as null', () {
      final cols = SupabaseSyncClient.scanIdentityColumns(
        const ExamineeInfo(firstName: '', lastName: '', examineeNumber: ''),
      );
      expect(cols['first_name'], isNull);
      expect(cols['last_name'], isNull);
      expect(cols['examinee_number'], isNull);
    });

    test('4. name present but missing last name only -> still all null', () {
      final cols = SupabaseSyncClient.scanIdentityColumns(
        const ExamineeInfo(
          firstName: 'JUAN',
          lastName: '',
          examineeNumber: '12345',
        ),
      );
      expect(cols['first_name'], isNull);
      expect(cols['last_name'], isNull);
      expect(cols['examinee_number'], isNull);
    });

    test('5. examineeTagged mirrors ExamineeInfo.isComplete', () {
      expect(
        SupabaseSyncClient.examineeTagged(
          const ExamineeInfo(
            firstName: 'A',
            lastName: 'B',
            examineeNumber: 'C',
          ),
        ),
        isTrue,
      );
      expect(
        SupabaseSyncClient.examineeTagged(
          const ExamineeInfo(
            firstName: 'A',
            lastName: 'B',
            examineeNumber: '',
          ),
        ),
        isFalse,
      );
      expect(SupabaseSyncClient.examineeTagged(null), isFalse);
    });
  });
}
