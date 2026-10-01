import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/batch_repository.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/archive/screens/cloud_archive_screen.dart';
import 'package:guidegrade/models/local_batch.dart';

class _FakeBatchRepository implements BatchRepository {
  _FakeBatchRepository(this.batches);
  final List<LocalBatch> batches;
  @override
  Future<List<LocalBatch>> getBatches() async => batches;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LocalBatch _batch(String code, String examCode, String description) =>
    LocalBatch(
      id: 'id-$code',
      batchCode: code,
      examCode: examCode,
      examTitle: examCode,
      description: description,
      expectedCount: 10,
      status: 'Completed',
      createdByUid: 'u',
      createdByName: 'U',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpScreen(WidgetTester tester, List<LocalBatch> batches) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final appState = AppState(batchRepository: _FakeBatchRepository(batches));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppStateScope(notifier: appState, child: child!),
        home: const CloudArchiveScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapType(WidgetTester tester, String code) async {
    await tester.tap(find.byKey(Key('archiveType.$code')));
    await tester.pumpAndSettle();
  }

  final mixed = [
    _batch('AT-1', 'AT', 'Admission batch one'),
    _batch('TAT-1', 'TAT', 'Teaching batch one'),
    _batch('QTM-1', 'QTM', 'Math batch one'),
    _batch('AT-2', 'AT', 'Admission batch two'),
  ];

  const allDescriptions = [
    'Admission batch one',
    'Admission batch two',
    'Teaching batch one',
    'Math batch one',
  ];

  testWidgets('initially shows all batches and inline exam filters', (
    tester,
  ) async {
    await pumpScreen(tester, mixed);

    expect(find.byKey(const Key('archiveType.QTM')), findsOneWidget);
    expect(find.byKey(const Key('archiveType.TAT')), findsOneWidget);
    expect(find.byKey(const Key('archiveType.AT')), findsOneWidget);
    expect(find.byKey(const Key('archiveType.OTHER')), findsNothing);
    for (final d in allDescriptions) {
      expect(find.text(d), findsOneWidget);
    }
    double x(String c) =>
        tester.getTopLeft(find.byKey(Key('archiveType.$c'))).dx;
    expect(x('ALL'), lessThan(x('AT')));
    expect(x('AT'), lessThan(x('QTM')));
    expect(x('QTM'), lessThan(x('TAT')));
  });

  testWidgets('tapping a type lists only that type\'s batches', (tester) async {
    await pumpScreen(tester, mixed);

    await tapType(tester, 'QTM');
    expect(find.text('Math batch one'), findsOneWidget);
    expect(find.text('Teaching batch one'), findsNothing);
    expect(find.text('Admission batch one'), findsNothing);
    expect(find.byKey(const Key('archiveType.QTM')), findsOneWidget);

    await tapType(tester, 'TAT');
    expect(find.text('Teaching batch one'), findsOneWidget);
    expect(find.text('Math batch one'), findsNothing);
    expect(find.text('Admission batch one'), findsNothing);

    await tapType(tester, 'AT');
    expect(find.text('Admission batch one'), findsOneWidget);
    expect(find.text('Admission batch two'), findsOneWidget);
    expect(find.text('Math batch one'), findsNothing);
    expect(find.text('Teaching batch one'), findsNothing);
  });

  testWidgets('All orders batches by newest saved date first', (tester) async {
    await pumpScreen(tester, [
      _batch(
        'OLD',
        'AT',
        'Older batch',
      ).copyWith(updatedAt: DateTime(2026, 1, 1)),
      _batch(
        'NEW',
        'TAT',
        'Newest batch',
      ).copyWith(updatedAt: DateTime(2026, 3, 1)),
      _batch(
        'MID',
        'QTM',
        'Middle batch',
      ).copyWith(updatedAt: DateTime(2026, 2, 1)),
    ]);
    double y(String label) => tester.getTopLeft(find.text(label)).dy;
    expect(y('Newest batch'), lessThan(y('Middle batch')));
    expect(y('Middle batch'), lessThan(y('Older batch')));
  });

  testWidgets('All restores every batch after filtering', (tester) async {
    await pumpScreen(tester, mixed);
    await tapType(tester, 'AT');
    await tapType(tester, 'ALL');
    for (final description in allDescriptions) {
      expect(find.text(description), findsOneWidget);
    }
  });

  testWidgets(
    'a batch shows description larger than the batch code, plus its other info',
    (tester) async {
      await pumpScreen(tester, mixed);
      await tapType(tester, 'QTM');

      final description = tester
          .widget<Text>(find.text('Math batch one'))
          .style!;
      final code = tester.widget<Text>(find.text('QTM-1')).style!;
      expect(description.fontWeight, FontWeight.w800);
      expect(description.fontSize!, greaterThan(code.fontSize!));
      expect(find.textContaining('Scans:'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
    },
  );

  testWidgets(
    'a type with no batches shows an empty message, not other types\' batches',
    (tester) async {
      await pumpScreen(tester, [_batch('AT-1', 'AT', 'Only admission')]);

      await tapType(tester, 'QTM');

      expect(find.text('No archived QTM batches yet.'), findsOneWidget);
      expect(find.text('Only admission'), findsNothing);
    },
  );

  testWidgets('a batch with an unknown exam code stays reachable through All', (
    tester,
  ) async {
    await pumpScreen(tester, [
      _batch('X-1', 'XYZ', 'Odd batch'),
      _batch('AT-1', 'AT', 'Admission'),
    ]);

    await tapType(tester, 'AT');
    expect(find.text('Odd batch'), findsNothing);
    await tapType(tester, 'ALL');
    expect(find.text('Odd batch'), findsOneWidget);
    expect(find.text('Admission'), findsOneWidget);
  });

  testWidgets('no batches at all still shows the original empty state', (
    tester,
  ) async {
    await pumpScreen(tester, const []);
    expect(find.text('No saved batches yet'), findsOneWidget);
    expect(find.byKey(const Key('archiveType.QTM')), findsNothing);
  });
}
