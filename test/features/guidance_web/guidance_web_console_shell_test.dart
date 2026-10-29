import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_home_screen.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_dashboard_service.dart';
import 'package:guidegrade/features/guidance_web/widgets/console_clock.dart';
import 'package:guidegrade/models/user.dart';

class _EmptyDashboard implements GuidanceWebDashboardService {
  @override
  Future<GuidanceDashboardData> load() async =>
      GuidanceDashboardData([], [], []);
}

Future<AppState> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  DateTime Function()? clock,
}) async {
  // Set the real view size (not just the surface) so MediaQuery sees it too:
  // the shell chooses its wide or narrow layout from MediaQuery.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final state = AppState();
  addTearDown(state.dispose);
  state.setCurrentUser(
    UserModel(
      userId: 'gc-1',
      email: 'staff@ndmu.edu.ph',
      displayName: 'Juan Dela Cruz',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          AppStateScope(notifier: state, child: child!),
      home: GuidanceWebHomeScreen(
        dashboardService: _EmptyDashboard(),
        clock: clock ?? () => DateTime(2026, 10, 29, 14, 5, 9),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return state;
}

double _railWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(const Key('consoleRail'))).width;

void main() {
  group('console clock formatting', () {
    test('12-hour time with AM/PM and no leading zero on the hour', () {
      expect(formatConsoleTime(DateTime(2026, 10, 29, 14, 5, 9)), '2:05:09 PM');
      expect(formatConsoleTime(DateTime(2026, 10, 29, 9, 30, 0)), '9:30:00 AM');
      expect(
        formatConsoleTime(DateTime(2026, 10, 29, 0, 7, 45)),
        '12:07:45 AM',
      );
      expect(
        formatConsoleTime(DateTime(2026, 10, 29, 12, 0, 1)),
        '12:00:01 PM',
      );
      expect(
        formatConsoleTime(DateTime(2026, 10, 29, 23, 59, 59)),
        '11:59:59 PM',
      );
    });

    test('date with weekday and month name', () {
      expect(
        formatConsoleDate(DateTime(2026, 10, 29)),
        'Thursday, October 29, 2026',
      );
      expect(
        formatConsoleDate(DateTime(2027, 1, 1)),
        'Friday, January 1, 2027',
      );
      expect(
        formatConsoleDate(DateTime(2026, 12, 6)),
        'Sunday, December 6, 2026',
      );
    });
  });

  group('green console shell', () {
    testWidgets('shows the university name and a closed icon rail', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('Notre Dame of Marbel University'), findsOneWidget);
      expect(find.text('Guidance and Testing Center'), findsOneWidget);
      expect(_railWidth(tester), 76);
      // Closed rail: icons only -- no label text at all (not even a clipped
      // first letter), just the user's initials and no Sign out button yet.
      expect(find.text('Results'), findsNothing);
      expect(find.text('Examinee Records'), findsNothing);
      expect(find.text('JC'), findsOneWidget); // Juan Dela Cruz
      expect(find.byKey(const Key('consoleSignOut')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the top bar shows the date and the time with seconds', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byKey(const Key('consoleClockTime')), findsOneWidget);
      expect(find.text('2:05:09 PM'), findsOneWidget);
      expect(find.text('Thursday, October 29, 2026'), findsOneWidget);
      // The page name no longer sits in the top bar (it is the page title).
      expect(find.text('GUIDANCE COUNCIL'), findsNothing);
      // Date and time are separate: the date sits to the left of the time.
      final dateRect = tester.getRect(
        find.byKey(const Key('consoleClockDate')),
      );
      final timeRect = tester.getRect(
        find.byKey(const Key('consoleClockTime')),
      );
      expect(dateRect.right, lessThan(timeRect.left));

      // Same size and weight for the date and the time.
      final dateStyle = tester
          .widget<Text>(find.byKey(const Key('consoleClockDate')))
          .style!;
      final timeStyle = tester
          .widget<Text>(find.byKey(const Key('consoleClockTime')))
          .style!;
      expect(timeStyle.fontSize, dateStyle.fontSize);
      expect(timeStyle.fontWeight, dateStyle.fontWeight);

      // The date and the time sit close together (only the divider between
      // them), not far apart ...
      final timeBlockLeft = tester.getTopLeft(find.byIcon(Icons.schedule)).dx;
      expect(timeBlockLeft - dateRect.right, lessThan(60));
      // ... and the pair is flush with the right edge of the bar (20 px
      // padding), so no empty space is left there.
      expect(timeRect.right, closeTo(1440 - 20, 1));
      // The free space is to the LEFT of the pair, between the name and date.
      final nameRight = tester
          .getTopRight(find.text('Notre Dame of Marbel University'))
          .dx;
      expect(nameRight, lessThan(dateRect.left - 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the time ticks every second', (tester) async {
      var now = DateTime(2026, 10, 29, 14, 5, 9);
      await _pump(tester, clock: () => now);
      expect(find.text('2:05:09 PM'), findsOneWidget);

      now = DateTime(2026, 10, 29, 14, 5, 10);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('2:05:10 PM'), findsOneWidget);
      expect(find.text('2:05:09 PM'), findsNothing);

      now = DateTime(2026, 10, 29, 14, 6, 0);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('2:06:00 PM'), findsOneWidget);
    });

    testWidgets('the clock fits a window just above the narrow limit', (
      tester,
    ) async {
      await _pump(tester, size: const Size(920, 800));
      expect(find.byKey(const Key('consoleClockTime')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the sidebar slides open on hover and closes on leave', (
      tester,
    ) async {
      await _pump(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(900, 500));
      addTearDown(mouse.removePointer);
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 76);

      await mouse.moveTo(
        tester.getCenter(find.byKey(const Key('consoleRail'))),
      );
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 280);
      expect(find.byKey(const Key('consoleSignOut')), findsOneWidget);
      // Open: the labels appear next to the icons.
      expect(find.text('Results'), findsOneWidget);
      expect(find.text('Examinee Records'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await mouse.moveTo(const Offset(900, 500));
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 76);
      expect(find.byKey(const Key('consoleSignOut')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the menu button keeps the sidebar open and closes it again', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('consoleMenuButton')));
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 280);

      await tester.tap(find.byKey(const Key('consoleMenuButton')));
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 76);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Sign out asks for confirmation and Cancel keeps the session', (
      tester,
    ) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('consoleMenuButton')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('consoleSignOut')));
      await tester.pumpAndSettle();
      expect(find.text('Log out?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Log out?'), findsNothing);
      expect(find.byKey(const Key('consoleRail')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the Dashboard banner shows a total tile per examination', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('EXAMINATION OVERVIEW'), findsOneWidget);
      expect(find.text('ADMISSION TEST RESULTS'), findsOneWidget);
      expect(find.text('QTM RESULTS'), findsOneWidget);
      expect(find.text('TAT RESULTS'), findsOneWidget);
    });

    testWidgets('a narrow window uses the green drawer with Sign out inside', (
      tester,
    ) async {
      await _pump(tester, size: const Size(390, 844));
      expect(find.byKey(const Key('consoleRail')), findsNothing);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsOneWidget);
      expect(find.byKey(const Key('consoleSignOut')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
