import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/local_batch_repository.dart';
import 'package:guidegrade/core/services/local_storage_service.dart';
import 'package:guidegrade/core/state/app_state.dart';
import 'package:guidegrade/features/exam/screens/answer_key_entry_screen.dart';
import 'package:guidegrade/models/answer_key.dart';

class _Storage implements LocalStorageService {
  @override
  Future<void> saveAnswerKeys(Map<String, AnswerKey> answerKeys) async {}
  @override
  Future<Map<String, AnswerKey>> loadAnswerKeys() async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tmp;
  late AppState appState;

  setUp(() => tmp = Directory.systemTemp.createTempSync('ak_cat_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Finder k(String key) => find.byKey(ValueKey(key));

  /// Opens the screen from a launcher route so Save (which pops) can be tested.
  Future<void> open(WidgetTester tester, String examCode, {AnswerKey? existing}) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appState = AppState(
      batchRepository: LocalBatchRepository(rootOverride: Directory('${tmp.path}/repo')),
      localStorage: _Storage(),
    )..setActiveExamCode(examCode);
    if (existing != null) appState.answerKeys[examCode] = existing;
    await tester.pumpWidget(MaterialApp(
      // Above the Navigator, so pushed routes (the screen) see it too.
      builder: (context, child) => AppStateScope(notifier: appState, child: child!),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AnswerKeyEntryScreen()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The bubble `choice` of item `Section 1|n`.
  Finder bubble(int n, String choice) =>
      find.descendant(of: k('row-Section 1|$n'), matching: find.text(choice));

  Future<void> selectCategory(WidgetTester tester, String label) async {
    await tester.tap(k('category-brush'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(label).last);
    await tester.pumpAndSettle();
  }

  Color? bubbleColor(WidgetTester tester, int n, String choice) {
    final container = find.ancestor(of: bubble(n, choice), matching: find.byType(Container)).first;
    return ((tester.widget<Container>(container)).decoration as BoxDecoration).color;
  }

  group('AT: header category control + assign-as-you-tap', () {
    testWidgets('a category pill replaces the title, and the per-row dropdowns are gone', (tester) async {
      await open(tester, 'AT');

      expect(k('category-brush'), findsOneWidget);
      expect(find.text('Verbal Comprehension'), findsOneWidget, reason: 'starts on the first category');
      expect(find.textContaining('Answer Key — AT'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is DropdownButton), findsOneWidget, reason: 'only the header one');
      expect(k('category-hint'), findsWidgets);
      for (final c in ['VC 0', 'VR 0', 'FR 0', 'QR 0']) {
        expect(find.text(c), findsOneWidget, reason: c);
      }
    });

    testWidgets('tapping an answer picks it AND assigns the item to the selected category', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D'));
      await tester.pump();

      expect(find.descendant(of: k('assigned-Section 1|1'), matching: find.text('VC')), findsOneWidget);
      expect(find.text('VC 1'), findsOneWidget);
      expect(find.textContaining('1/72 answered'), findsOneWidget);
    });

    testWidgets('each category has its own colour on its selected answers', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D')); // VC
      await selectCategory(tester, 'Verbal Reasoning');
      await tester.tap(bubble(2, 'K')); // VR
      await selectCategory(tester, 'Figural Reasoning');
      await tester.tap(bubble(4, 'H')); // FR
      await selectCategory(tester, 'Quantitative Reasoning');
      await tester.tap(bubble(3, 'D')); // QR
      await tester.pump();

      final colours = {
        for (final e in {1: 'D', 2: 'K', 4: 'H', 3: 'D'}.entries) e.key: bubbleColor(tester, e.key, e.value),
      };
      expect(colours.values.toSet().length, 4, reason: 'four different colours: $colours');
      expect(colours.values.every((c) => c != null && c != const Color(0xFFF1F5F4)), isTrue);
    });

    testWidgets('after switching category, items assigned to the earlier one are locked', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D')); // assigned to VC
      await selectCategory(tester, 'Verbal Reasoning');

      // Locked: tapping a different answer on item 1 does nothing.
      await tester.tap(bubble(1, 'A'), warnIfMissed: false);
      await tester.pump();
      expect(find.textContaining('1/72 answered'), findsOneWidget);
      expect(find.descendant(of: k('assigned-Section 1|1'), matching: find.text('VC')), findsOneWidget);
      expect(
        find.descendant(of: k('row-Section 1|1'), matching: find.byType(IgnorePointer)),
        findsWidgets,
        reason: 'the locked row ignores touches',
      );

      // An unassigned item is free: it goes to VR.
      await tester.tap(bubble(2, 'K'));
      await tester.pump();
      expect(find.descendant(of: k('assigned-Section 1|2'), matching: find.text('VR')), findsOneWidget);
      expect(find.text('VR 1'), findsOneWidget);
      expect(find.text('VC 1'), findsOneWidget);
    });

    testWidgets('switching back to the category makes its items editable again', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D'));
      await selectCategory(tester, 'Verbal Reasoning');
      await selectCategory(tester, 'Verbal Comprehension');

      await tester.tap(bubble(1, 'A'));
      await tester.pump();
      expect(find.textContaining('1/72 answered'), findsOneWidget);
      // Changed from D to A, still assigned to VC.
      expect(find.text('VC 1'), findsOneWidget);
    });

    testWidgets('tapping the picked answer again clears it and releases the item', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D'));
      await tester.pump();
      await tester.tap(bubble(1, 'D'));
      await tester.pump();

      expect(find.textContaining('0/72 answered'), findsOneWidget);
      expect(k('assigned-Section 1|1'), findsNothing);
      expect(find.text('VC 0'), findsOneWidget);
    });

    testWidgets('long-pressing an item number releases it from its category but keeps the answer', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D'));
      await tester.pump();

      await tester.longPress(find.descendant(of: k('row-Section 1|1'), matching: find.text('1.')));
      await tester.pump();

      expect(k('assigned-Section 1|1'), findsNothing);
      expect(find.textContaining('1/72 answered'), findsOneWidget, reason: 'the answer stays');
      expect(find.text('VC 0'), findsOneWidget);
    });

    testWidgets('a locked item cannot be released from another category', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D')); // VC
      await selectCategory(tester, 'Verbal Reasoning');

      await tester.longPress(find.descendant(of: k('row-Section 1|1'), matching: find.text('1.')), warnIfMissed: false);
      await tester.pump();
      expect(find.descendant(of: k('assigned-Section 1|1'), matching: find.text('VC')), findsOneWidget);
    });

    testWidgets('the counter chips switch the selected category too', (tester) async {
      await open(tester, 'AT');
      await tester.tap(k('chip-FR'));
      await tester.pumpAndSettle();
      expect(find.text('Figural Reasoning'), findsOneWidget, reason: 'pill now shows FR');

      await tester.tap(bubble(4, 'H'));
      await tester.pump();
      expect(find.descendant(of: k('assigned-Section 1|4'), matching: find.text('FR')), findsOneWidget);
    });

    testWidgets('the dropdown lists all four categories with their counts', (tester) async {
      await open(tester, 'AT');
      await tester.tap(k('category-brush'));
      await tester.pumpAndSettle();
      for (final label in ['Verbal Comprehension', 'Verbal Reasoning', 'Figural Reasoning', 'Quantitative Reasoning']) {
        expect(find.textContaining(label), findsWidgets, reason: label);
      }
    });
  });

  group('saving and loading', () {
    testWidgets('Save stores the answers AND the categories assigned on the way', (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D'));
      await selectCategory(tester, 'Verbal Reasoning');
      await tester.tap(bubble(2, 'K'));
      await tester.pump();

      await tester.tap(find.text('SAVE ANSWER KEY'));
      await tester.pumpAndSettle();

      final saved = appState.answerKeys['AT']!;
      expect(saved.correctChoices, {'Section 1|1': 'D', 'Section 1|2': 'K'});
      expect(saved.itemCategories, {'Section 1|1': 'VC', 'Section 1|2': 'VR'});
    });

    testWidgets('a saved key reopens with its assignments, locked against the selected category', (tester) async {
      await open(
        tester,
        'AT',
        existing: const AnswerKey(
          examCode: 'AT',
          correctChoices: {'Section 1|1': 'D', 'Section 1|2': 'K'},
          itemCategories: {'Section 1|1': 'VC', 'Section 1|2': 'VR'},
        ),
      );
      expect(find.text('VC 1'), findsOneWidget);
      expect(find.text('VR 1'), findsOneWidget);
      expect(find.textContaining('2/72 answered'), findsOneWidget);

      // Brush starts on VC: item 2 (VR) is locked, item 1 (VC) is editable.
      await tester.tap(bubble(2, 'F'), warnIfMissed: false);
      await tester.pump();
      expect(find.textContaining('2/72 answered'), findsOneWidget);
      await tester.tap(bubble(1, 'A'));
      await tester.pump();
      expect(find.text('VC 1'), findsOneWidget);
    });

    testWidgets('items left unassigned are not given a category on save (scoring falls back to the official map)',
        (tester) async {
      await open(tester, 'AT');
      await tester.tap(bubble(1, 'D'));
      await tester.tap(bubble(2, 'K'), warnIfMissed: false); // still VC brush: assigned VC
      await tester.longPress(find.descendant(of: k('row-Section 1|2'), matching: find.text('2.')));
      await tester.pump();
      await tester.tap(find.text('SAVE ANSWER KEY'));
      await tester.pumpAndSettle();

      final saved = appState.answerKeys['AT']!;
      expect(saved.itemCategories.containsKey('Section 1|2'), isFalse);
      expect(saved.correctChoices['Section 1|2'], 'K');
    });
  });

  group('other exams are unchanged', () {
    testWidgets('TAT: no category pill, no hint, original title, original green selection', (tester) async {
      await open(tester, 'TAT');
      expect(find.textContaining('Answer Key — TAT'), findsOneWidget);
      expect(k('category-brush'), findsNothing);
      expect(k('category-hint'), findsNothing);
      expect(find.byWidgetPredicate((w) => w is DropdownButton), findsNothing);
    });
  });
}
