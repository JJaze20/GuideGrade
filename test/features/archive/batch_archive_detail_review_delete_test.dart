import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/archive/screens/batch_archive_detail_screen.dart';
import 'package:guidegrade/features/guidance/widgets/batch_list_item.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

OmrScanResult _decoded({required bool flagged}) => OmrScanResult(
      examCode: 'AT',
      items: [
        const OmrItemResult(sectionName: 'Section 1', itemNumber: 1, markedChoice: 'B'),
        OmrItemResult(sectionName: 'Section 1', itemNumber: 2, markedChoice: null, isAmbiguous: flagged),
      ],
    );

LocalScan _scan(String id, {bool flagged = false, String? first}) => LocalScan(
      id: id,
      imageFileName: 'images/$id.enc',
      capturedAt: DateTime.utc(2026, 9, 1),
      decoded: _decoded(flagged: flagged),
      examinee: first == null
          ? null
          : ExamineeInfo(firstName: first, lastName: 'Cruz', middleName: '', examineeNumber: 'X-$id'),
    );

LocalBatch _batch(List<LocalScan> scans, {String status = 'Archived'}) => LocalBatch(
      id: 'b1',
      batchCode: 'B-1',
      examCode: 'AT',
      examTitle: 'Admission Test',
      description: 'Morning batch',
      expectedCount: 10,
      status: status,
      createdByUid: 'u',
      createdByName: 'Officer',
      createdAt: DateTime.utc(2026, 9, 1),
      updatedAt: DateTime.utc(2026, 9, 2),
      scans: scans,
    );

class _Repo implements BatchRepository {
  _Repo(this.batch);
  LocalBatch batch;
  bool failDelete = false;
  final deleted = <String>[];

  @override
  Future<LocalBatch?> getBatchById(String id) async => batch;

  @override
  Future<LocalBatch> deleteScan({required String batchId, required String scanId}) async {
    if (failDelete) throw StateError('disk full');
    deleted.add(scanId);
    batch = batch.copyWith(
      scans: batch.scans.where((s) => s.id != scanId).toList(),
      updatedAt: batch.updatedAt.add(const Duration(milliseconds: 1)),
    );
    return batch;
  }

  @override
  Future<Uint8List?> resolveScanImage(String batchId, LocalScan scan) async => null;
  @override
  Future<Uint8List?> resolveScanRectifiedImage(String batchId, LocalScan scan) async => null;
  @override
  Future<Uint8List?> resolveScanNameCropLast(String batchId, LocalScan scan) async => null;
  @override
  Future<Uint8List?> resolveScanNameCropFirst(String batchId, LocalScan scan) async => null;
  @override
  Future<Uint8List?> resolveScanNameCropMiddle(String batchId, LocalScan scan) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<void> pump(WidgetTester tester, _Repo repo) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appState = AppState(batchRepository: repo);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppStateScope(notifier: appState, child: child!),
        home: const BatchArchiveDetailScreen(batchId: 'b1'),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('batch card', () {
    testWidgets('shows a Needs review indicator with the affected-sheet count', (tester) async {
      final batch = _batch([_scan('s1', flagged: true), _scan('s2', flagged: true), _scan('s3')]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BatchListItem(batch: batch, onTap: () {}, onDelete: () {})),
      ));
      expect(find.text('Needs review · 2'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('a batch with only wrong/blank answers shows no indicator', (tester) async {
      final batch = _batch([_scan('s1'), _scan('s2')]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BatchListItem(batch: batch, onTap: () {}, onDelete: () {})),
      ));
      expect(find.byKey(const ValueKey('needs-review-chip')), findsNothing);
    });
  });

  group('archived batch detail', () {
    testWidgets('lists the sheets that need review', (tester) async {
      final repo = _Repo(_batch([_scan('s1', first: 'Ana'), _scan('s2', flagged: true, first: 'Ben'), _scan('s3')]));
      await pump(tester, repo);

      final banner = find.byKey(const ValueKey('needs-review-banner'));
      expect(banner, findsOneWidget);
      expect(find.descendant(of: banner, matching: find.textContaining('1 sheet needs review')), findsOneWidget);
      expect(find.descendant(of: banner, matching: find.textContaining('Ben')), findsOneWidget);
    });

    testWidgets('delete asks first, names the sheet, and Cancel deletes nothing', (tester) async {
      final repo = _Repo(_batch([_scan('s1', first: 'Ana'), _scan('s2', first: 'Ben')]));
      await pump(tester, repo);

      await tester.tap(find.byKey(const ValueKey('delete-scan-s2')));
      await tester.pumpAndSettle();

      expect(find.text('Delete This Sheet?'), findsOneWidget);
      expect(find.textContaining('Sheet 2'), findsWidgets);
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.textContaining(repo.batch.scans[1].examinee!.displayName)), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(repo.deleted, isEmpty);
      expect(find.byKey(const ValueKey('delete-scan-s2')), findsOneWidget);
    });

    testWidgets('confirming deletes only that sheet; warning and counts update; status stays Archived',
        (tester) async {
      final repo = _Repo(_batch([_scan('s1', first: 'Ana'), _scan('s2', flagged: true, first: 'Ben')]));
      await pump(tester, repo);
      expect(find.byKey(const ValueKey('needs-review-banner')), findsOneWidget);
      expect(find.text('Archived'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('delete-scan-s2')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(repo.deleted, ['s2']);
      expect(find.byKey(const ValueKey('delete-scan-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-scan-s2')), findsNothing);
      expect(find.byKey(const ValueKey('needs-review-banner')), findsNothing, reason: 'no flagged sheet is left');
      expect(find.text('Archived'), findsWidgets);
      expect(find.text('Sheet 2 deleted.'), findsOneWidget);
    });

    testWidgets('a failed delete says so, keeps the sheet, and never reports success', (tester) async {
      final repo = _Repo(_batch([_scan('s1', first: 'Ana')]))..failDelete = true;
      await pump(tester, repo);

      await tester.tap(find.byKey(const ValueKey('delete-scan-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not delete this sheet'), findsOneWidget);
      expect(find.textContaining('deleted.'), findsNothing);
      expect(find.byKey(const ValueKey('delete-scan-s1')), findsOneWidget);
    });
  });
}
