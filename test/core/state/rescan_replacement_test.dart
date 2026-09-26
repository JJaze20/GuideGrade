import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show XFile;
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/core/state/rescan_candidate.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

const _originalDecode = OmrScanResult(
  examCode: 'AT',
  items: [OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: 'B')],
);
const _candidateDecode = OmrScanResult(
  examCode: 'AT',
  items: [OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: 'A')],
);

final _key = AnswerKey(examCode: 'AT', correctChoices: {'Section 1|1': 'A'});

LocalScan _stored({ExamineeInfo? examinee, DateTime? scannedAt}) => LocalScan(
      id: 's1',
      imageFileName: 'images/s1.enc',
      capturedAt: DateTime.utc(2026, 8, 1),
      decoded: _originalDecode,
      result: LocalScanResult(
        rawScore: 0,
        totalGraded: 1,
        totalItems: 72,
        percentage: 0,
        status: 'Graded',
        scannedAt: scannedAt ?? DateTime.utc(2026, 8, 1, 9),
        processedByUid: 'orig',
        processedByName: 'Original Scanner',
      ),
      examinee: examinee,
    );

LocalBatch _batch(LocalScan scan) => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: '',
      expectedCount: 5,
      status: 'Archived',
      createdByUid: 'u',
      createdByName: 'o',
      createdAt: DateTime.utc(2026, 8, 1),
      updatedAt: DateTime.utc(2026, 8, 2),
      scans: [scan],
    );

class _ReplaceCall {
  final File sourceImage;
  final File? rectified;
  final LocalScanResult? result;
  final ExamineeInfo? examinee;
  final File? cropLast;
  final LocalScan? expectedOriginal;
  final OmrScanResult decoded;
  _ReplaceCall(this.sourceImage, this.rectified, this.result, this.examinee, this.cropLast, this.expectedOriginal, this.decoded);
}

class _Repo implements BatchRepository {
  _Repo(this.batch);
  LocalBatch batch;
  final calls = <_ReplaceCall>[];
  Object? failWith;
  Completer<void>? gate;

  @override
  Future<LocalBatch> replaceScan({
    required String batchId,
    required String scanId,
    required OmrScanResult decoded,
    required File sourceImage,
    File? rectifiedImage,
    LocalScanResult? result,
    ExamineeInfo? examinee,
    File? nameCropLastImage,
    File? nameCropFirstImage,
    File? nameCropMiddleImage,
    LocalScan? expectedOriginal,
  }) async {
    calls.add(_ReplaceCall(sourceImage, rectifiedImage, result, examinee, nameCropLastImage, expectedOriginal, decoded));
    if (gate != null) await gate!.future;
    final err = failWith;
    if (err != null) throw err;
    return batch;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;
  late _Repo repo;
  late AppState app;
  late LocalScan stored;

  File tempFile(String name) => File('${tmp.path}/$name')..writeAsBytesSync(const [1, 2, 3]);

  /// A rescan in progress with a decoded candidate awaiting confirmation.
  RescanCandidate stage({String? ocrLast, String? ocrFirst}) {
    final photo = tempFile('photo.jpg');
    final review = tempFile('review.jpg');
    final cropLast = tempFile('crop_last.jpg');
    final cropFirst = tempFile('crop_first.jpg');
    app.startRescan(repo.batch, stored);
    app.capturedPages.add(XFile(photo.path));
    app.scannedResults.add(_candidateDecode);
    app.rectifiedImagePaths.add(review.path);
    final candidate = RescanCandidate(
      photoPath: photo.path,
      decoded: _candidateDecode,
      reviewImagePath: review.path,
      nameCropLastPath: cropLast.path,
      nameCropFirstPath: cropFirst.path,
      ocrLastName: ocrLast,
      ocrFirstName: ocrFirst,
    );
    app.rescanCandidate = candidate;
    return candidate;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rescan_replacement_test_');
    stored = _stored(
      examinee: const ExamineeInfo(firstName: 'Ana', lastName: 'Cruz', middleName: '', examineeNumber: 'EX-42'),
    );
    repo = _Repo(_batch(stored));
    app = AppState(batchRepository: repo);
    app.answerKeys['AT'] = _key;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('confirmation before replacement', () {
    test('nothing is saved without the verification: the repository is never touched', () async {
      stage();

      final ok = await app.finishRescan(expectedOriginal: stored, identityVerified: false);

      expect(ok, isFalse);
      expect(repo.calls, isEmpty);
      expect(app.rescanSaveError, contains('same original answer sheet'));
      expect(app.rescanScanId, 's1', reason: 'the rescan is still open');
      expect(app.rescanCandidate, isNotNull, reason: 'the candidate is kept');
    });

    test('preparing/staging a candidate never writes to the repository either', () {
      stage();
      expect(repo.calls, isEmpty);
    });

    test('with verification it replaces once, using the reviewed candidate and the original as the guard', () async {
      final candidate = stage();

      final ok = await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      expect(ok, isTrue);
      expect(repo.calls, hasLength(1));
      final call = repo.calls.single;
      expect(call.sourceImage.path, candidate.photoPath);
      expect(call.decoded, same(_candidateDecode), reason: 'the candidate\'s existing decode is reused');
      expect(call.cropLast!.path, candidate.nameCropLastPath, reason: 'crops are the ones the reviewer saw');
      expect(identical(call.expectedOriginal, stored), isTrue);
      expect(app.rescanScanId, isNull);
      expect(app.rescanCandidate, isNull);
    });
  });

  group('identity and date are preserved', () {
    test('the saved name and Examinee ID are not rebuilt from OCR', () async {
      stage(ocrLast: 'TotallyDifferent', ocrFirst: 'Person');

      await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      // null = "keep the stored tag exactly as it is" (BatchRepository.replaceScan contract).
      expect(repo.calls.single.examinee, isNull);
    });

    test('a legacy sheet with no Examinee ID gets one, keeping its names — never OCR names', () async {
      stored = _stored(examinee: const ExamineeInfo(firstName: 'Ana', lastName: 'Cruz', examineeNumber: ''));
      repo = _Repo(_batch(stored));
      app = AppState(batchRepository: repo)..answerKeys['AT'] = _key;
      stage(ocrLast: 'Nope', ocrFirst: 'Nope');

      await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      final e = repo.calls.single.examinee!;
      expect(e.lastName, 'Cruz');
      expect(e.firstName, 'Ana');
      expect(e.examineeNumber, isNotEmpty);
    });

    test('the saved result keeps the sheet\'s original scoring date, scored on the new decode', () async {
      stage();

      await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      final result = repo.calls.single.result!;
      expect(result.scannedAt, stored.result!.scannedAt);
      expect(result.rawScore, 1, reason: 'the candidate answers A, the key is A');
    });
  });

  group('double submission', () {
    test('a second confirmation while the first is saving is ignored', () async {
      stage();
      repo.gate = Completer<void>();

      final first = app.finishRescan(expectedOriginal: stored, identityVerified: true);
      await Future<void>.delayed(Duration.zero);
      expect(app.isSavingRescan, isTrue);
      final second = await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      expect(second, isFalse);
      repo.gate!.complete();
      expect(await first, isTrue);
      expect(repo.calls, hasLength(1));
    });
  });

  group('a failed save', () {
    test('leaves the rescan and candidate in place, reports why, and a retry can succeed', () async {
      final candidate = stage();
      repo.failWith = const FileSystemException('disk full');

      final failed = await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      expect(failed, isFalse);
      expect(app.rescanSaveError, contains('Could not save the rescan'));
      expect(app.rescanOriginalChanged, isFalse);
      expect(app.isSavingRescan, isFalse);
      expect(app.rescanScanId, 's1');
      expect(app.rescanCandidate, same(candidate));
      expect(File(candidate.photoPath).existsSync(), isTrue, reason: 'temp files kept so a retry can still save');

      repo.failWith = null;
      final retried = await app.finishRescan(expectedOriginal: stored, identityVerified: true);
      expect(retried, isTrue);
      expect(repo.calls, hasLength(2));
    });

    test('an original that changed or was deleted is reported and flagged as not retryable', () async {
      stage();
      repo.failWith = RescanOriginalChangedException(deleted: false);

      final ok = await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      expect(ok, isFalse);
      expect(app.rescanOriginalChanged, isTrue);
      expect(app.rescanSaveError, contains('changed while you were comparing'));
      expect(app.rescanScanId, 's1');

      repo.failWith = RescanOriginalChangedException(deleted: true);
      await app.finishRescan(expectedOriginal: stored, identityVerified: true);
      expect(app.rescanSaveError, contains('deleted'));
    });
  });

  group('abandoning a candidate', () {
    test('Cancel deletes the candidate\'s temporary files and closes the rescan, saving nothing', () {
      final candidate = stage();

      app.cancelRescan();

      for (final p in candidate.temporaryPaths) {
        expect(File(p).existsSync(), isFalse, reason: p);
      }
      expect(app.rescanScanId, isNull);
      expect(app.rescanCandidate, isNull);
      expect(app.capturedPages, isEmpty);
      expect(repo.calls, isEmpty);
    });

    test('Retake deletes the candidate but keeps the rescan open for a new capture', () {
      final candidate = stage();

      app.discardRescanCandidate();

      for (final p in candidate.temporaryPaths) {
        expect(File(p).existsSync(), isFalse, reason: p);
      }
      expect(app.rescanScanId, 's1', reason: 'still rescanning the same sheet');
      expect(app.capturedPages, isEmpty);
      expect(app.rescanCandidate, isNull);
      expect(repo.calls, isEmpty);
    });

    test('never deletes a file inside batch storage, even if one were listed', () {
      final storage = Directory('${tmp.path}/guidegrade_batches/b1/images')..createSync(recursive: true);
      final saved = File('${storage.path}/s1.enc')..writeAsBytesSync(const [7]);
      stage();
      app.capturedPages.add(XFile(saved.path));

      app.cancelRescan();

      expect(saved.existsSync(), isTrue, reason: 'a saved record\'s file must survive cleanup');
    });

    test('after a successful replacement the temporary candidate files are cleaned up', () async {
      final candidate = stage();

      await app.finishRescan(expectedOriginal: stored, identityVerified: true);

      for (final p in candidate.temporaryPaths) {
        expect(File(p).existsSync(), isFalse, reason: p);
      }
    });
  });
}
