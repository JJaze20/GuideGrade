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
}
