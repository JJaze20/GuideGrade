import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_dashboard_service.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/examinee_record.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

final _date = DateTime.utc(2026);
LocalBatch _batch(String code) => LocalBatch(
  id: code,
  batchCode: code,
  examCode: code,
  examTitle: code,
  description: '',
  expectedCount: 0,
  status: 'Completed',
  createdByUid: 'u',
  createdByName: 'n',
  createdAt: _date,
  updatedAt: _date,
);
LocalScan _scan(
  String id,
  String code,
  int score, {
  String status = 'Graded',
  bool partial = false,
}) {
  final items = code == 'AT'
      ? 72
      : code == 'QTM'
      ? 60
      : 100;
  return LocalScan(
    id: id,
    imageFileName: '',
    capturedAt: _date,
    decoded: OmrScanResult(examCode: code, items: const []),
    result: LocalScanResult(
      rawScore: score,
      totalItems: items,
      totalGraded: partial ? 1 : items,
      percentage: 0,
      status: status,
      scannedAt: _date,
      processedByUid: 'u',
      processedByName: 'n',
    ),
  );
}

class _Identity implements ExamineeRecord {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Results implements GuidanceWebResultsService {
  final calls = <String>[];
  bool fail = false;
  @override
  Future<List<LocalBatch>> loadBatches() async => [
    for (final code in ['AT', 'QTM', 'TAT', 'UNKNOWN']) _batch(code),
  ];
  @override
  Future<WebBatchResults> loadResultsForBatch(
    LocalBatch batch, {
    bool includeArchivedAttempts = false,
  }) async {
    expect(includeArchivedAttempts, isFalse);
    calls.add(batch.examCode);
    if (fail) throw GuidanceWebResultsException('Could not load results');
    final score = batch.examCode == 'AT'
        ? 55
        : batch.examCode == 'QTM'
        ? 60
        : 160;
    final scans = [
      _scan('valid', batch.examCode, score),
      _scan('unlinked', batch.examCode, score),
      _scan('ungraded', batch.examCode, score, status: 'Ungraded'),
      if (batch.examCode != 'TAT')
        _scan('partial', batch.examCode, score, partial: true),
      _scan('invalid', batch.examCode, 999),
    ];
    return WebBatchResults(
      scans: scans,
      linkedExamineeByScanId: {
        for (final scan in scans)
          if (scan.id != 'unlinked') scan.id: _Identity(),
      },
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'reuses Results reads, excludes unlinked/ungraded/partial/invalid results',
    () async {
      final results = _Results();
      final data = await GuidanceWebDashboardService(results: results).load();
      expect(results.calls, ['AT', 'QTM', 'TAT']);
      expect(data.charts[0].counts, [0, 1, 0, 0]);
      expect(data.charts[1].counts, [0, 0, 0, 0, 0, 1]);
      expect(data.charts[2].counts, [0, 0, 0, 0, 0, 0, 0, 1]);
    },
  );
  test(
    'failed read never returns a fabricated zero or partial aggregate',
    () async {
      final results = _Results()..fail = true;
      await expectLater(
        GuidanceWebDashboardService(results: results).load(),
        throwsA(isA<GuidanceWebResultsException>()),
      );
    },
  );
}
