import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/logging_service.dart';
import 'package:guidegrade/models/log_entry.dart';

/// [LoggingService.getRecentLogs] talks to a real `FirebaseFirestore`
/// instance with no injectable query abstraction, and this project has no
/// Firestore-faking dependency -- so these tests exercise [LogPage] itself:
/// the exact contract `getRecentLogs`'s success and catch paths now return
/// (a plain `return page;`/`return LogPage.error(cause: e);`, nothing else
/// to unit-test on that method without adding a new test dependency).
void main() {
  LogEntry entry(String id) => LogEntry(
        logId: id,
        timestamp: DateTime.utc(2026, 1, 1),
        actorUid: 'u1',
        actorEmail: 'admin@ndmu.edu.ph',
        actorRole: 'system_admin',
        action: LogAction.loginSuccess,
        category: LogCategory.authentication,
        description: 'Signed in',
        success: true,
        severity: LogSeverity.info,
      );

  group('LogPage.isError', () {
    test('A. a successful result containing records has isError == false', () {
      final page = LogPage(entries: [entry('1'), entry('2')], lastDocument: null, hasMore: true);
      expect(page.isError, isFalse);
      expect(page.entries, hasLength(2));
    });

    test('B. a successful result containing zero records has isError == '
        'false -- same shape as LogPage.empty', () {
      const page = LogPage(entries: [], lastDocument: null, hasMore: false);
      expect(page.isError, isFalse);
      expect(page.entries, isEmpty);
      expect(page.hasMore, isFalse);
      expect(LogPage.empty.isError, isFalse);
    });

    test('C. the representation getRecentLogs\' catch block returns on a '
        'simulated exception has isError == true', () {
      final page = LogPage.error();
      expect(page.isError, isTrue);
      // Same empty shape as a genuine empty success -- isError is the only
      // field that tells the two apart.
      expect(page.entries, isEmpty);
      expect(page.lastDocument, isNull);
      expect(page.hasMore, isFalse);
    });

    test('LogPage.empty and LogPage.error() are structurally identical '
        'except for isError -- proving the bug this fix closes', () {
      const empty = LogPage.empty;
      final error = LogPage.error();
      expect(empty.entries, error.entries);
      expect(empty.lastDocument, error.lastDocument);
      expect(empty.hasMore, error.hasMore);
      expect(empty.isError, isFalse);
      expect(error.isError, isTrue);
    });

    test('LogPage.error carries the original error as cause, for message '
        'classification, and every non-error page has a null cause', () {
      final original = Exception('boom');
      final page = LogPage.error(cause: original);
      expect(page.cause, same(original));
      expect(LogPage.empty.cause, isNull);
      expect(
        const LogPage(entries: [], lastDocument: null, hasMore: false).cause,
        isNull,
      );
    });
  });
}
