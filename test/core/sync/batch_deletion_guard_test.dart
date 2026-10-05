import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/core/sync/completed_batch_status_refresh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/batch_deletion_guard.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';

class _Client implements SyncClient {
  CloudBatchesRead batches = CloudBatchesRead.found(const []);
  CloudBatchArchivesRead archives = CloudBatchArchivesRead.found(const []);
  @override
  Future<CloudBatchesRead> readCloudBatches() async => batches;
  @override
  Future<CloudBatchArchivesRead> readBatchArchives() async => archives;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Repository implements BatchRepository {
  LocalBatch batch = LocalBatch(
    id: 'b',
    batchCode: 'B',
    examCode: 'AT',
    examTitle: 'Admission Test',
    description: 'Local description',
    expectedCount: 10,
    status: 'Archived',
    createdByUid: 'u',
    createdByName: 'User',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
    scans: const [],
  );
  int writes = 0;
  @override
  Future<List<LocalBatch>> getBatches() async => [batch];
  @override
  Future<LocalBatch> upsertBatchFromCloud(LocalBatch incoming) async {
    writes++;
    return batch = incoming;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'Web archive refresh marks existing mobile batch Completed and is idempotent',
    () async {
      final repo = _Repository();
      final client = _Client()
        ..archives = CloudBatchArchivesRead.found([
          CloudBatchArchiveRow(
            batchId: 'b',
            archivedAt: DateTime.utc(2026),
            archivedByUid: 'u',
          ),
          CloudBatchArchiveRow(
            batchId: 'not-on-device',
            archivedAt: DateTime.utc(2026),
            archivedByUid: 'u',
          ),
        ]);
      await refreshCompletedBatchStatuses(repo, client);
      expect(repo.batch.isCompleted, isTrue);
      expect(repo.batch.description, 'Local description');
      await refreshCompletedBatchStatuses(repo, client);
      expect(repo.writes, 1);
    },
  );
  test(
    'offline completion refresh keeps last known status and does not write',
    () async {
      final repo = _Repository();
      final client = _Client()
        ..batches = const CloudBatchesRead.failed(
          SyncOutcome.transient('offline'),
        );
      await refreshCompletedBatchStatuses(repo, client);
      expect(repo.batch.isArchived, isTrue);
      expect(repo.writes, 0);
    },
  );

  for (final status in ['Active', 'Archived', 'Completed']) {
    test(
      '$status follows business completion rather than sync label',
      () async {
        final client = _Client()
          ..batches = CloudBatchesRead.found([
            CloudBatchRow(
              id: 'b',
              batchCode: 'B',
              examCode: 'AT',
              examTitle: 'AT',
              description: '',
              expectedCount: 1,
              status: status,
              createdByUid: 'u',
              createdByName: 'User',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          ]);
        expect(
          (await checkBatchDeletionAllowed(client, 'b')).isSuccess,
          status != 'Completed',
        );
      },
    );
  }
  test('Web archive marker protects even a locally Active batch', () async {
    final client = _Client()
      ..archives = CloudBatchArchivesRead.found([
        CloudBatchArchiveRow(
          batchId: 'b',
          archivedAt: DateTime.utc(2026),
          archivedByUid: 'u',
        ),
      ]);
    expect(
      (await checkBatchDeletionAllowed(client, 'b')).code,
      'completed_batch_protected',
    );
    expect(
      (await checkBatchDeletionAllowed(client, 'other')).isSuccess,
      isTrue,
    );
  });
  test(
    'uncompleted batch is allowed; missing cloud rows allow orphan cleanup',
    () async {
      expect(
        (await checkBatchDeletionAllowed(_Client(), 'b')).isSuccess,
        isTrue,
      );
    },
  );
  test('read failure blocks deletion', () async {
    final client = _Client()
      ..batches = const CloudBatchesRead.failed(
        SyncOutcome.transient('offline'),
      );
    expect((await checkBatchDeletionAllowed(client, 'b')).isSuccess, isFalse);
  });
  test('archive verification failure also blocks deletion', () async {
    final client = _Client()
      ..archives = const CloudBatchArchivesRead.failed(
        SyncOutcome.transient('offline'),
      );
    expect((await checkBatchDeletionAllowed(client, 'b')).isSuccess, isFalse);
  });
}
