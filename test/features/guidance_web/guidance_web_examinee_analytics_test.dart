import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_examinee_records_service.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_examinee_analytics_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_results_service.dart';

final date = DateTime.utc(2026, 1, 1);
CloudExamineeRow person(String id) => CloudExamineeRow(
  id: id,
  temporaryExamineeId: 'TMP-$id',
  firstName: 'Name$id',
  lastName: 'Person',
  status: 'active',
  createdAt: date,
  updatedAt: date,
  createdByUid: 'u',
  updatedByUid: 'u',
);
CloudScanRow scan(String id, String? personId, {bool archived = false}) =>
    CloudScanRow(
      id: id,
      batchId: 'b',
      examCode: 'AT',
      capturedAt: date,
      decoded: {'examCode': 'AT', 'items': <dynamic>[]},
      examineeId: personId,
      attemptStatus: archived ? 'archived' : 'active',
    );

class ReadClient implements SyncClient {
  final List<CloudScanRow> scans = [];
  final List<String> calls = [];
  bool identityFails = false;
  @override
  Future<CloudExamineesRead> readCloudExaminees() async {
    calls.add('people');
    return identityFails
        ? const CloudExamineesRead.failed(SyncOutcome.transient('network'))
        : CloudExamineesRead.found([person('a'), person('without-link')]);
  }

  @override
  Future<CloudBatchesRead> readCloudBatches() async {
    calls.add('batches');
    return CloudBatchesRead.found([
      CloudBatchRow(
        id: 'b',
        batchCode: 'B',
        examCode: 'AT',
        examTitle: 'Admission Test',
        description: '',
        expectedCount: 10,
        status: 'Completed',
        createdByUid: 'u',
        createdByName: 'User',
        createdAt: date,
        updatedAt: date,
      ),
    ]);
  }

  @override
  Future<CloudScansRead> readCloudScans(String batchId) async {
    calls.add('scans:$batchId');
    return CloudScansRead.found(scans);
  }

  @override
  Future<CloudScansRead> readCloudScansForExaminee(String id) async =>
      CloudScansRead.found(
        scans.where((scan) => scan.examineeId == id).toList(),
      );

  @override
  Future<CloudAnswerKeyRead> readAnswerKey(String examCode) async =>
      const CloudAnswerKeyRead.absent();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected call: ${invocation.memberName}');
}

void main() {
  late ReadClient client;
  late GuidanceWebExamineeRecordsService service;
  setUp(() {
    client = ReadClient();
    service = GuidanceWebExamineeRecordsService(client: client);
  });
  for (final width in [320.0, 390.0, 768.0, 1280.0]) {
    testWidgets('Examinee Analytics controls fit at $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      client.scans.addAll([scan('linked', 'a'), scan('unlinked', null)]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceWebExamineeAnalyticsView(
              recordsService: service,
              resultsService: GuidanceWebResultsService(client: client),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Unlinked Examinee').first);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('unlinkedAnalyticsRow_unlinked')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('examineeAnalyticsSearch')),
        'no-match',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('unlinkedAnalyticsRow_unlinked')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'linked Analytics result retains the canonical name and ID with empty scan names',
    (tester) async {
      client.scans.add(scan('linked', 'a'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceWebExamineeAnalyticsView(
              recordsService: service,
              resultsService: GuidanceWebResultsService(client: client),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('examineeAnalyticsRow_a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AT — B'));
      await tester.pumpAndSettle();
      expect(find.text('Namea Person'), findsOneWidget);
      await tester.tap(find.text('Examinee details'));
      await tester.pumpAndSettle();
      expect(find.text('TMP-a'), findsOneWidget);
      expect(find.text('Namea'), findsOneWidget);
      expect(find.text('Person'), findsOneWidget);
      expect(
        find.textContaining('not from a verified Examinee Record'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'unique linked people, unresolved scans, and archived attempt exclusions',
    () async {
      client.scans.addAll([
        scan('one', 'a'),
        scan('two', 'a'),
        scan('three', 'a'),
        scan('null', null),
        scan('dangling', 'missing'),
        scan('duplicate', null),
        scan('duplicate', null),
        scan('old', 'without-link', archived: true),
        scan('old-null', null, archived: true),
      ]);
      final population = await service.loadAnalyticsPopulation();
      expect(population.examinees.map((p) => p.id), ['a']);
      expect(population.unlinked.map((p) => p.scan.id).toSet(), {
        'null',
        'dangling',
        'duplicate',
      });
      expect(client.calls, ['people', 'batches', 'scans:b']);
    },
  );
  test('identity failure is not misreported as unlinked records', () async {
    client.identityFails = true;
    expect(
      service.loadAnalyticsPopulation(),
      throwsA(isA<GuidanceWebExamineeRecordsException>()),
    );
    expect(client.calls, ['people']);
  });
  testWidgets(
    'hot reload resets mode and reloads the linked/unlinked snapshot',
    (tester) async {
      client.scans.addAll([scan('linked', 'a'), scan('null', null)]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceWebExamineeAnalyticsView(recordsService: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unlinked Examinee'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('unlinkedAnalyticsRow_null')),
        findsOneWidget,
      );
      client.scans.clear();
      tester.binding.buildOwner!.reassemble(tester.binding.rootElement!);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('analytics.examineeCount')))
            .data,
        '0',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('analytics.unlinkedCount')))
            .data,
        '0',
      );
      expect(find.text('No examinees found.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(client.calls.where((c) => c == 'people').length, 2);
    },
  );

  test('production scan read retains soft-delete exclusion', () {
    final source = File(
      'lib/core/sync/supabase_sync_client.dart',
    ).readAsStringSync();
    final start = source.indexOf(
      'Future<CloudScansRead> readCloudScans(String batchId)',
    );
    final end = source.indexOf('return CloudScansRead.found', start);
    expect(
      source.substring(start, end),
      contains(".isFilter('deleted_at', null)"),
    );
  });
  for (final (label, rows, linked, unlinked) in [
    ('both', [scan('linked', 'a'), scan('null', null)], 1, 1),
    ('no linked', [scan('null', null)], 0, 1),
    ('no unlinked', [scan('linked', 'a'), scan('repeat', 'a')], 1, 0),
    ('empty', <CloudScanRow>[], 0, 0),
  ]) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('$label counts and labels at width $width', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        client.scans.addAll(rows);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: GuidanceWebExamineeAnalyticsView(
                  recordsService: service,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Examinee'), findsOneWidget);
        expect(find.text('Unlinked Examinee'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const Key('analytics.examineeCount')))
              .data,
          '$linked',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('analytics.unlinkedCount')))
              .data,
          '$unlinked',
        );
        for (final forbidden in [
          'Tagged',
          'Untagged',
          'Real Examinee',
          'Canonical Examinee',
        ]) {
          expect(find.textContaining(forbidden), findsNothing);
        }
        expect(
          find.byKey(const Key('examineeAnalyticsRow_a')),
          linked == 0 ? findsNothing : findsOneWidget,
        );
        final before = List.of(client.calls);
        await tester.tap(find.text('Unlinked Examinee'));
        await tester.pumpAndSettle();
        if (unlinked == 0)
          expect(find.text('No unlinked examinees.'), findsOneWidget);
        else
          expect(
            find.byKey(const Key('unlinkedAnalyticsRow_null')),
            findsOneWidget,
          );
        expect(client.calls, before);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
