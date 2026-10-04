import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/features/admin/screens/admin_dashboard_screen.dart';

void main() {
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AdminDashboardScreen()));
    await tester.pump();
  }

  testWidgets('1. Restore Management appears as a tile on the Admin dashboard, alongside '
      'User Management and System Logs', (tester) async {
    await pumpScreen(tester);

    expect(find.text('User Management'), findsOneWidget);
    expect(find.text('System Logs'), findsOneWidget);
    expect(find.text('Restore Management'), findsOneWidget);
  });

  testWidgets('narrow console fits and opens the existing restore route', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: const AdminDashboardScreen(),
      routes: {
        '/restore-management': (_) => const Scaffold(body: Text('Restore destination')),
      },
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Results'), findsNothing);
    expect(find.text('Analytics'), findsNothing);
    await tester.ensureVisible(find.text('Restore Management'));
    await tester.tap(find.text('Restore Management'));
    await tester.pumpAndSettle();
    expect(find.text('Restore destination'), findsOneWidget);
  });
}
