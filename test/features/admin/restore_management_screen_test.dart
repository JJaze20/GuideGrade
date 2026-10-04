import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/sync/admin_scan_restore_client.dart';
import 'package:guidegrade/core/sync/supabase_sync_client.dart' show SyncIdentity;
import 'package:guidegrade/core/sync/sync_outcome.dart';
import 'package:guidegrade/features/admin/screens/restore_management_screen.dart';
import 'package:guidegrade/features/admin/services/admin_scan_restore_service.dart';

/// Never reaches real Supabase. [deletedScans]/[requests] are mutated by
/// [reviewRestoreRequest]/[restoreApprovedScan] to simulate the RPCs' own
/// server-side effects (status transitions, a restored scan leaving the
/// deleted-scans listing), the same convention the Guidance Web fakes in
/// this test suite already use.
class _FakeAdminScanRestoreClient implements AdminScanRestoreClient {
  List<CloudAdminSoftDeletedScanRow> deletedScans = [];
  List<CloudAdminRestoreRequestRow> requests = [];
  SyncOutcome? reviewResult;
  SyncOutcome? restoreResult;
  final List<String> calls = [];

  @override
  Future<CloudAdminSoftDeletedScansRead> listDeletedScansForAdmin() async {
    calls.add('listDeletedScansForAdmin');
    return CloudAdminSoftDeletedScansRead.found(deletedScans);
  }

  @override
  Future<CloudAdminRestoreRequestsRead> listRestoreRequestsForAdmin() async {
    calls.add('listRestoreRequestsForAdmin');
    return CloudAdminRestoreRequestsRead.found(requests);
  }

  @override
  Future<SyncOutcome> reviewRestoreRequest({
    required String requestId,
    required bool approve,
    required String reviewerUid,
    String? reviewerName,
    String? reviewNote,
  }) async {
    calls.add('reviewRestoreRequest:$requestId/$approve');
    final override = reviewResult;
    if (override != null) return override;
    requests = [
      for (final r in requests)
        if (r.requestId == requestId)
          CloudAdminRestoreRequestRow(
            requestId: r.requestId,
            batchId: r.batchId,
            scanId: r.scanId,
            examCode: r.examCode,
            status: approve ? 'APPROVED' : 'REJECTED',
            reason: r.reason,
            requestedByName: r.requestedByName,
            requestedAt: r.requestedAt,
            reviewedByName: reviewerName,
            reviewedAt: DateTime.utc(2026, 3, 3),
            reviewNote: reviewNote,
          )
        else
          r,
    ];
    return const SyncOutcome.success();
  }

  @override
  Future<SyncOutcome> restoreApprovedScan({
    required String requestId,
    required String reviewerUid,
    String? reviewerName,
  }) async {
    calls.add('restoreApprovedScan:$requestId');
    final override = restoreResult;
    if (override != null) return override;
    final target = requests.where((r) => r.requestId == requestId).firstOrNull;
    if (target != null) {
      deletedScans = deletedScans
          .where((s) => !(s.batchId == target.batchId && s.scanId == target.scanId))
          .toList();
    }
    requests = [
      for (final r in requests)
        if (r.requestId == requestId)
          CloudAdminRestoreRequestRow(
            requestId: r.requestId,
            batchId: r.batchId,
            scanId: r.scanId,
            examCode: r.examCode,
            status: 'RESTORED',
            reason: r.reason,
            requestedByName: r.requestedByName,
            requestedAt: r.requestedAt,
            reviewedByName: r.reviewedByName,
            reviewedAt: r.reviewedAt,
            reviewNote: r.reviewNote,
          )
        else
          r,
    ];
    return const SyncOutcome.success();
  }
}

CloudAdminSoftDeletedScanRow _scanRow({String scanId = 's1'}) => CloudAdminSoftDeletedScanRow(
      batchId: 'b1',
      scanId: scanId,
      examCode: 'TAT',
      deletedAt: DateTime.utc(2026, 3, 1),
      retentionUntil: DateTime.utc(2026, 3, 31),
      deletionReason: 'Duplicate capture',
      deletedByName: 'Council Member',
    );

CloudAdminRestoreRequestRow _requestRow({
  String requestId = 'req-1',
  String status = 'PENDING',
  String scanId = 's1',
}) =>
    CloudAdminRestoreRequestRow(
      requestId: requestId,
      batchId: 'b1',
      scanId: scanId,
      examCode: 'TAT',
      status: status,
      reason: 'Need this scan back',
      requestedByName: 'Council Member',
      requestedAt: DateTime.utc(2026, 3, 2),
    );

/// Test-only [SyncIdentity] so [AdminScanRestoreService] never reaches
/// `FirebaseAuth.instance` (which has no app initialized in a widget test).
class _Identity implements SyncIdentity {
  _Identity({this.uid = 'admin-uid-1', this.displayName = 'System Administrator'});
  @override
  final String? uid;
  @override
  final String? displayName;
  @override
  Future<bool> refreshToken() async => false;
}

void main() {
  late _FakeAdminScanRestoreClient client;

  setUp(() {
    client = _FakeAdminScanRestoreClient();
  });

  Future<void> pumpScreen(WidgetTester tester, {SyncIdentity? identity}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RestoreManagementScreen(
          service: AdminScanRestoreService(client: client, identity: identity ?? _Identity()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openRequestsTab(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Restore Requests'));
    await tester.pumpAndSettle();
  }

  Future<void> openDeletedTab(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Deleted Scans'));
    await tester.pumpAndSettle();
  }

  testWidgets('2. Deleted Scans section displays only lifecycle metadata', (tester) async {
    client.deletedScans = [_scanRow()];
    await pumpScreen(tester);

    expect(find.textContaining('Scan s1'), findsOneWidget);
    expect(find.textContaining('Batch b1'), findsOneWidget);
    expect(find.text('TAT'), findsOneWidget);
    expect(find.textContaining('Duplicate capture'), findsOneWidget);
    expect(find.textContaining('Council Member'), findsOneWidget);
  });

  testWidgets('3. Restore Requests section displays request metadata', (tester) async {
    client.requests = [_requestRow()];
    await pumpScreen(tester);
    await openRequestsTab(tester);

    expect(find.textContaining('Scan s1'), findsOneWidget);
    expect(find.textContaining('Need this scan back'), findsOneWidget);
    expect(find.textContaining('Council Member'), findsOneWidget);
    expect(find.text('PENDING'), findsOneWidget);
  });

  testWidgets('4. PENDING shows Approve/Reject', (tester) async {
    client.requests = [_requestRow(status: 'PENDING')];
    await pumpScreen(tester);
    await openRequestsTab(tester);

    expect(find.widgetWithText(TextButton, 'Approve'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Reject'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Restore Scan'), findsNothing);
  });

  testWidgets('5. APPROVED shows Restore Scan', (tester) async {
    client.requests = [_requestRow(status: 'APPROVED')];
    await pumpScreen(tester);
    await openRequestsTab(tester);

    expect(find.widgetWithText(TextButton, 'Restore Scan'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Approve'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Reject'), findsNothing);
  });

  testWidgets('6. RESTORED does not show an active restore action', (tester) async {
    client.requests = [_requestRow(status: 'RESTORED')];
    await pumpScreen(tester);
    await openRequestsTab(tester);

    expect(find.widgetWithText(TextButton, 'Restore Scan'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Approve'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Reject'), findsNothing);
    expect(find.text('RESTORED'), findsOneWidget);
  });

  testWidgets('7. review note is required', (tester) async {
    client.requests = [_requestRow(status: 'PENDING')];
    await pumpScreen(tester);
    await openRequestsTab(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();
    expect(find.text('Approve Restore Request'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(find.text('A review note is required'), findsOneWidget);
    expect(find.text('Approve Restore Request'), findsOneWidget); // dialog still open
    expect(client.calls, isNot(contains(startsWith('reviewRestoreRequest'))));
  });

  testWidgets('8. approve success refreshes state', (tester) async {
    client.requests = [_requestRow(status: 'PENDING')];
    await pumpScreen(tester);
    await openRequestsTab(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reviewNoteField')), 'Looks legitimate');
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();

    expect(find.text('Approve Restore Request'), findsNothing); // dialog closed
    expect(find.text('APPROVED'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Restore Scan'), findsOneWidget);
    expect(find.textContaining('Request approved'), findsOneWidget);
  });

  testWidgets('9. reject success refreshes state', (tester) async {
    client.requests = [_requestRow(status: 'PENDING')];
    await pumpScreen(tester);
    await openRequestsTab(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Reject'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reviewNoteField')), 'Not eligible');
    await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
    await tester.pumpAndSettle();

    expect(find.text('Reject Restore Request'), findsNothing); // dialog closed
    expect(find.text('REJECTED'), findsOneWidget);
    expect(find.textContaining('Request rejected'), findsOneWidget);
  });

  testWidgets('10. restore success removes the scan from Deleted Scans and marks the request '
      'RESTORED, never claiming anything about its result/score', (tester) async {
    client.deletedScans = [_scanRow(scanId: 's1')];
    client.requests = [_requestRow(status: 'APPROVED', scanId: 's1')];
    await pumpScreen(tester);
    expect(find.textContaining('Scan s1'), findsOneWidget); // Deleted Scans tab, default

    await openRequestsTab(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Restore Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Restore Scan?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Restore Scan'));
    await tester.pumpAndSettle();

    expect(find.text('Restore Scan?'), findsNothing); // dialog closed
    expect(find.text('RESTORED'), findsOneWidget);
    expect(find.textContaining('Scan restored successfully'), findsOneWidget);
    expect(find.textContaining('score'), findsNothing);
    expect(find.textContaining('result'), findsNothing);

    await openDeletedTab(tester);
    expect(find.textContaining('No soft-deleted scans'), findsOneWidget);
  });

  testWidgets('11. a review failure keeps the dialog open with an inline error, and the screen '
      'remains fully usable afterward', (tester) async {
    client.requests = [_requestRow(status: 'PENDING')];
    client.reviewResult = const SyncOutcome.permanent('42501');
    await pumpScreen(tester);
    await openRequestsTab(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Approve'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reviewNoteField')), 'Looks fine');
    await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
    await tester.pumpAndSettle();

    // Dialog stays open with its own inline error; the request is untouched.
    expect(find.text('Approve Restore Request'), findsOneWidget);
    expect(find.textContaining('already been'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    // The screen itself is still fully interactive afterward.
    expect(find.text('PENDING'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Approve'), findsOneWidget);
  });

  testWidgets('12. no decoded answer, score, result, or image/path data ever appears',
      (tester) async {
    client.deletedScans = [_scanRow()];
    client.requests = [_requestRow()];
    await pumpScreen(tester);

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Score'), findsNothing);
    expect(find.textContaining('score'), findsNothing);
    expect(find.textContaining('Image'), findsNothing);
    expect(find.textContaining('.jpg'), findsNothing);

    await openRequestsTab(tester);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Score'), findsNothing);
  });

  testWidgets(
    '13. a restore failure keeps the Restore Scan dialog open with an inline error, shows no '
    'success SnackBar, and never falsely marks the request as RESTORED',
    (tester) async {
      client.deletedScans = [_scanRow(scanId: 's1')];
      client.requests = [_requestRow(status: 'APPROVED', scanId: 's1')];
      client.restoreResult = const SyncOutcome.permanent('42501');
      await pumpScreen(tester);
      await openRequestsTab(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Restore Scan'));
      await tester.pumpAndSettle();
      expect(find.text('Restore Scan?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Restore Scan'));
      await tester.pumpAndSettle();

      // The dialog stays open (never pops), showing its own inline error --
      // the saving state has ended (the button reads "Restore Scan" again,
      // not "Restoring...", and is tappable, not disabled).
      expect(find.text('Restore Scan?'), findsOneWidget);
      expect(find.textContaining('retention window may have expired'), findsOneWidget);
      final retryButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Restore Scan'),
      );
      expect(retryButton.onPressed, isNotNull);

      // No success SnackBar was ever shown, and the request is still
      // APPROVED -- never advanced to RESTORED by a failed attempt.
      expect(find.textContaining('Scan restored successfully'), findsNothing);
      expect(find.text('RESTORED'), findsNothing);

      // Close the dialog and confirm the underlying request/scan state is
      // completely untouched: still APPROVED, and the scan is still listed
      // on Deleted Scans (a real restore would have removed it there).
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('APPROVED'), findsOneWidget);
      await openDeletedTab(tester);
      expect(find.textContaining('Scan s1'), findsOneWidget);
    },
  );

  testWidgets(
    '14. a signed-out reviewer (SyncIdentity.uid null) never reaches the client, and the '
    'dialog surfaces the sign-in error instead of pretending success',
    (tester) async {
      client.requests = [_requestRow(status: 'PENDING')];
      await pumpScreen(tester, identity: _Identity(uid: null));
      await openRequestsTab(tester);

      await tester.tap(find.widgetWithText(TextButton, 'Approve'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('reviewNoteField')), 'Looks fine');
      await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();

      // The dialog stays open (never pops -- no fabricated success) and
      // shows the sign-in error, and the client/RPC was never called at all.
      expect(find.text('Approve Restore Request'), findsOneWidget);
      expect(find.textContaining('signed in'), findsOneWidget);
      expect(client.calls, isNot(contains(startsWith('reviewRestoreRequest'))));

      // The request is still PENDING -- never advanced to APPROVED.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('PENDING'), findsOneWidget);
    },
  );

  testWidgets('15. both tabs lay out on a phone with large text (no overflow)', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    client.deletedScans = [_scanRow()];
    client.requests = [_requestRow(), _requestRow(requestId: 'req-2', status: 'APPROVED', scanId: 's2')];
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: RestoreManagementScreen(
            service: AdminScanRestoreService(client: client, identity: _Identity()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Scan s1'), findsOneWidget);

    await openRequestsTab(tester);
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextButton, 'Approve'), findsOneWidget);
    // The second card is below the fold at this size/scale: scroll to it.
    await tester.scrollUntilVisible(
      find.widgetWithText(TextButton, 'Restore Scan'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextButton, 'Restore Scan'), findsOneWidget);
  });

  testWidgets('16. an empty list explains itself and the refresh button has a tooltip', (tester) async {
    await pumpScreen(tester);
    expect(find.text('No soft-deleted scans.'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    await openRequestsTab(tester);
    expect(find.text('No restore requests.'), findsOneWidget);
  });
}
