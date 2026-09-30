import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:guidegrade/core/services/logging_service.dart';
import 'package:guidegrade/features/admin/screens/system_logs_screen.dart';
import 'package:guidegrade/models/log_entry.dart';

/// Never reaches real Firestore. Queues one [LogPage] per call to
/// [getRecentLogs] (first call = initial load, subsequent calls = each
/// Load More tap), consumed in order.
class _FakeLoggingService implements LoggingService {
  final List<LogPage> responses = [];
  int callCount = 0;

  @override
  Future<LogPage> getRecentLogs({int limit = 100, DocumentSnapshot? startAfter}) async {
    final page = callCount < responses.length ? responses[callCount] : LogPage.empty;
    callCount++;
    return page;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LogEntry _entry(String id, {String description = 'Signed in'}) => LogEntry(
      logId: id,
      timestamp: DateTime.utc(2026, 1, 1),
      actorUid: 'u1',
      actorEmail: 'admin@ndmu.edu.ph',
      actorRole: 'system_admin',
      action: LogAction.loginSuccess,
      category: LogCategory.authentication,
      description: description,
      success: true,
      severity: LogSeverity.info,
    );

void main() {
  late _FakeLoggingService loggingService;

  setUp(() {
    loggingService = _FakeLoggingService();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: SystemLogsScreen(loggingService: loggingService)),
    );
    await tester.pump();
  }

  testWidgets('A. logs are displayed when records exist', (tester) async {
    loggingService.responses.add(
      LogPage(entries: [_entry('1', description: 'Alice signed in')], lastDocument: null, hasMore: false),
    );
    await pumpScreen(tester);

    expect(find.text('Alice signed in'), findsOneWidget);
    expect(find.text('No logs found'), findsNothing);
    expect(find.text('Could not load logs'), findsNothing);
  });

  testWidgets('B. empty-state UI appears for a successful zero-result load',
      (tester) async {
    loggingService.responses.add(const LogPage(entries: [], lastDocument: null, hasMore: false));
    await pumpScreen(tester);

    expect(find.text('No logs found'), findsOneWidget);
    expect(find.text('Could not load logs'), findsNothing);
  });

  testWidgets('C. error-state UI appears for a failed initial load',
      (tester) async {
    loggingService.responses.add(LogPage.error());
    await pumpScreen(tester);

    expect(find.text('Could not load logs'), findsOneWidget);
    expect(find.text('No logs found'), findsNothing);
  });

  testWidgets('D. reload/retry can recover from an initial load failure',
      (tester) async {
    loggingService.responses.add(LogPage.error());
    await pumpScreen(tester);
    expect(find.text('Could not load logs'), findsOneWidget);

    // The app-bar reload button (FontAwesomeIcons.rotateRight) calls
    // _loadInitial again -- a second, successful response now resolves it.
    loggingService.responses.add(
      LogPage(entries: [_entry('1', description: 'Recovered log')], lastDocument: null, hasMore: false),
    );
    await tester.tap(find.byIcon(FontAwesomeIcons.rotateRight.data));
    await tester.pump();
    await tester.pump();

    expect(find.text('Recovered log'), findsOneWidget);
    expect(find.text('Could not load logs'), findsNothing);
  });

  testWidgets("E. a load-more failure does not remove already-loaded logs",
      (tester) async {
    loggingService.responses.add(
      LogPage(entries: [_entry('1', description: 'First page log')], lastDocument: null, hasMore: true),
    );
    loggingService.responses.add(LogPage.error());
    await pumpScreen(tester);

    expect(find.text('First page log'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Load More'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Load More'));
    await tester.pump(); // start the load-more (shows spinner)
    await tester.pump(); // settle the awaited Future

    // Existing log is still there; whole-screen error state did NOT take over.
    expect(find.text('First page log'), findsOneWidget);
    expect(find.text('Could not load logs'), findsNothing);
    // Load More is still available for the user to retry (SnackBar shown).
    expect(find.widgetWithText(OutlinedButton, 'Load More'), findsOneWidget);
    expect(find.text('Could not load more logs. Please try again.'), findsOneWidget);
  });

  testWidgets('F. a classified Firebase failure (permission-denied) shows '
      'the authorization-specific message, and reload/retry still works',
      (tester) async {
    loggingService.responses.add(
      LogPage.error(cause: FirebaseException(plugin: 'firestore', code: 'permission-denied')),
    );
    await pumpScreen(tester);

    expect(find.textContaining('permission'), findsOneWidget);
    expect(find.text('Could not load logs'), findsNothing);

    // The app-bar reload button still recovers, exactly as in test D.
    loggingService.responses.add(
      LogPage(entries: [_entry('1', description: 'Recovered log')], lastDocument: null, hasMore: false),
    );
    await tester.tap(find.byIcon(FontAwesomeIcons.rotateRight.data));
    await tester.pump();
    await tester.pump();

    expect(find.text('Recovered log'), findsOneWidget);
    expect(find.textContaining('permission'), findsNothing);
  });
}
