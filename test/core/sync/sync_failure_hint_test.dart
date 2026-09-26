import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/sync_failure_hint.dart';
import 'package:guidegrade/core/sync/sync_job.dart';

SyncJob _failed(String? code) => SyncJob.create(
      type: SyncJobType.pushScan,
      entityId: 's',
      batchId: 'b',
      scanId: 's',
    ).copyWith(status: SyncJobStatus.failedPermanent, lastErrorCode: code);

void main() {
  test('known codes have a plain-English meaning; unknown codes have none', () {
    expect(syncFailureMeaning('42501'), contains('permission'));
    expect(syncFailureMeaning('23503'), contains('batch is not in the cloud'));
    expect(syncFailureMeaning('23514'), contains('name/ID'));
    expect(syncFailureMeaning('network'), contains('connection'));
    expect(syncFailureMeaning('99999'), isNull);
    expect(syncFailureMeaning(null), isNull);
  });

  test('summarises distinct codes with counts, most common first', () {
    final lines = summarizeSyncFailures([
      _failed('23503'),
      _failed('42501'),
      _failed('23503'),
      _failed('23503'),
      _failed('42501'),
    ]);
    expect(lines, hasLength(2));
    expect(lines[0], startsWith('23503 ×3'));
    expect(lines[1], startsWith('42501 ×2'));
  });

  test('a job with no recorded code is reported as unknown, and an unmapped code still shows its number', () {
    expect(summarizeSyncFailures([_failed(null)]).single, startsWith('unknown ×1'));
    expect(summarizeSyncFailures([_failed('XX000')]).single, 'XX000 ×1');
  });

  test('no failed jobs gives no lines', () {
    expect(summarizeSyncFailures(const []), isEmpty);
  });
}
