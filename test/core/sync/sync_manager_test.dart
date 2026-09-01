import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_job.dart';
import 'package:guidegrade/core/sync/sync_manager.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/core/sync/sync_queue.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

/// Deterministic, mutable clock.
class _FakeClock {
  _FakeClock(this._now);
  DateTime _now;
  DateTime call() => _now.toUtc();
  void advance(Duration d) => _now = _now.add(d);
}

/// Records every dispatch and returns a configurable [SyncOutcome]
/// (per call label, else success). An optional [gate] lets a test hold a
/// job mid-flight.
class _FakeSyncClient implements SyncClient {
  final List<String> calls = [];
  final Map<String, SyncOutcome> outcomeByLabel = {};
  Completer<void>? gate;

  /// The `meta` map handed to the most recent `pushScan` call.
  Map<String, String>? lastPushScanMeta;

  /// The `meta` map handed to the most recent `pushAnswerKey` call.
  Map<String, String>? lastPushAnswerKeyMeta;

  Future<SyncOutcome> _run(String label) async {
    calls.add(label);
    final g = gate;
    if (g != null) await g.future;
    return outcomeByLabel[label] ?? const SyncOutcome.success();
  }

  @override
  Future<SyncOutcome> pushBatch(String batchId) => _run('pushBatch:$batchId');

  @override
  Future<SyncOutcome> pushScan(String batchId, String scanId,
      {Map<String, String> meta = const {}}) {
    lastPushScanMeta = meta;
    return _run('pushScan:$batchId/$scanId');
  }

  @override
  Future<SyncOutcome> uploadImage(SyncJob job) =>
      _run('uploadImage:${job.batchId}/${job.scanId}/${job.meta['variant']}');

  @override
  Future<SyncOutcome> patchImageStatus(String batchId, String scanId) =>
      _run('patchImageStatus:$batchId/$scanId');

  @override
  Future<SyncOutcome> pushAnswerKey(String examCode,
      {Map<String, String> meta = const {}}) {
    lastPushAnswerKeyMeta = meta;
    return _run('pushAnswerKey:$examCode');
  }

  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async {
    calls.add('readAnswerKey:$examCode');
    return const CloudAnswerKeyRead.absent();
  }

  @override
  Future<SyncOutcome> deleteBatch(String batchId) =>
      _run('deleteBatch:$batchId');

  @override
  Future<SyncOutcome> deleteStoragePrefix(String batchId) =>
      _run('deleteStoragePrefix:$batchId');
}

void main() {
  late Directory tempDir;
  late _FakeClock fakeClock;
  late SyncQueue queue;
  late LocalBatchRepository batchRepo;
  late _FakeSyncClient client;
  late Map<String, AnswerKey> answerKeys;
  late SyncManager manager;

  DateTime clock() => fakeClock.call();

  /// Waits (bounded) until the fake client has recorded at least [n] calls,
  /// so gate-based tests do not depend on exact event-loop pump counts.
  Future<void> waitForCalls(int n) async {
    for (var i = 0; i < 400 && client.calls.length < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  SyncJob newJob(
    SyncJobType type, {
    String? batchId,
    String? scanId,
    String? entityId,
    String? variant,
  }) =>
      SyncJob.create(
        type: type,
        entityId: entityId ?? batchId ?? scanId ?? 'e',
        batchId: batchId,
        scanId: scanId,
        meta: variant == null ? const {} : {'variant': variant},
        now: clock(),
      );

  Future<LocalBatch> seedBatch({int scans = 0}) async {
    final created = await batchRepo.createBatch(
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Aptitude',
      description: 'd',
      expectedCount: 100,
      createdByUid: 'uid',
      createdByName: 'Officer',
    );
    var current = created;
    for (var i = 0; i < scans; i++) {
      final src = File('${tempDir.path}/src_${created.id}_$i.jpg')
        ..writeAsBytesSync(const [1, 2, 3]);
      current = await batchRepo.addScan(
        batchId: created.id,
        decoded: const OmrScanResult(examCode: 'AT', items: []),
        sourceImage: src,
      );
    }
    return current;
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sync_mgr_test_');
    fakeClock = _FakeClock(DateTime.utc(2026, 1, 1, 12));
    queue = SyncQueue(
      rootOverride: Directory('${tempDir.path}/queue'),
      clock: () => fakeClock.call(),
    );
    batchRepo = LocalBatchRepository(
      rootOverride: Directory('${tempDir.path}/batches'),
    );
    client = _FakeSyncClient();
    answerKeys = {};
    manager = SyncManager(
      queue: queue,
      client: client,
      batchRepository: batchRepo,
      loadAnswerKeys: () async => answerKeys,
      clock: () => fakeClock.call(),
      jitter: () => 1.0,
    );
  });

  tearDown(() async {
    // Release any held gate so an in-flight drain can unwind cleanly.
    final gate = client.gate;
    if (gate != null && !gate.isCompleted) gate.complete();
    manager.dispose();
    await pumpEventQueue();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {
      // Windows may briefly hold a handle from the just-finished drain;
      // the OS reclaims the temp dir later.
    }
  });

  test('1. restore resets a surviving inProgress job to pending', () async {
    final job = await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.update(job!.copyWith(status: SyncJobStatus.inProgress));
    expect(queue.byStatus(SyncJobStatus.inProgress), hasLength(1));

    await manager.restore();

    expect(queue.byStatus(SyncJobStatus.inProgress), isEmpty);
    expect(queue.byStatus(SyncJobStatus.pending), hasLength(1));
  });

  test('2. startup reconcile creates a missing PUSH_BATCH', () async {
    final batch = await seedBatch();
    await manager.restore();

    expect(
      queue.jobs.map((j) => j.dedupeKey),
      contains('PUSH_BATCH:${batch.id}'),
    );
    expect(
      queue.jobs.where((j) => j.type == SyncJobType.pushBatch),
      hasLength(1),
    );
  });

  test('3. startup reconcile creates a missing PUSH_SCAN', () async {
    final batch = await seedBatch(scans: 1);
    final scanId = batch.scans.single.id;

    await manager.restore();

    expect(
      queue.jobs.map((j) => j.dedupeKey),
      contains('PUSH_SCAN:${batch.id}:$scanId'),
    );
  });

  test('4. reconcile does not create duplicate pending jobs', () async {
    final batch = await seedBatch();

    await manager.restore();
    final first =
        queue.jobs.where((j) => j.dedupeKey == 'PUSH_BATCH:${batch.id}').length;
    await manager.restore();
    final second =
        queue.jobs.where((j) => j.dedupeKey == 'PUSH_BATCH:${batch.id}').length;

    expect(first, 1);
    expect(second, 1);
  });

  test('5. jobs execute serially (no overlap)', () async {
    client.gate = Completer<void>();
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b2'));
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b3'));

    final draining = manager.start();
    await waitForCalls(1);
    expect(client.calls, ['pushBatch:b1']); // only the first has started

    client.gate!.complete();
    await draining;
    expect(client.calls, ['pushBatch:b1', 'pushBatch:b2', 'pushBatch:b3']);
  });

  test('6. each job type dispatches to the matching client method', () async {
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.enqueue(
        newJob(SyncJobType.pushScan, batchId: 'b1', scanId: 's1'));
    await queue.enqueue(newJob(SyncJobType.uploadImage,
        batchId: 'b1', scanId: 's1', variant: 'original'));
    await queue.enqueue(
        newJob(SyncJobType.patchImageStatus, batchId: 'b1', scanId: 's1'));
    await queue.enqueue(newJob(SyncJobType.pushAnswerKey, entityId: 'AT'));
    await queue.enqueue(newJob(SyncJobType.deleteBatch, batchId: 'b2'));
    await queue.enqueue(newJob(SyncJobType.deleteStoragePrefix, batchId: 'b2'));

    await manager.start();

    expect(
      client.calls,
      containsAll(<String>[
        'pushBatch:b1',
        'pushScan:b1/s1',
        'uploadImage:b1/s1/original',
        'patchImageStatus:b1/s1',
        'pushAnswerKey:AT',
        'deleteBatch:b2',
        'deleteStoragePrefix:b2',
      ]),
    );
    expect(queue.jobs, isEmpty);
  });

  test('7. a successful job is removed from the queue', () async {
    final job = await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await manager.start();

    expect(queue.jobById(job!.id), isNull);
    expect(queue.jobs, isEmpty);
  });

  test('8. transient failure increments attempts and schedules backoff',
      () async {
    client.outcomeByLabel['pushBatch:b1'] =
        const SyncOutcome.transient('network');
    final job = await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    final base = clock();

    await manager.start();

    final updated = queue.jobById(job!.id)!;
    expect(updated.status, SyncJobStatus.pending);
    expect(updated.attempts, 1);
    expect(updated.lastErrorCode, 'network');
    // jitter = 1.0, BASE = 5s, attempt 1 -> exactly 5s
    expect(updated.nextAttemptAt, base.add(const Duration(seconds: 5)));
    expect(client.calls, ['pushBatch:b1']); // not retried in the same pass
  });

  test('8b. backoff grows exponentially and is capped at 15 min', () async {
    client.outcomeByLabel['pushBatch:b1'] =
        const SyncOutcome.transient('network');
    final job = await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));

    // attempt 1 -> 5s
    await manager.start();
    var updated = queue.jobById(job!.id)!;
    expect(updated.nextAttemptAt.difference(clock()), const Duration(seconds: 5));

    // attempt 4 -> 5s * 2^3 = 40s
    await queue.update(updated.copyWith(attempts: 3, nextAttemptAt: clock()));
    await manager.syncNow();
    updated = queue.jobById(job.id)!;
    expect(updated.attempts, 4);
    expect(
        updated.nextAttemptAt.difference(clock()), const Duration(seconds: 40));

    // attempt 20 -> capped at 15 min
    await queue.update(updated.copyWith(attempts: 19, nextAttemptAt: clock()));
    await manager.syncNow();
    updated = queue.jobById(job.id)!;
    expect(updated.nextAttemptAt.difference(clock()),
        const Duration(minutes: 15));
  });

  test('9. permanent failure marks the job failedPermanent', () async {
    client.outcomeByLabel['pushBatch:b1'] =
        const SyncOutcome.permanent('42501');
    final job = await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));

    await manager.start();

    final updated = queue.jobById(job!.id)!;
    expect(updated.status, SyncJobStatus.failedPermanent);
    expect(updated.lastErrorCode, '42501');
    expect(updated.attempts, 0);
  });

  test('10. conflict marks the job blockedConflict', () async {
    client.outcomeByLabel['pushAnswerKey:AT'] =
        const SyncOutcome.conflict('answer_key_changed');
    final job =
        await queue.enqueue(newJob(SyncJobType.pushAnswerKey, entityId: 'AT'));

    await manager.start();

    final updated = queue.jobById(job!.id)!;
    expect(updated.status, SyncJobStatus.blockedConflict);
    expect(updated.lastErrorCode, 'answer_key_changed');
  });

  test('11. syncNow re-times future pending jobs to now and drains them',
      () async {
    await manager.start(); // active, queue empty
    final job = await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.update(
        job!.copyWith(nextAttemptAt: clock().add(const Duration(hours: 1))));

    await manager.processQueue();
    expect(client.calls, isEmpty); // not due yet

    await manager.syncNow();
    expect(client.calls, ['pushBatch:b1']);
    expect(queue.jobs, isEmpty);
  });

  test('12. syncNow does not revive a failedPermanent job', () async {
    await manager.start();
    final job = await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.update(job!.copyWith(
      status: SyncJobStatus.failedPermanent,
      lastErrorCode: '42501',
    ));

    await manager.syncNow();

    expect(queue.jobById(job.id)!.status, SyncJobStatus.failedPermanent);
    expect(client.calls, isEmpty);
  });

  test('13. syncNow does not revive a blockedConflict job', () async {
    await manager.start();
    final job =
        await queue.enqueue(newJob(SyncJobType.pushAnswerKey, entityId: 'AT'));
    await queue.update(job!.copyWith(
      status: SyncJobStatus.blockedConflict,
      lastErrorCode: 'answer_key_changed',
    ));

    await manager.syncNow();

    expect(queue.jobById(job.id)!.status, SyncJobStatus.blockedConflict);
    expect(client.calls, isEmpty);
  });

  test('14. pause stops the drain from starting further jobs', () async {
    client.gate = Completer<void>();
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b2'));

    final draining = manager.start();
    await waitForCalls(1);
    expect(client.calls, ['pushBatch:b1']);

    manager.pause();
    client.gate!.complete();
    await draining;

    expect(client.calls, ['pushBatch:b1']); // b2 never started
    expect(manager.pendingCount, 1); // b2 still pending
  });

  test('15. reconcile enqueues DELETE_BATCH before DELETE_STORAGE_PREFIX',
      () async {
    queue.state.setBatchPushed('orphan', clock());
    await queue.saveState();

    await manager.restore();

    final deleteTypes = queue.jobs
        .where((j) =>
            j.type == SyncJobType.deleteBatch ||
            j.type == SyncJobType.deleteStoragePrefix)
        .map((j) => j.type)
        .toList();
    expect(deleteTypes,
        [SyncJobType.deleteBatch, SyncJobType.deleteStoragePrefix]);

    await manager.start();
    expect(client.calls, ['deleteBatch:orphan', 'deleteStoragePrefix:orphan']);
  });

  test('16. PUSH_BATCH runs before PUSH_SCAN for the same batch', () async {
    final batch = await seedBatch(scans: 1);
    final scanId = batch.scans.single.id;

    await manager.restore();
    await manager.start();

    expect(client.calls.take(4).toList(), [
      'pushBatch:${batch.id}',
      'pushScan:${batch.id}/$scanId',
      'uploadImage:${batch.id}/$scanId/original',
      'patchImageStatus:${batch.id}/$scanId',
    ]);
  });

  test('17. a failedPermanent job for one batch does not block another',
      () async {
    client.outcomeByLabel['pushBatch:b1'] =
        const SyncOutcome.permanent('42501');
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b2'));

    await manager.start();

    expect(client.calls, ['pushBatch:b1', 'pushBatch:b2']);
    expect(
      queue.byStatus(SyncJobStatus.failedPermanent).map((j) => j.batchId),
      ['b1'],
    );
    expect(queue.jobs.where((j) => j.batchId == 'b2'), isEmpty);
  });

  test('18. a second processQueue call is a no-op while one is running',
      () async {
    client.gate = Completer<void>();
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b2'));

    final first = manager.start();
    await waitForCalls(1);
    expect(client.calls, ['pushBatch:b1']);
    expect(manager.isRunning, isTrue);

    await manager.processQueue(); // must return immediately, no work
    expect(client.calls, ['pushBatch:b1']);

    client.gate!.complete();
    await first;
    expect(client.calls, ['pushBatch:b1', 'pushBatch:b2']); // each exactly once
  });

  test('19. a failedPermanent job does not block newer pending work in the '
      'same batch', () async {
    final oldJob = await queue
        .enqueue(newJob(SyncJobType.pushScan, batchId: 'b1', scanId: 's1'));
    await queue.update(oldJob!.copyWith(
      status: SyncJobStatus.failedPermanent,
      lastErrorCode: '42501',
    ));
    await queue
        .enqueue(newJob(SyncJobType.pushScan, batchId: 'b1', scanId: 's2'));

    await manager.start();

    expect(client.calls, ['pushScan:b1/s2']);
    expect(queue.jobById(oldJob.id)!.status, SyncJobStatus.failedPermanent);
    expect(
      queue.jobs.where((j) => j.dedupeKey == 'PUSH_SCAN:b1:s2'),
      isEmpty, // newer job ran and was removed
    );
  });

  test('20. a blockedConflict answer-key job does not block a different '
      'examCode', () async {
    final blocked = await queue
        .enqueue(newJob(SyncJobType.pushAnswerKey, entityId: 'AT'));
    await queue.update(blocked!.copyWith(
      status: SyncJobStatus.blockedConflict,
      lastErrorCode: 'answer_key_changed',
    ));
    await queue.enqueue(newJob(SyncJobType.pushAnswerKey, entityId: 'QTM'));

    await manager.start();

    expect(client.calls, ['pushAnswerKey:QTM']);
    expect(queue.jobById(blocked.id)!.status, SyncJobStatus.blockedConflict);
  });

  test('21. an older backing-off job still blocks a newer dependent job in '
      'the same batch', () async {
    final batchJob =
        await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.update(batchJob!.copyWith(
      attempts: 1,
      nextAttemptAt: clock().add(const Duration(minutes: 5)),
    ));
    await queue
        .enqueue(newJob(SyncJobType.pushScan, batchId: 'b1', scanId: 's1'));

    await manager.start();

    expect(client.calls, isEmpty); // scan waits for the backing-off batch push
    expect(manager.pendingCount, 2);
  });

  // --- wake() (Phase 9B-7B) -----------------------------------------------

  test('22. wake() while inactive makes no client calls', () async {
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));

    await manager.wake(); // never started -> inactive

    expect(client.calls, isEmpty);
    expect(manager.pendingCount, 1);
  });

  test('23. wake() while active dispatches a job enqueued after start()',
      () async {
    await manager.start(); // active; queue empty -> start()'s pass drains nothing
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    expect(client.calls, isEmpty); // start()'s single pass already finished

    await manager.wake();

    expect(client.calls, ['pushBatch:b1']);
    expect(queue.jobs, isEmpty);
  });

  test('24. wake() while a drain is running does not start a concurrent drain',
      () async {
    client.gate = Completer<void>();
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b2'));

    final draining = manager.start();
    await waitForCalls(1);
    expect(client.calls, ['pushBatch:b1']); // b1 in flight (gated)

    await manager.wake();
    await manager.wake();
    expect(client.calls, ['pushBatch:b1']); // no second processor started

    client.gate!.complete();
    await draining;
    expect(client.calls, ['pushBatch:b1', 'pushBatch:b2']); // each exactly once
  });

  test('25. jobs enqueued after login are processed once wake() is called',
      () async {
    await manager.start(); // login, empty queue
    await queue
        .enqueue(newJob(SyncJobType.pushScan, batchId: 'b1', scanId: 's1'));
    await queue.enqueue(newJob(SyncJobType.uploadImage,
        batchId: 'b1', scanId: 's1', variant: 'original'));

    await manager.wake();

    expect(client.calls, ['pushScan:b1/s1', 'uploadImage:b1/s1/original']);
    expect(queue.jobs, isEmpty);
  });

  test('26. wake() after an empty start() drains the full 5-job scan set',
      () async {
    await manager.start(); // empty
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue
        .enqueue(newJob(SyncJobType.pushScan, batchId: 'b1', scanId: 's1'));
    await queue.enqueue(newJob(SyncJobType.uploadImage,
        batchId: 'b1', scanId: 's1', variant: 'original'));
    await queue.enqueue(newJob(SyncJobType.uploadImage,
        batchId: 'b1', scanId: 's1', variant: 'rectified'));
    await queue
        .enqueue(newJob(SyncJobType.patchImageStatus, batchId: 'b1', scanId: 's1'));

    await manager.wake();

    expect(client.calls, [
      'pushBatch:b1',
      'pushScan:b1/s1',
      'uploadImage:b1/s1/original',
      'uploadImage:b1/s1/rectified',
      'patchImageStatus:b1/s1',
    ]);
    expect(manager.pendingCount, 0);
    expect(queue.jobs, isEmpty);
  });

  test('27. concurrent wake() calls stay serialized (each job dispatched once)',
      () async {
    client.gate = Completer<void>();
    await manager.start(); // active, empty
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b2'));

    final w1 = manager.wake();
    final w2 = manager.wake();
    final w3 = manager.wake();
    await waitForCalls(1);
    expect(client.calls, ['pushBatch:b1']); // b1 gated; b2 not started

    client.gate!.complete();
    await Future.wait([w1, w2, w3]);
    expect(client.calls, ['pushBatch:b1', 'pushBatch:b2']); // no duplicates
    expect(queue.jobs, isEmpty);
  });

  test('28. pause() then wake() does not process jobs', () async {
    await manager.start(); // active
    manager.pause(); // inactive
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));

    await manager.wake();

    expect(client.calls, isEmpty);
    expect(manager.pendingCount, 1);
  });

  test('29. dispose() then wake() does not process jobs and does not throw',
      () async {
    await manager.start(); // active, empty
    await queue.enqueue(newJob(SyncJobType.pushBatch, batchId: 'b1'));
    manager.dispose();

    await manager.wake(); // no-op, must not throw

    expect(client.calls, isEmpty);
  });

  // --- PUSH_SCAN meta forwarding (Phase 9B-7E) --------------------------

  test('30. _dispatch forwards the PUSH_SCAN job meta to the client unchanged',
      () async {
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's1',
      batchId: 'b1',
      scanId: 's1',
      meta: {
        'operation': 'examinee_tag',
        'opAt': '2026-08-31T09:15:00.000Z',
      },
      now: clock(),
    ));

    await manager.start();

    expect(client.calls, ['pushScan:b1/s1']);
    expect(client.lastPushScanMeta, {
      'operation': 'examinee_tag',
      'opAt': '2026-08-31T09:15:00.000Z',
    });
  });

  test('31. SyncJob.meta survives copyWith (retry / backoff / restore)', () {
    final job = SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's1',
      batchId: 'b1',
      scanId: 's1',
      meta: {
        'operation': 'examinee_clear',
        'opAt': '2026-08-31T10:00:00.000Z',
      },
    );

    final retried = job.copyWith(
      status: SyncJobStatus.pending,
      attempts: 3,
      nextAttemptAt: DateTime.utc(2027),
      lastErrorCode: 'network',
    );

    expect(retried.meta, {
      'operation': 'examinee_clear',
      'opAt': '2026-08-31T10:00:00.000Z',
    });
  });

  // --- PUSH_ANSWER_KEY meta forwarding (Phase 10E-1) -------------------

  test('32. _dispatch forwards the PUSH_ANSWER_KEY job meta to pushAnswerKey '
      'unchanged', () async {
    await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushAnswerKey,
      entityId: 'AT',
      meta: {'force': 'true', 'expectedCloudVersion': '3'},
      now: clock(),
    ));

    await manager.start();

    expect(client.calls, ['pushAnswerKey:AT']);
    expect(client.lastPushAnswerKeyMeta,
        {'force': 'true', 'expectedCloudVersion': '3'});
  });

  test('33. a force PUSH_ANSWER_KEY that returns conflict is parked as '
      'blockedConflict with its meta intact and is not retried', () async {
    client.outcomeByLabel['pushAnswerKey:AT'] =
        const SyncOutcome.conflict('answer_key_changed');
    final job = await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushAnswerKey,
      entityId: 'AT',
      meta: {'force': 'true', 'expectedCloudVersion': '3'},
      now: clock(),
    ));

    await manager.start();

    expect(client.calls, ['pushAnswerKey:AT']); // exactly one attempt
    final parked = queue.jobById(job!.id)!;
    expect(parked.status, SyncJobStatus.blockedConflict);
    expect(parked.lastErrorCode, 'answer_key_changed');
    expect(parked.meta, {'force': 'true', 'expectedCloudVersion': '3'});
  });

  test('34. a force PUSH_ANSWER_KEY that succeeds is removed from the queue '
      '(the force job is not sticky)', () async {
    final job = await queue.enqueue(SyncJob.create(
      type: SyncJobType.pushAnswerKey,
      entityId: 'AT',
      meta: {'force': 'true', 'expectedCloudVersion': '3'},
      now: clock(),
    ));

    await manager.start();

    expect(client.calls, ['pushAnswerKey:AT']);
    expect(queue.jobById(job!.id), isNull);
    expect(
      queue.jobs.where((j) => j.type == SyncJobType.pushAnswerKey),
      isEmpty,
    );
  });
}
