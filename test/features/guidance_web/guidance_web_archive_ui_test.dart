import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:guidegrade/core/constants/app_theme.dart';
import 'package:guidegrade/core/sync/sync_client.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/batch_archive.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_archive_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_archive_service.dart';

class _Client implements SyncClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service extends GuidanceWebArchiveService {
  _Service() : super(client: _Client());
  int calls = 0;
  Future<List<ArchivedBatchEntry>> Function()? response;
  @override
  Future<List<ArchivedBatchEntry>> loadArchivedBatches() async {
    calls++;
    return response == null ? [] : await response!();
  }
}

ArchivedBatchEntry _entry(String code, {String exam = 'AT'}) =>
    ArchivedBatchEntry(
      batch: LocalBatch(
        id: code,
        batchCode: code,
        examCode: exam,
        examTitle: 'Admission Test',
        description: 'Morning session',
        expectedCount: 5,
        status: 'Completed',
        createdByUid: 'uid',
        createdByName: 'Officer',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
      archive: BatchArchive(
        batchId: code,
        archivedAt: DateTime.utc(2026, 10, 1),
        archivedByUid: 'uid',
        archivedByName: 'Officer',
      ),
      scanCount: 5,
    );
void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  Future<void> pump(
    WidgetTester tester,
    _Service service, {
    double width = 1280,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 1000),
              textScaler: TextScaler.linear(scale),
            ),
            child: GuidanceWebArchiveView(service: service),
          ),
        ),
      ),
    );
  }

  testWidgets('loading shows real progress then resolves to empty guidance', (
    tester,
  ) async {
    final pending = Completer<List<ArchivedBatchEntry>>();
    final service = _Service()..response = () => pending.future;
    await pump(tester, service, width: 320);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('No completed batches yet.'), findsOneWidget);
    expect(
      find.textContaining('Archive an eligible batch from Results'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'error retry reloads existing service and renders recovered records',
    (tester) async {
      final service = _Service()
        ..response = () =>
            Future.error(GuidanceWebArchiveException('Check your connection.'));
      await pump(tester, service);
      await tester.pumpAndSettle();
      expect(find.text('Could not load completed batches'), findsOneWidget);
      expect(service.calls, 1);
      service.response = () async => [_entry('B-RECOVERED')];
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(service.calls, 2);
      expect(find.text('B-RECOVERED'), findsOneWidget);
      expect(find.text('Check your connection.'), findsNothing);
    },
  );
  for (final width in [320.0, 768.0, 1280.0]) {
    testWidgets('records render without overflow at $width with large text', (
      tester,
    ) async {
      final service = _Service()..response = () async => [_entry('B-MORNING')];
      await pump(tester, service, width: width, scale: 1.8);
      await tester.pumpAndSettle();
      expect(find.text('B-MORNING'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(
        find.byKey(Key(width < 700 ? 'archiveCards' : 'archiveTable')),
        findsOneWidget,
      );
      if (width < 700) {
        expect(find.textContaining('Archived by: Officer'), findsOneWidget);
        expect(
          tester.getSize(find.widgetWithText(TextButton, 'View')).height,
          greaterThanOrEqualTo(44),
        );
      } else {
        await tester.drag(
          find.byKey(const Key('archiveTable')),
          const Offset(-3000, 0),
        );
        await tester.pumpAndSettle();
        expect(find.text('View').hitTestable(), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('search no-match can clear filters and recover records', (
    tester,
  ) async {
    final service = _Service()..response = () async => [_entry('B-MORNING')];
    await pump(tester, service, width: 360);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('archiveSearch')), 'absent');
    await tester.pumpAndSettle();
    expect(
      find.text('No completed batches match your search or filter.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('B-MORNING'), findsOneWidget);
    expect(service.calls, 1);
  });
}
