import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/features/guidance_web/screens/guidance_web_dashboard_view.dart';
import 'package:guidegrade/features/guidance_web/services/guidance_web_dashboard_service.dart';

class FakeDashboardService implements GuidanceWebDashboardService {
  FakeDashboardService(this.loader);
  final Future<GuidanceDashboardData> Function() loader;
  @override
  Future<GuidanceDashboardData> load() => loader();
}

void main() {
  testWidgets('charts refresh automatically without a refresh button', (
    tester,
  ) async {
    var calls = 0;
    var scores = <int>[];
    final service = FakeDashboardService(() async {
      calls++;
      return GuidanceDashboardData(scores, [], []);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuidanceWebDashboardView(
            service: service,
            refreshInterval: const Duration(seconds: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Refresh statistics'), findsNothing);
    expect(find.text('0 graded results'), findsNWidgets(3));
    scores = [58];
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('1 graded results'), findsOneWidget);
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 2);
  });
  test('Admission boundaries use four categories with B 55–60', () {
    final data = GuidanceDashboardData(
      [0, 54, 55, 56, 57, 60, 61, 64, 65, 72, -1, 73],
      [],
      [],
    );
    expect(data.charts.map((c) => c.title), ['Admission Test', 'QTM', 'TAT']);
    expect(data.charts.first.labels, ['A', 'B', 'C', 'D']);
    expect(data.charts.first.counts, [2, 4, 2, 2]);
  });
  test(
    'QTM includes every boundary, including 60, and rejects invalid scores',
    () {
      final data = GuidanceDashboardData([], [
        0,
        9,
        10,
        19,
        20,
        29,
        30,
        39,
        40,
        49,
        50,
        60,
        -1,
        61,
      ], []);
      expect(data.charts[1].labels, [
        '0–9',
        '10–19',
        '20–29',
        '30–39',
        '40–49',
        '50–60',
      ]);
      expect(data.charts[1].counts, List.filled(6, 2));
    },
  );
  test(
    'TAT includes every boundary, including 160, and rejects invalid scores',
    () {
      final data = GuidanceDashboardData([], [], [
        0,
        19,
        20,
        39,
        40,
        59,
        60,
        79,
        80,
        99,
        100,
        119,
        120,
        139,
        140,
        160,
        -1,
        161,
      ]);
      expect(data.charts[2].labels, [
        '0–19',
        '20–39',
        '40–59',
        '60–79',
        '80–99',
        '100–119',
        '120–139',
        '140–160',
      ]);
      expect(data.charts[2].counts, List.filled(8, 2));
    },
  );
  test('empty data keeps every zero-count category', () {
    final data = GuidanceDashboardData([], [], []);
    expect(data.charts.map((c) => c.counts.length), [4, 6, 8]);
    expect(data.charts.every((c) => c.counts.every((n) => n == 0)), isTrue);
  });
  testWidgets('loading changes to three empty chart cards without shortcuts', (
    tester,
  ) async {
    final completer = Completer<GuidanceDashboardData>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuidanceWebDashboardView(
            refreshInterval: null,
            service: FakeDashboardService(() => completer.future),
          ),
        ),
      ),
    );
    expect(find.text('Loading examination statistics…'), findsOneWidget);
    completer.complete(GuidanceDashboardData([], [], []));
    await tester.pumpAndSettle();
    for (final title in ['Admission Test', 'QTM', 'TAT']) {
      expect(find.byKey(ValueKey('dashboard.chart.$title')), findsOneWidget);
    }
    expect(find.textContaining('No eligible results yet.'), findsNWidgets(3));
    for (final label in [
      'Results',
      'Examinee Records',
      'Completed Batch',
      'Analytics',
      'Export',
    ]) {
      expect(find.text(label), findsNothing);
    }
  });
  testWidgets('read failure shows error; retry loads genuine service result', (
    tester,
  ) async {
    var calls = 0;
    final service = FakeDashboardService(() async {
      if (++calls == 1) throw StateError('private backend details');
      return GuidanceDashboardData([55], [60], [160]);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GuidanceWebDashboardView(
            refreshInterval: null,
            service: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Statistics could not be loaded.'),
      findsOneWidget,
    );
    expect(find.textContaining('private backend'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('1 graded results'), findsNWidgets(3));
    expect(calls, 2);
  });
  testWidgets('statistics explanation is accessible on a narrow screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: Scaffold(
          body: GuidanceWebDashboardView(
            service: FakeDashboardService(
              () async => GuidanceDashboardData([55], [60], [160]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Updates automatically'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byTooltip('About these statistics'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('About these statistics'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Archived attempts and soft-deleted scans'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  for (final width in [320.0, 390.0, 768.0, 1280.0, 1440.0]) {
    testWidgets('chart layout has no overflow at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GuidanceWebDashboardView(
              refreshInterval: null,
              service: FakeDashboardService(
                () async => GuidanceDashboardData([55], [60], [160]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cards = [
        for (final title in ['Admission Test', 'QTM', 'TAT'])
          tester.getRect(find.byKey(ValueKey('dashboard.chart.$title'))),
      ];
      expect(cards[0].bottom, lessThan(cards[1].top));
      expect(cards[1].bottom, lessThan(cards[2].top));
      expect(cards[0].width, closeTo(cards[2].width, 0.01));
      await tester.scrollUntilVisible(
        find.text('TAT'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
