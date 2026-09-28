import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/analytics/at_batch_analytics.dart';
import 'package:guidegrade/core/analytics/tat_batch_analytics.dart';
import 'package:guidegrade/core/omr/admission_category.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/omr/qtm_result.dart';
import 'package:guidegrade/core/omr/tat_result.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_analytics_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_analytics_service.dart';
import 'package:guidegrade/models/answer_key.dart';

/// Read-only stand-in for Supabase. ANY write (or an unrelated read) is
/// recorded in [forbidden] and throws, so a test can prove Analytics never
/// attempts one.
class _FakeClient implements SyncClient {
  final List<CloudBatchRow> batches = [];
  final Map<String, List<CloudScanRow>> scansByBatch = {};
  final Set<String> archivedIds = {};
  bool archiveReadFails = false;
  bool batchReadFails = false;
  final Map<String, int> countsOverride = {};
  CloudAnswerKeyRead keyRead = const CloudAnswerKeyRead.absent();

  final List<String> calls = [];
  final List<String> forbidden = [];
  final Map<String, int> scanReads = {};
  final Map<String, int> keyReads = {};
  int _inFlight = 0;
  int maxInFlight = 0;
  Duration scanDelay = const Duration(milliseconds: 5);

  Never _no(String label) {
    forbidden.add(label);
    throw StateError('Analytics must never call $label');
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('readCloudBatches');
    if (batchReadFails) return const CloudBatchesRead.failed(SyncOutcome.permanent('42501'));
    return CloudBatchesRead.found(List.of(batches));
  }

  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async {
    calls.add('readBatchArchives');
    if (archiveReadFails) return const CloudBatchArchivesRead.failed(SyncOutcome.permanent('PGRST205'));
    return CloudBatchArchivesRead.found([
      for (final id in archivedIds)
        CloudBatchArchiveRow(batchId: id, archivedAt: DateTime.utc(2026, 3, 1), archivedByUid: 'u'),
    ]);
  }

  @override
  Future<CloudScanCountsRead> readScanCounts(List<String> batchIds) async {
    calls.add('readScanCounts');
    return CloudScanCountsRead.found({
      for (final id in batchIds) id: countsOverride[id] ?? (scansByBatch[id] ?? const []).length,
    });
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    calls.add('readCloudScans:$batchId');
    scanReads[batchId] = (scanReads[batchId] ?? 0) + 1;
    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    await Future<void>.delayed(scanDelay);
    _inFlight--;
    return CloudScansRead.found(List.of(scansByBatch[batchId] ?? const []));
  }

  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    calls.add('readAnswerKey:$examCode');
    keyReads[examCode] = (keyReads[examCode] ?? 0) + 1;
    return keyRead;
  }

  // Everything below is a write or an unrelated read: forbidden for Analytics.
  @override
  Future<SyncOutcome> pushBatch(String batchId) => _no('pushBatch');
  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId, {Map<String, String> meta = const {}}) =>
      _no('pushScan');
  @override
  Future<SyncOutcome> uploadImage(SyncJob job) => _no('uploadImage');
  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) => _no('patchImageStatus');
  @override
  Future<SyncOutcome> pushAnswerKey(String examCode, {Map<String, String> meta = const {}}) =>
      _no('pushAnswerKey');
  @override
  Future<CloudImageRead> downloadScanImage({
    required String batchId,
    required String scanId,
    required bool rectified,
  }) =>
      _no('downloadScanImage');

  @override
  Future<CloudImageRead> downloadNameCropImage({
    required String batchId,
    required String scanId,
    required String variant,
  }) => _no('downloadNameCropImage');

  @override
  Future<SyncOutcome> deleteBatch(String batchId) => _no('deleteBatch');
  @override
  Future<SyncOutcome> deleteScan(String batchId, String scanId) => _no('deleteScan');
  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) => _no('deleteStoragePrefix');
  @override
  Future<CloudExamineesRead> readCloudExaminees() => _no('readCloudExaminees');
  @override
  Future<CloudExamineeWrite> createExamineeFromScan({
    required String batchId,
    required String scanId,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no('createExamineeFromScan');
  @override
  Future<CloudExamineeWrite> updateCloudExaminee({
    required String id,
    required String firstName,
    String? middleName,
    required String lastName,
  }) =>
      _no('updateCloudExaminee');
  @override
  Future<CloudExamineeWrite> setExamineeArchived(String id, bool archived) => _no('setExamineeArchived');
  @override
  Future<SyncOutcome> linkScanToExaminee({
    required String batchId,
    required String scanId,
    required String? examineeId,
  }) =>
      _no('linkScanToExaminee');
  @override
  Future<SyncOutcome> unlinkScanFromExaminee({
    required String batchId,
    required String scanId,
    required String examineeId,
  }) =>
      _no('unlinkScanFromExaminee');
  @override
  Future<CloudScansRead> readCloudScansForExaminee(String examineeId) => _no('readCloudScansForExaminee');
  @override
  Future<CloudScansRead> readUnlinkedScans() => _no('readUnlinkedScans');
  @override
  Future<SyncOutcome> archiveBatch({required String batchId, String? reason}) => _no('archiveBatch');
}

CloudBatchRow _batch(String id, String examCode, {String status = 'Completed', int day = 1}) => CloudBatchRow(
      id: id,
      batchCode: 'CODE-$id',
      examCode: examCode,
      examTitle: 'Title $examCode',
      description: '',
      expectedCount: 100,
      status: status,
      createdByUid: 'uid',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 1, day),
      updatedAt: DateTime.utc(2026, 1, day),
    );

CloudScanRow _scan(
  String id,
  String batchId,
  String examCode,
  int? raw, {
  Map<String, dynamic>? decoded,
  int attemptNo = 1,
  String attemptStatus = 'active',
}) =>
    CloudScanRow(
      id: id,
      batchId: batchId,
      examCode: examCode,
      capturedAt: DateTime.utc(2026, 1, 1),
      decoded: decoded ?? {'examCode': examCode, 'items': <dynamic>[]},
      rawScore: raw,
      // AT's existing analyzable rule needs the key to cover all 72 items.
      totalGraded: raw == null ? null : (examCode == 'AT' ? 72 : 10),
      totalItems: examCode == 'AT' ? 72 : (examCode == 'QTM' ? 60 : 130),
      resultStatus: raw == null ? null : 'Graded',
      scannedAt: raw == null ? null : DateTime.utc(2026, 1, 1),
      processedByUid: 'uid',
      processedByName: 'Officer',
      firstName: 'First$id',
      lastName: 'Last$id',
      examineeNumber: 'EX-$id',
      attemptNo: attemptNo,
      attemptStatus: attemptStatus,
    );

/// A TAT decoded sheet: the first [c] items of each template section are
/// marked correct ('A'), the rest marked wrong ('B'). Against [_completeKey]
/// this yields Test 1 = 2*c1, Test 2 = max(0, c2-(80-c2)), Test 3 =
/// max(0, c3-(20-c3)).
Map<String, dynamic> _tatDecoded(int c1, int c2, int c3) {
  final counts = [c1, c2, c3];
  final sections = omrTemplates['TAT']!.sections;
  final items = <Map<String, dynamic>>[];
  for (var s = 0; s < sections.length; s++) {
    for (var i = 1; i <= sections[s].itemCount; i++) {
      items.add({
        'sectionName': sections[s].name,
        'itemNumber': i,
        'markedChoice': i <= counts[s] ? 'A' : 'B',
        'isAmbiguous': false,
      });
    }
  }
  return {'examCode': 'TAT', 'items': items};
}

int _tatTotal(int c1, int c2, int c3) {
  int atLeast0(int v) => v < 0 ? 0 : v;
  return c1 * 2 + atLeast0(c2 - (80 - c2)) + atLeast0(c3 - (20 - c3));
}

Map<String, String> _completeKeyAnswers() {
  final map = <String, String>{};
  for (final s in omrTemplates['TAT']!.sections) {
    for (var i = 1; i <= s.itemCount; i++) {
      map[AnswerKey.keyFor(s.name, i)] = 'A';
    }
  }
  return map;
}

CloudAnswerKeyRead _foundKey(Map<String, String> answers) => CloudAnswerKeyRead.found(
      version: 12,
      answers: answers,
      updatedByName: 'Ms. Cruz',
      updatedAt: '2026-09-19T08:00:00Z',
    );

void main() {
  late _FakeClient client;
  late GuidanceWebAnalyticsService service;

  setUp(() {
    client = _FakeClient();
    service = GuidanceWebAnalyticsService(client: client);
  });

  Future<AnalyticsResult> run(
    String examCode, {
    AnalyticsBatchStatus status = AnalyticsBatchStatus.all,
    String? batchId,
  }) async {
    final catalog = await service.loadCatalog();
    return service.analyze(
      catalog: catalog,
      examCode: examCode,
      status: status,
      batch: batchId == null ? null : catalog.batches.firstWhere((b) => b.id == batchId),
    );
  }

  group('TAT overall uses the stored raw_score', () {
    void seedTat() {
      client.batches.add(_batch('t1', 'TAT'));
      client.scansByBatch['t1'] = [
        // Stored totals 90 / 40 / 150. The decoded sheets deliberately
        // produce DIFFERENT totals with the current key.
        _scan('a', 't1', 'TAT', 90, decoded: _tatDecoded(10, 40, 5)),
        _scan('b', 't1', 'TAT', 40, decoded: _tatDecoded(20, 60, 15)),
        _scan('c', 't1', 'TAT', 150, decoded: _tatDecoded(0, 0, 0)),
        _scan('d', 't1', 'TAT', null), // ungraded
      ];
    }

    for (final withKey in [false, true]) {
      test('total/percentage/eligibility/bands/average/highest/lowest/median (key ${withKey ? 'present' : 'missing'})',
          () async {
        seedTat();
        if (withKey) client.keyRead = _foundKey(_completeKeyAnswers());
        final o = (await run('TAT')).tatOverall!;

        expect(o.totalExaminees, 4);
        expect(o.gradedExaminees, 3);
        expect(o.ungradedExaminees, 1);
        expect(o.averageTotal, closeTo((90 + 40 + 150) / 3, 1e-9));
        expect(o.highestTotal, 150);
        expect(o.lowestTotal, 40);
        expect(o.medianTotal, 90);
        expect(o.averagePercentage, closeTo(((90 + 40 + 150) / 3) / 160 * 100, 1e-9));
        expect(o.highestPercentage, closeTo(150 / 160 * 100, 1e-9));
        expect(o.lowestPercentage, closeTo(40 / 160 * 100, 1e-9));
        expect(o.medianPercentage, closeTo(90 / 160 * 100, 1e-9));
        // Eligibility: 40 does not meet (<48); 90 and 150 meet.
        expect(o.eligibilityDistribution[TatEligibility.meetsRequirement], 2);
        expect(o.eligibilityDistribution[TatEligibility.doesNotMeetRequirement], 1);
        // Bands from the stored totals.
        expect(o.totalScoreDistribution[TatTotalBand.band40to59], 1);
        expect(o.totalScoreDistribution[TatTotalBand.band80to99], 1);
        expect(o.totalScoreDistribution[TatTotalBand.band140to160], 1);
      });
    }

    test('average percentage is the mean of raw_score / 160 * 100', () async {
      seedTat();
      final o = (await run('TAT')).tatOverall!;
      final expected = (90 / 160 * 100 + 40 / 160 * 100 + 150 / 160 * 100) / 3;
      expect(o.averagePercentage, closeTo(expected, 1e-9));
    });

    test('a stored total outside 0..160 is excluded and counted, not fabricated', () async {
      client.batches.add(_batch('t1', 'TAT'));
      client.scansByBatch['t1'] = [_scan('a', 't1', 'TAT', 90), _scan('b', 't1', 'TAT', 999)];
      final o = (await run('TAT')).tatOverall!;
      expect(o.analyzableExaminees, 1);
      expect(o.excludedGradedCount, 1);
    });
  });

  group('TAT detailed analysis (Answer Key)', () {
    void seedConsistent() {
      client.batches.add(_batch('t1', 'TAT'));
      client.scansByBatch['t1'] = [
        _scan('a', 't1', 'TAT', _tatTotal(20, 60, 15), decoded: _tatDecoded(20, 60, 15)), // 40+40+10 = 90
        _scan('b', 't1', 'TAT', _tatTotal(10, 50, 10), decoded: _tatDecoded(10, 50, 10)), // 20+20+0 = 40
      ];
    }

    test('a complete key produces per-test analytics, strongest and weakest via the existing helper', () async {
      seedConsistent();
      client.keyRead = _foundKey(_completeKeyAnswers());
      final d = (await run('TAT')).tatDetail!;
      expect(d.status, TatDetailStatus.available);
      final a = d.analytics!;
      expect(a.analyzableExaminees, 2);
      expect(a.test1.average, 30); // (40 + 20) / 2
      expect(a.test2.average, 30); // (40 + 20) / 2
      expect(a.test3.average, 5); // (10 + 0) / 2
      expect(a.strongestTestByPercent, TatTestKey.test1); // 50% of max
      expect(a.weakestTestByPercent, TatTestKey.test3); // 25% of max
      expect(d.drifts, isEmpty);
    });

    test('provenance comes from the existing version / updated_at / updated_by_name', () async {
      seedConsistent();
      client.keyRead = _foundKey(_completeKeyAnswers());
      final info = (await run('TAT')).tatDetail!.keyInfo!;
      expect(info.version, 12);
      expect(info.updatedByName, 'Ms. Cruz');
      expect(info.updatedAt, DateTime.utc(2026, 9, 19, 8));
    });

    test('a missing key does not crash: overall works, detail is unavailable', () async {
      seedConsistent();
      client.keyRead = const CloudAnswerKeyRead.absent();
      final r = await run('TAT');
      expect(r.tatOverall!.gradedExaminees, 2);
      expect(r.tatOverall!.highestTotal, 90);
      expect(r.tatDetail!.status, TatDetailStatus.keyMissing);
      expect(r.tatDetail!.analytics, isNull);
      expect(r.tatDetail!.keyInfo, isNull);
    });

    test('an incomplete key gives NO partial per-test results, but overall still works', () async {
      seedConsistent();
      final answers = _completeKeyAnswers()..remove(_completeKeyAnswers().keys.first);
      client.keyRead = _foundKey(answers);
      final r = await run('TAT');
      expect(r.tatOverall!.highestTotal, 90);
      expect(r.tatDetail!.status, TatDetailStatus.keyIncomplete);
      expect(r.tatDetail!.analytics, isNull);
      expect(r.tatDetail!.drifts, isEmpty);
      expect(r.tatDetail!.keyInfo!.version, 12); // provenance still shown
    });

    test('an empty-string answer counts as incomplete', () {
      final answers = _completeKeyAnswers();
      answers[answers.keys.last] = '  ';
      expect(isTatAnswerKeyComplete(AnswerKey(examCode: 'TAT', correctChoices: answers)), isFalse);
      expect(isTatAnswerKeyComplete(AnswerKey(examCode: 'TAT', correctChoices: _completeKeyAnswers())), isTrue);
    });

    test('completeness is derived from omrTemplates[TAT] (every section|item)', () {
      final expected = omrTemplates['TAT']!.sections.fold<int>(0, (n, s) => n + s.itemCount);
      expect(_completeKeyAnswers().length, expected);
    });

    test('a failed key read is non-fatal: overall works, detail is unavailable', () async {
      seedConsistent();
      client.keyRead = const CloudAnswerKeyRead.failed(SyncOutcome.transient('network'));
      final r = await run('TAT');
      expect(r.tatOverall!.gradedExaminees, 2);
      expect(r.tatDetail!.status, TatDetailStatus.keyUnavailable);
    });

    test('a recomputed total that differs from raw_score warns, stays included, and never replaces raw_score',
        () async {
      client.batches.add(_batch('t1', 'TAT'));
      client.scansByBatch['t1'] = [
        _scan('drift', 't1', 'TAT', 92, decoded: _tatDecoded(20, 60, 15)), // recorded 92, current key 90
        _scan('ok', 't1', 'TAT', _tatTotal(10, 50, 10), decoded: _tatDecoded(10, 50, 10)),
      ];
      client.keyRead = _foundKey(_completeKeyAnswers());
      final r = await run('TAT');

      expect(r.tatDetail!.drifts, hasLength(1));
      final drift = r.tatDetail!.drifts.single;
      expect(drift.scanId, 'drift');
      expect(drift.recordedTotal, 92);
      expect(drift.currentKeyTotal, 90);
      // Included in the per-test summaries.
      expect(r.tatDetail!.analytics!.analyzableExaminees, 2);
      // The recorded 92 stays official in the overall statistics.
      expect(r.tatOverall!.highestTotal, 92);
      // The source row was not altered.
      expect(client.scansByBatch['t1']!.first.rawScore, 92);
    });
  });

  group('AT and QTM use the existing helpers on stored scores, with no Answer Key', () {
    test('AT: stored raw_score, existing categories and bands', () async {
      client.batches.add(_batch('a1', 'AT'));
      client.scansByBatch['a1'] = [
        _scan('1', 'a1', 'AT', 50), // A
        _scan('2', 'a1', 'AT', 56), // Unclassified
        _scan('3', 'a1', 'AT', 59), // B
        _scan('4', 'a1', 'AT', 62), // C
        _scan('5', 'a1', 'AT', 70), // D
      ];
      final r = await run('AT');
      final at = r.at!;
      expect(at.averageRawScore, closeTo((50 + 56 + 59 + 62 + 70) / 5, 1e-9));
      expect(at.categoryDistribution[AdmissionCategory.a], 1);
      expect(at.categoryDistribution[AdmissionCategory.b], 1);
      expect(at.categoryDistribution[AdmissionCategory.c], 1);
      expect(at.categoryDistribution[AdmissionCategory.d], 1);
      expect(at.unclassifiedCount, 1);
      expect(at.scoreDistribution[AtScoreBand.unclassified], 1);
      expect(client.keyReads, isEmpty); // no Answer Key read for AT
    });

    test('QTM: stored raw_score, existing eligibility and bands', () async {
      client.batches.add(_batch('q1', 'QTM'));
      client.scansByBatch['q1'] = [
        _scan('1', 'q1', 'QTM', 10), // < 15
        _scan('2', 'q1', 'QTM', 16), // 15..17
        _scan('3', 'q1', 'QTM', 20), // 18+
      ];
      final q = (await run('QTM')).qtm!;
      expect(q.eligibilityDistribution[QtmEligibility.notEligible], 1);
      expect(q.eligibilityDistribution[QtmEligibility.allCoursesExceptBscs], 1);
      expect(q.eligibilityDistribution[QtmEligibility.allCoursesIncludingBscs], 1);
      expect(q.averageRawScore, closeTo(46 / 3, 1e-9));
      expect(client.keyReads, isEmpty); // no Answer Key read for QTM
    });
  });

  group('Answer Key retrieval', () {
    test('TAT: exactly one readAnswerKey per load, however many scans and batches', () async {
      for (var i = 0; i < 3; i++) {
        client.batches.add(_batch('t$i', 'TAT', day: i + 1));
        client.scansByBatch['t$i'] = [
          for (var s = 0; s < 8; s++) _scan('s$i-$s', 't$i', 'TAT', 60, decoded: _tatDecoded(20, 60, 15)),
        ];
      }
      client.keyRead = _foundKey(_completeKeyAnswers());
      await run('TAT');
      expect(client.keyReads['TAT'], 1);
      expect(client.keyReads.length, 1);
    });

    test('no Answer Key read when nothing complete is analyzed', () async {
      client.batches.add(_batch('t1', 'TAT'));
      client.scansByBatch['t1'] = [_scan('a', 't1', 'TAT', 60)];
      client.countsOverride['t1'] = 5; // mismatch -> incomplete
      await run('TAT');
      expect(client.keyReads, isEmpty);
    });
  });

  group('Web Archive filtering (batch_archives only)', () {
    setUp(() {
      client.batches
        ..add(_batch('archived', 'AT', day: 3))
        ..add(_batch('current', 'AT', day: 2))
        // Mobile status 'Archived' but NO Web Archive marker -> still Current.
        ..add(_batch('mobile-archived', 'AT', status: 'Archived', day: 1));
      client.archivedIds.add('archived');
      for (final id in ['archived', 'current', 'mobile-archived']) {
        client.scansByBatch[id] = [_scan('$id-1', id, 'AT', 60)];
      }
    });

    test('All includes current + Web-archived', () async {
      final catalog = await service.loadCatalog();
      final ids = catalog.batchesFor(examCode: 'AT', status: AnalyticsBatchStatus.all).map((b) => b.id);
      expect(ids.toSet(), {'archived', 'current', 'mobile-archived'});
    });

    test('Current excludes Web-archived, and batches.status == Archived is ignored', () async {
      final catalog = await service.loadCatalog();
      final ids = catalog.batchesFor(examCode: 'AT', status: AnalyticsBatchStatus.current).map((b) => b.id);
      expect(ids.toSet(), {'current', 'mobile-archived'});
    });

    test('Archived includes only batches with a batch_archives marker', () async {
      final catalog = await service.loadCatalog();
      final ids = catalog.batchesFor(examCode: 'AT', status: AnalyticsBatchStatus.archived).map((b) => b.id);
      expect(ids.toList(), ['archived']);
    });

    test('archived batches are fully analyzable', () async {
      final r = await run('AT', status: AnalyticsBatchStatus.archived);
      expect(r.at!.totalExaminees, 1);
      expect(r.analyzedBatches.single.id, 'archived');
    });

    test('a failed marker read leaves All usable and makes Current/Archived unavailable (not "none archived")',
        () async {
      client.archiveReadFails = true;
      final catalog = await service.loadCatalog();
      expect(catalog.archiveFilterAvailable, isFalse);
      expect(catalog.batchesFor(examCode: 'AT', status: AnalyticsBatchStatus.all), hasLength(3));
      expect(() => catalog.batchesFor(examCode: 'AT', status: AnalyticsBatchStatus.current),
          throwsA(isA<GuidanceWebAnalyticsException>()));
      expect(() => catalog.batchesFor(examCode: 'AT', status: AnalyticsBatchStatus.archived),
          throwsA(isA<GuidanceWebAnalyticsException>()));
      final r = await service.analyze(catalog: catalog, examCode: 'AT', status: AnalyticsBatchStatus.all);
      expect(r.at!.totalExaminees, 3);
    });
  });

  group('Batch filtering', () {
    setUp(() {
      client.batches
        ..add(_batch('b1', 'AT', day: 2))
        ..add(_batch('b2', 'AT', day: 1))
        ..add(_batch('q1', 'QTM'));
      client.scansByBatch['b1'] = [_scan('1', 'b1', 'AT', 60), _scan('2', 'b1', 'AT', 50)];
      client.scansByBatch['b2'] = [_scan('3', 'b2', 'AT', 70)];
      client.scansByBatch['q1'] = [_scan('4', 'q1', 'QTM', 30)];
    });

    test('All Batches combines every complete batch of the exam type only', () async {
      final r = await run('AT');
      expect(r.at!.totalExaminees, 3);
      expect(r.analyzedBatches.map((b) => b.id).toSet(), {'b1', 'b2'});
      expect(client.scanReads.containsKey('q1'), isFalse);
    });

    test('a specific batch analyzes only that batch', () async {
      final r = await run('AT', batchId: 'b2');
      expect(r.at!.totalExaminees, 1);
      expect(client.scanReads, {'b2': 1});
    });
  });

  group('Cross-batch safety', () {
    test('at most 30 batches per All Batches load; 30 is allowed', () async {
      for (var i = 0; i < 30; i++) {
        client.batches.add(_batch('b$i', 'AT', day: (i % 28) + 1));
        client.scansByBatch['b$i'] = [_scan('s$i', 'b$i', 'AT', 60)];
      }
      final r = await run('AT');
      expect(r.analyzedBatches, hasLength(30));
    });

    test('more than 30 matching batches: nothing is loaded and a narrowing error is raised', () async {
      for (var i = 0; i < 31; i++) {
        client.batches.add(_batch('b$i', 'AT', day: (i % 28) + 1));
        client.scansByBatch['b$i'] = [_scan('s$i', 'b$i', 'AT', 60)];
      }
      await expectLater(
        run('AT'),
        throwsA(isA<AnalyticsTooManyBatchesException>()
            .having((e) => e.count, 'count', 31)
            .having((e) => e.message, 'message', contains('narrow'))),
      );
      expect(client.scanReads, isEmpty); // not "the first 30"
      expect(client.calls.where((c) => c == 'readScanCounts'), isEmpty);
    });

    test('a specific batch is allowed even when many batches exist', () async {
      for (var i = 0; i < 40; i++) {
        client.batches.add(_batch('b$i', 'AT', day: (i % 28) + 1));
        client.scansByBatch['b$i'] = [_scan('s$i', 'b$i', 'AT', 60)];
      }
      final r = await run('AT', batchId: 'b7');
      expect(r.analyzedBatches.single.id, 'b7');
    });

    test('never more than 4 scan requests in flight, and the limit is actually used', () async {
      for (var i = 0; i < 12; i++) {
        client.batches.add(_batch('b$i', 'AT', day: (i % 28) + 1));
        client.scansByBatch['b$i'] = [_scan('s$i', 'b$i', 'AT', 60)];
      }
      await run('AT');
      expect(client.maxInFlight, lessThanOrEqualTo(4));
      expect(client.maxInFlight, 4);
    });

    test('a scan-count mismatch marks the batch incomplete and excludes it from every aggregate', () async {
      client.batches
        ..add(_batch('good', 'AT', day: 2))
        ..add(_batch('bad', 'AT', day: 1));
      client.scansByBatch['good'] = [_scan('1', 'good', 'AT', 60), _scan('2', 'good', 'AT', 50)];
      client.scansByBatch['bad'] = [for (var i = 0; i < 1000; i++) _scan('x$i', 'bad', 'AT', 70)];
      client.countsOverride['bad'] = 1250;

      final r = await run('AT');
      expect(r.at!.totalExaminees, 2); // only the complete batch
      expect(r.analyzedBatches.map((b) => b.id), ['good']);
      expect(r.incompleteBatches, hasLength(1));
      expect(r.incompleteBatches.single.batch.id, 'bad');
      expect(r.incompleteBatches.single.expectedScans, 1250);
      expect(r.incompleteBatches.single.retrievedScans, 1000);
    });

    test('selecting an incomplete batch yields no aggregate results at all', () async {
      client.batches.add(_batch('bad', 'AT'));
      client.scansByBatch['bad'] = [_scan('1', 'bad', 'AT', 60)];
      client.countsOverride['bad'] = 5;
      final r = await run('AT', batchId: 'bad');
      expect(r.hasData, isFalse);
      expect(r.at, isNull);
      expect(r.incompleteBatches, hasLength(1));
    });
  });

  group('Scan cache', () {
    setUp(() {
      client.batches
        ..add(_batch('cur', 'AT', day: 2))
        ..add(_batch('arc', 'AT', day: 1));
      client.archivedIds.add('arc');
      client.scansByBatch['cur'] = [_scan('1', 'cur', 'AT', 60)];
      client.scansByBatch['arc'] = [_scan('2', 'arc', 'AT', 60)];
    });

    test('changing filters reuses already-loaded batches', () async {
      final catalog = await service.loadCatalog();
      await service.analyze(catalog: catalog, examCode: 'AT', status: AnalyticsBatchStatus.all);
      expect(client.scanReads, {'cur': 1, 'arc': 1});
      await service.analyze(catalog: catalog, examCode: 'AT', status: AnalyticsBatchStatus.current);
      await service.analyze(catalog: catalog, examCode: 'AT', status: AnalyticsBatchStatus.archived);
      expect(client.scanReads, {'cur': 1, 'arc': 1}); // no refetch
    });

    test('clearCache forces a fresh read', () async {
      final catalog = await service.loadCatalog();
      await service.analyze(catalog: catalog, examCode: 'AT', status: AnalyticsBatchStatus.all);
      service.clearCache();
      await service.analyze(catalog: catalog, examCode: 'AT', status: AnalyticsBatchStatus.all);
      expect(client.scanReads, {'cur': 2, 'arc': 2});
    });
  });

  group('Read-only', () {
    test('a full TAT + AT + QTM session performs only the allowed reads', () async {
      client.batches
        ..add(_batch('t1', 'TAT'))
        ..add(_batch('a1', 'AT'))
        ..add(_batch('q1', 'QTM'));
      client.scansByBatch['t1'] = [_scan('1', 't1', 'TAT', 90, decoded: _tatDecoded(20, 60, 15))];
      client.scansByBatch['a1'] = [_scan('2', 'a1', 'AT', 60)];
      client.scansByBatch['q1'] = [_scan('3', 'q1', 'QTM', 20)];
      client.keyRead = _foundKey(_completeKeyAnswers());
      for (final exam in ['TAT', 'AT', 'QTM']) {
        await run(exam);
      }
      expect(client.forbidden, isEmpty);
      const allowed = {'readCloudBatches', 'readBatchArchives', 'readScanCounts', 'readCloudScans', 'readAnswerKey'};
      for (final call in client.calls) {
        expect(allowed, contains(call.split(':').first), reason: call);
      }
    });

    test('the analytics service and view contain no write, archive, or restore calls', () {
      for (final path in [
        'lib/features/guidance_web/services/guidance_web_analytics_service.dart',
        'lib/features/guidance_web/screens/guidance_web_analytics_view.dart',
      ]) {
        final code = File(path)
            .readAsLinesSync()
            .where((l) => !l.trimLeft().startsWith('//'))
            .join('\n');
        for (final forbidden in [
          '.pushBatch(',
          '.pushScan(',
          '.archiveBatch(',
          '.unlinkScanFromExaminee(',
          '.linkScanToExaminee(',
          '.deleteBatch(',
          '.insert(',
          '.update(',
          '.upsert(',
          '.delete(',
        ]) {
          expect(code, isNot(contains(forbidden)), reason: '$path contains $forbidden');
        }
      }
    });
  });

  group('Analytics view', () {
    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1700, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: GuidanceWebAnalyticsView(service: service)),
      ));
    }

    Future<void> chooseExam(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const Key('examTypeFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    Future<void> chooseStatus(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const Key('batchStatusFilter')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    void seedTatView({bool drift = false}) {
      client.batches.add(_batch('t1', 'TAT'));
      client.scansByBatch['t1'] = [
        _scan('a', 't1', 'TAT', drift ? 92 : 90, decoded: _tatDecoded(20, 60, 15)),
        _scan('b', 't1', 'TAT', 40, decoded: _tatDecoded(10, 50, 10)),
      ];
    }

    testWidgets('loading state, then AT results', (tester) async {
      client.batches.add(_batch('a1', 'AT'));
      client.scansByBatch['a1'] = [_scan('1', 'a1', 'AT', 60), _scan('2', 'a1', 'AT', 50)];
      await pump(tester);
      expect(find.text('Loading Analytics...'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(find.text('Overall Statistics'), findsOneWidget);
      expect(find.text('Score Distribution'), findsOneWidget);
      expect(find.text('Category Distribution'), findsOneWidget);
      expect(find.text('TOTAL'), findsOneWidget);
      expect(find.text('MEDIAN'), findsOneWidget);
      expect(client.keyReads, isEmpty);
    });

    testWidgets('empty state when no batch matches', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('No batches match the selected filters.'), findsOneWidget);
    });

    testWidgets('error state when batches cannot be read', (tester) async {
      client.batchReadFails = true;
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('Could not load Analytics data. Please try again.'), findsOneWidget);
    });

    testWidgets('TAT with a complete key: provenance once, per-test analysis, strongest/weakest', (tester) async {
      seedTatView();
      client.keyRead = _foundKey(_completeKeyAnswers());
      await pump(tester);
      await tester.pumpAndSettle();
      await chooseExam(tester, 'Teaching Aptitude Test (TAT)');

      expect(find.text('Overall Statistics (recorded scores)'), findsOneWidget);
      expect(find.text('Detailed TAT Analysis'), findsOneWidget);
      expect(find.text('Version: 12'), findsOneWidget);
      expect(find.text('Updated: September 19, 2026'), findsOneWidget);
      expect(find.text('Updated by: Ms. Cruz'), findsOneWidget);
      expect(find.textContaining('Strongest test: Test 1'), findsOneWidget);
      expect(find.textContaining('Weakest test: Test 3'), findsOneWidget);
      expect(find.byKey(const Key('tatDriftWarning')), findsNothing);
      expect(client.keyReads['TAT'], 1);
    });

    testWidgets('TAT drift shows the warning with recorded and current-key totals', (tester) async {
      seedTatView(drift: true);
      client.keyRead = _foundKey(_completeKeyAnswers());
      await pump(tester);
      await tester.pumpAndSettle();
      await chooseExam(tester, 'Teaching Aptitude Test (TAT)');

      expect(find.byKey(const Key('tatDriftWarning')), findsOneWidget);
      expect(find.textContaining('recorded score remains authoritative'), findsOneWidget);
      expect(find.textContaining('Recorded total: 92'), findsOneWidget);
      expect(find.textContaining('Current-key total: 90'), findsOneWidget);
    });

    testWidgets('TAT with a missing key: overall available, detail unavailable', (tester) async {
      seedTatView();
      await pump(tester);
      await tester.pumpAndSettle();
      await chooseExam(tester, 'Teaching Aptitude Test (TAT)');

      expect(find.text('Overall Statistics (recorded scores)'), findsOneWidget);
      expect(find.text('⚠ Unavailable — Answer Key is not available.'), findsOneWidget);
      expect(find.textContaining('Strongest test'), findsNothing);
    });

    testWidgets('TAT with an incomplete key: overall available, detail unavailable, provenance shown', (tester) async {
      seedTatView();
      client.keyRead = _foundKey(_completeKeyAnswers()..remove(_completeKeyAnswers().keys.first));
      await pump(tester);
      await tester.pumpAndSettle();
      await chooseExam(tester, 'Teaching Aptitude Test (TAT)');

      expect(find.text('Overall Statistics (recorded scores)'), findsOneWidget);
      expect(find.text('⚠ Unavailable — Answer Key appears incomplete.'), findsOneWidget);
      expect(find.textContaining('Strongest test'), findsNothing);
      expect(find.text('Version: 12'), findsOneWidget);
    });

    testWidgets('archive filtering: Archived shows only Web-archived batches', (tester) async {
      client.batches
        ..add(_batch('arc', 'AT', day: 2))
        ..add(_batch('cur', 'AT', day: 1));
      client.archivedIds.add('arc');
      client.scansByBatch['arc'] = [_scan('1', 'arc', 'AT', 60)];
      client.scansByBatch['cur'] = [_scan('2', 'cur', 'AT', 60), _scan('3', 'cur', 'AT', 50)];
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('Analyzing 2 batches'), findsOneWidget);

      await chooseStatus(tester, 'Archived');
      expect(find.text('Analyzing 1 batch'), findsOneWidget);
      await chooseStatus(tester, 'Current');
      expect(find.text('Analyzing 1 batch'), findsOneWidget);
    });

    testWidgets('archive marker failure: notice shown, All still analyzes, no page failure', (tester) async {
      client.archiveReadFails = true;
      client.batches.add(_batch('a1', 'AT'));
      client.scansByBatch['a1'] = [_scan('1', 'a1', 'AT', 60)];
      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('archiveUnavailableNotice')), findsOneWidget);
      expect(find.text('Overall Statistics'), findsOneWidget);
    });

    testWidgets('more than 30 matching batches shows the narrowing message and loads nothing', (tester) async {
      for (var i = 0; i < 31; i++) {
        client.batches.add(_batch('b$i', 'AT', day: (i % 28) + 1));
        client.scansByBatch['b$i'] = [_scan('s$i', 'b$i', 'AT', 60)];
      }
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('narrowMessage')), findsOneWidget);
      expect(find.textContaining('narrow the selection'), findsOneWidget);
      expect(client.scanReads, isEmpty);
    });

    testWidgets('an incomplete batch is warned about with its counts and excluded', (tester) async {
      client.batches
        ..add(_batch('good', 'AT', day: 2))
        ..add(_batch('bad', 'AT', day: 1));
      client.scansByBatch['good'] = [_scan('1', 'good', 'AT', 60)];
      client.scansByBatch['bad'] = [for (var i = 0; i < 3; i++) _scan('x$i', 'bad', 'AT', 70)];
      client.countsOverride['bad'] = 1250;
      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('incompleteBatchWarning')), findsOneWidget);
      expect(find.textContaining('CODE-bad: expected 1,250 scans, retrieved 3'), findsOneWidget);
      expect(find.text('Analyzing 1 batch'), findsOneWidget);
    });

    testWidgets('an incomplete specific batch shows the warning and no misleading statistics', (tester) async {
      client.batches.add(_batch('bad', 'AT'));
      client.scansByBatch['bad'] = [_scan('1', 'bad', 'AT', 60)];
      client.countsOverride['bad'] = 5;
      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('incompleteBatchWarning')), findsOneWidget);
      expect(find.byKey(const Key('noCompleteData')), findsOneWidget);
      expect(find.text('Overall Statistics'), findsNothing);
    });

    testWidgets('a batch whose only attempt is archived shows the archived-only message, not zero statistics',
        (tester) async {
      client.batches.add(_batch('b1', 'AT'));
      client.scansByBatch['b1'] = [_scan('s-old', 'b1', 'AT', 50, attemptNo: 1, attemptStatus: 'archived')];
      await pump(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('allAttemptsArchived')), findsOneWidget);
      expect(
        find.text('All examination attempts in this batch are archived. No active attempts to analyze.'),
        findsOneWidget,
      );
      expect(find.text('Overall Statistics'), findsNothing);
      expect(find.text('Total'), findsNothing);
      // Not the "no complete batch data" message either -- the batch WAS
      // fully retrieved, it's simply all-archived.
      expect(find.byKey(const Key('noCompleteData')), findsNothing);
      expect(find.byKey(const Key('incompleteBatchWarning')), findsNothing);
    });

    testWidgets('the refresh action clears the cache and re-reads', (tester) async {
      client.batches.add(_batch('a1', 'AT'));
      client.scansByBatch['a1'] = [_scan('1', 'a1', 'AT', 60)];
      await pump(tester);
      await tester.pumpAndSettle();
      expect(client.scanReads['a1'], 1);

      await tester.tap(find.byKey(const Key('analyticsRefresh')));
      await tester.pumpAndSettle();
      expect(client.scanReads['a1'], 2);
    });

    testWidgets('the whole page performs no write operation', (tester) async {
      seedTatView();
      client.keyRead = _foundKey(_completeKeyAnswers());
      await pump(tester);
      await tester.pumpAndSettle();
      await chooseExam(tester, 'Teaching Aptitude Test (TAT)');
      await chooseStatus(tester, 'Archived');
      expect(client.forbidden, isEmpty);
    });
  });

  test('QTM percentage helper follows the existing rule', () {
    expect(GuidanceWebAnalyticsService.qtmPercentOf(30), qtmPercentage(30));
    expect(GuidanceWebAnalyticsService.qtmPercentOf(null), isNull);
  });

group('Applicant Retake Management -- archived attempts excluded by default', () {
  test('AT: an archived Attempt 1 is excluded from the aggregate, the active Attempt 2 is included', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s-old', 'b1', 'AT', 50, attemptNo: 1, attemptStatus: 'archived'),
      _scan('s-new', 'b1', 'AT', 65, attemptNo: 2, attemptStatus: 'active'),
    ];

    final r = await run('AT');

    expect(r.at!.totalExaminees, 1);
    expect(r.at!.averageRawScore, 65);
  });

  test('AT: the batch is still marked complete -- archiving an attempt never looks like a missing scan', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [
      _scan('s-old', 'b1', 'AT', 50, attemptNo: 1, attemptStatus: 'archived'),
      _scan('s-new', 'b1', 'AT', 65, attemptNo: 2, attemptStatus: 'active'),
    ];

    final r = await run('AT');

    expect(r.incompleteBatches, isEmpty);
    expect(r.analyzedBatches.map((b) => b.id), ['b1']);
  });

  test('TAT: an archived Attempt 1 is excluded from the overall stats', () async {
    client.batches.add(_batch('t1', 'TAT'));
    client.scansByBatch['t1'] = [
      _scan('s-old', 't1', 'TAT', 40, attemptNo: 1, attemptStatus: 'archived'),
      _scan('s-new', 't1', 'TAT', 150, attemptNo: 2, attemptStatus: 'active'),
    ];

    final o = (await run('TAT')).tatOverall!;

    expect(o.totalExaminees, 1);
    expect(o.averageTotal, 150);
  });

  test('an applicant with only Attempt 1 (no retake) is unchanged', () async {
    client.batches.add(_batch('b1', 'AT'));
    client.scansByBatch['b1'] = [_scan('s1', 'b1', 'AT', 60)]; // default: attempt 1, active

    final r = await run('AT');

    expect(r.at!.totalExaminees, 1);
    expect(r.at!.averageRawScore, 60);
  });

  test('QTM is unchanged for an ordinary batch (no retake activity at all)', () async {
    client.batches.add(_batch('q1', 'QTM'));
    client.scansByBatch['q1'] = [
      _scan('1', 'q1', 'QTM', 10),
      _scan('2', 'q1', 'QTM', 20),
    ];

    final q = (await run('QTM')).qtm!;

    expect(q.totalExaminees, 2);
    expect(q.averageRawScore, 15);
  });

  test('the archived-attempt filter applies uniformly regardless of exam code', () async {
    client.batches.add(_batch('q1', 'QTM'));
    client.scansByBatch['q1'] = [
      _scan('1', 'q1', 'QTM', 10, attemptNo: 1, attemptStatus: 'archived'),
      _scan('2', 'q1', 'QTM', 20),
    ];

    final q = (await run('QTM')).qtm!;

    expect(q.totalExaminees, 1);
    expect(q.averageRawScore, 20);
  });

  group('archived-only batch (physically complete, nothing active)', () {
    test('AT: recognized -- completeness stays true, but at/qtm/tatOverall stay null', () async {
      client.batches.add(_batch('b1', 'AT', day: 1));
      client.scansByBatch['b1'] = [
        _scan('s-old', 'b1', 'AT', 50, attemptNo: 1, attemptStatus: 'archived'),
      ];

      final r = await run('AT');

      // Completeness still uses the physical scan count -- this batch was
      // fully retrieved (1 expected, 1 retrieved), so it is NOT reported as
      // incomplete even though nothing in it is active.
      expect(r.incompleteBatches, isEmpty);
      expect(r.analyzedBatches.map((b) => b.id), ['b1']);
      expect(r.allActiveAttemptsArchived, isTrue);
      // Archived scans never reach the pure AT/QTM/TAT calculators: no
      // all-zero result is fabricated for them to report on.
      expect(r.at, isNull);
      expect(r.qtm, isNull);
      expect(r.tatOverall, isNull);
      expect(r.tatDetail, isNull);
    });

    test('TAT: recognized the same way', () async {
      client.batches.add(_batch('t1', 'TAT', day: 1));
      client.scansByBatch['t1'] = [
        _scan('s-old', 't1', 'TAT', 40, attemptNo: 1, attemptStatus: 'archived'),
      ];

      final r = await run('TAT');

      expect(r.incompleteBatches, isEmpty);
      expect(r.allActiveAttemptsArchived, isTrue);
      expect(r.tatOverall, isNull);
      expect(r.tatDetail, isNull);
    });

    test('a batch with at least one active scan is never reported archived-only', () async {
      client.batches.add(_batch('b1', 'AT', day: 1));
      client.scansByBatch['b1'] = [
        _scan('s-old', 'b1', 'AT', 50, attemptNo: 1, attemptStatus: 'archived'),
        _scan('s-new', 'b1', 'AT', 65, attemptNo: 2, attemptStatus: 'active'),
      ];

      final r = await run('AT');

      expect(r.allActiveAttemptsArchived, isFalse);
      expect(r.at, isNotNull);
    });

    test('an ordinary batch with no retake activity is never reported archived-only', () async {
      client.batches.add(_batch('b1', 'AT', day: 1));
      client.scansByBatch['b1'] = [_scan('s1', 'b1', 'AT', 60)];

      final r = await run('AT');

      expect(r.allActiveAttemptsArchived, isFalse);
      expect(r.at, isNotNull);
    });

    test('an incomplete batch (not fully synced) is never reported archived-only', () async {
      client.batches.add(_batch('b1', 'AT', day: 1));
      client.scansByBatch['b1'] = [
        _scan('s-old', 'b1', 'AT', 50, attemptNo: 1, attemptStatus: 'archived'),
      ];
      client.countsOverride['b1'] = 5; // server reports 5 expected, only 1 retrieved

      final r = await run('AT');

      expect(r.incompleteBatches, hasLength(1));
      expect(r.allActiveAttemptsArchived, isFalse);
    });
  });
});

}
