import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_home_screen.dart';
import 'package:guidegrade/shared/widgets/console_task_card.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_dashboard_service.dart';

class _EmptyDashboard implements GuidanceWebDashboardService {
  @override
  Future<GuidanceDashboardData> load() async =>
      GuidanceDashboardData([], [], []);
}

void main() {
  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets(
      'Guidance console fits ${size.width} and keeps sidebar navigation',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final state = AppState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) =>
                AppStateScope(notifier: state, child: child!),
            home: GuidanceWebHomeScreen(dashboardService: _EmptyDashboard()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ConsoleTaskCard), findsNothing);
        expect(
          find.byKey(const ValueKey('dashboard.chart.Admission Test')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (size.width < 900) {
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pumpAndSettle();
          expect(find.byType(Drawer), findsOneWidget);
          await tester.tap(
            find.descendant(
              of: find.byType(Drawer),
              matching: find.text('Dashboard'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(ConsoleTaskCard), findsNothing);
          expect(tester.takeException(), isNull);
        }
      },
    );
  }
}
