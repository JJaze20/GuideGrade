import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';
import 'package:guidegrade/core/omr/rescan_comparison.dart';
import 'package:guidegrade/features/exam/screens/rescan_comparison_screen.dart';
import 'package:guidegrade/models/answer_key.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/omr_scan_result.dart';

// 1x1 PNG so images have something valid to decode.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
ImageProvider get _img => MemoryImage(_png);

/// AT: 3 changes (blank, multiple marks, other choice) out of a full sheet.
RescanComparison _comparison() {
  final tpl = omrTemplates['AT']!;
  final items = <OmrItemResult>[];
  final key = <String, String>{};
  for (final s in tpl.sections) {
    for (final n in (s.items.keys.toList()..sort())) {
      final c = s.items[n]!.first.choice;
      key[AnswerKey.keyFor(s.name, n)] = c;
      items.add(OmrItemResult(sectionName: s.name, itemNumber: n, markedChoice: c));
    }
  }
  final original = LocalScan(
    id: 's1',
    imageFileName: 'images/s1.enc',
    capturedAt: DateTime.utc(2026, 8, 1),
    decoded: OmrScanResult(examCode: 'AT', items: items),
  );
  final candidate = OmrScanResult(examCode: 'AT', items: [
    OmrItemResult(sectionName: items[0].sectionName, itemNumber: items[0].itemNumber, markedChoice: null),
    OmrItemResult(
        sectionName: items[1].sectionName, itemNumber: items[1].itemNumber, markedChoice: null, isAmbiguous: true),
    for (final i in items.skip(2)) i,
  ]);
  return RescanComparison.build(
    original: original,
    candidate: candidate,
    answerKey: AnswerKey(examCode: 'AT', correctChoices: key),
  );
}

RescanComparisonData _data({
  bool originalSheet = true,
  bool originalCrops = true,
  bool candidateSheet = true,
  bool candidateCrops = true,
  String? ocrLast = 'Reyes',
  String? ocrFirst = 'Ben',
  bool ocrWillBeSaved = false,
}) =>
    RescanComparisonData(
      comparison: _comparison(),
      originalExaminee: const ExamineeInfo(
        firstName: 'Ana',
        lastName: 'Cruz',
        middleName: '',
        examineeNumber: 'EX-42',
      ),
      originalCapturedAt: DateTime.utc(2026, 8, 1, 12),
      originalSheet: originalSheet ? _img : null,
      originalCropLast: originalCrops ? _img : null,
      originalCropFirst: originalCrops ? _img : null,
      candidateSheet: candidateSheet ? _img : null,
      candidateCropLast: candidateCrops ? _img : null,
      candidateCropFirst: candidateCrops ? _img : null,
      ocrLastName: ocrLast,
      ocrFirstName: ocrFirst,
      ocrSuggestionWillBeSaved: ocrWillBeSaved,
    );

void main() {
  RescanDecision? decision;

  /// Hosts the panel behind a button so its pop result can be observed.
  Future<void> open(
    WidgetTester tester, {
    required Future<RescanConfirmOutcome> Function() onConfirm,
    RescanComparisonData? data,
    Size size = const Size(420, 1800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    decision = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  decision = await Navigator.of(context).push<RescanDecision>(
                    MaterialPageRoute(
                      builder: (_) => RescanComparisonScreen(data: data ?? _data(), onConfirm: onConfirm),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  Future<void> tick(WidgetTester tester) async {
    await tester.ensureVisible(key('rescan-confirm-check'));
    await tester.tap(key('rescan-confirm-check'));
    await tester.pump();
  }

  bool confirmEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(key('rescan-confirm')).onPressed != null;

  group('what the panel shows', () {
    testWidgets('labels both versions and separates the saved identity from the unverified OCR guess', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved());

      expect(find.text('Original scan'), findsOneWidget);
      expect(find.text('New scan'), findsOneWidget);
      // Saved identity from the original record.
      expect(find.descendant(of: key('rescan-saved-name'), matching: find.textContaining('Ana')), findsOneWidget);
      expect(find.descendant(of: key('rescan-saved-id'), matching: find.text('EX-42')), findsOneWidget);
      // OCR is a clearly-labelled, unverified suggestion — a different widget from the saved name.
      expect(find.descendant(of: key('rescan-ocr-suggestion'), matching: find.textContaining('unverified')), findsOneWidget);
      expect(find.descendant(of: key('rescan-ocr-suggestion'), matching: find.textContaining('Ben')), findsOneWidget);
      expect(find.descendant(of: key('rescan-saved-name'), matching: find.textContaining('Ben')), findsNothing);
      expect(find.textContaining('not the saved name'), findsOneWidget);
    });

    testWidgets('shows both scores and every changed answer with its state', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved());

      final cmp = _comparison();
      expect(cmp.changedCount, 2);
      expect(find.textContaining('${cmp.originalScore!.rawScore} / ${cmp.originalScore!.maxScore}'), findsWidgets);
      expect(find.textContaining('${cmp.proposedScore!.rawScore} / ${cmp.proposedScore!.maxScore}'), findsWidgets);
      expect(find.text('2 of ${cmp.comparedItems} answers differ — advisory only'), findsOneWidget);
      for (final c in cmp.changes) {
        expect(key('rescan-change-${c.sectionName}|${c.itemNumber}'), findsOneWidget);
      }
      expect(find.textContaining('Blank'), findsWidgets);
      expect(find.textContaining('Multiple marks'), findsWidgets);
    });

    testWidgets('an already-named sheet says the OCR guess will NOT be saved', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved());
      final note = tester.widget<Text>(key('rescan-ocr-note'));
      expect(note.data, contains('will not be saved'));
      expect(note.data, isNot(contains('will be saved into')));
    });

    testWidgets('an unnamed sheet announces that confirming saves the OCR name into blank fields only', (tester) async {
      await open(tester, data: _data(ocrWillBeSaved: true), onConfirm: () async => const RescanConfirmOutcome.saved());
      final note = tester.widget<Text>(key('rescan-ocr-note'));
      expect(note.data, contains('will be saved into the blank name fields only'));
      expect(note.data, contains('Edit student'));
      // Still clearly labelled as an unverified guess.
      expect(find.descendant(of: key('rescan-ocr-suggestion'), matching: find.textContaining('unverified')), findsOneWidget);
    });

    testWidgets('a scanner reminder says answers/names are advisory and nothing is saved yet', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved());
      expect(find.textContaining('Nothing has been saved yet'), findsOneWidget);
      expect(find.textContaining('do not prove it'), findsOneWidget);
    });
  });

  group('confirmation is gated', () {
    testWidgets('the checkbox is unchecked by default with the exact wording, and Confirm is disabled', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved());

      expect(tester.widget<CheckboxListTile>(key('rescan-confirm-check')).value, isFalse);
      expect(
        find.text('I verified that this is the same original answer sheet for this examinee.'),
        findsOneWidget,
      );
      expect(confirmEnabled(tester), isFalse);
    });

    testWidgets('confirming replaces nothing until the box is ticked; then calls onConfirm and pops "saved"', (tester) async {
      var confirms = 0;
      await open(tester, onConfirm: () async {
        confirms++;
        return const RescanConfirmOutcome.saved();
      });

      await tester.ensureVisible(key('rescan-confirm'));
      await tester.tap(key('rescan-confirm'), warnIfMissed: false);
      await tester.pump();
      expect(confirms, 0, reason: 'a disabled Confirm does nothing');

      await tick(tester);
      expect(confirmEnabled(tester), isTrue);
      await tester.tap(key('rescan-confirm'));
      await tester.pumpAndSettle();

      expect(confirms, 1);
      expect(decision, RescanDecision.saved);
    });
  });

  group('leaving without saving', () {
    testWidgets('Cancel pops "cancelled" and never calls onConfirm', (tester) async {
      var confirms = 0;
      await open(tester, onConfirm: () async {
        confirms++;
        return const RescanConfirmOutcome.saved();
      });
      await tester.ensureVisible(key('rescan-cancel'));
      await tester.tap(key('rescan-cancel'));
      await tester.pumpAndSettle();
      expect(decision, RescanDecision.cancelled);
      expect(confirms, 0);
    });

    testWidgets('the close button and system back behave like Cancel', (tester) async {
      var confirms = 0;
      Future<RescanConfirmOutcome> confirm() async {
        confirms++;
        return const RescanConfirmOutcome.saved();
      }

      await open(tester, onConfirm: confirm);
      await tester.tap(key('rescan-close'));
      await tester.pumpAndSettle();
      expect(decision, RescanDecision.cancelled);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute(); // Android back
      await tester.pumpAndSettle();
      expect(decision, RescanDecision.cancelled);
      expect(confirms, 0);
    });

    testWidgets('Retake photo pops "retake" and never calls onConfirm', (tester) async {
      var confirms = 0;
      await open(tester, onConfirm: () async {
        confirms++;
        return const RescanConfirmOutcome.saved();
      });
      await tester.ensureVisible(key('rescan-retake'));
      await tester.tap(key('rescan-retake'));
      await tester.pumpAndSettle();
      expect(decision, RescanDecision.retake);
      expect(confirms, 0);
    });
  });

  group('saving', () {
    testWidgets('repeated Confirm taps while saving send exactly one request; back is ignored meanwhile', (tester) async {
      final gate = Completer<RescanConfirmOutcome>();
      var confirms = 0;
      await open(tester, onConfirm: () {
        confirms++;
        return gate.future;
      });
      await tick(tester);
      await tester.tap(key('rescan-confirm'));
      await tester.pump();
      await tester.tap(key('rescan-confirm'), warnIfMissed: false);
      await tester.pump();
      await tester.tap(key('rescan-confirm'), warnIfMissed: false);
      await tester.pump();
      expect(confirms, 1);
      expect(find.text('Saving…'), findsOneWidget);
      expect(confirmEnabled(tester), isFalse);

      await tester.binding.handlePopRoute(); // back while saving must not abandon the save
      await tester.pump();
      expect(decision, isNull);
      expect(find.byType(RescanComparisonScreen), findsOneWidget);

      gate.complete(const RescanConfirmOutcome.saved());
      await tester.pumpAndSettle();
      expect(decision, RescanDecision.saved);
      expect(confirms, 1);
    });

    testWidgets('a failed save keeps the panel open with the reason, and Confirm can be retried or the rescan cancelled',
        (tester) async {
      var confirms = 0;
      var fail = true;
      await open(tester, onConfirm: () async {
        confirms++;
        return fail
            ? const RescanConfirmOutcome.failed('Could not save the rescan: disk full')
            : const RescanConfirmOutcome.saved();
      });
      await tick(tester);
      await tester.tap(key('rescan-confirm'));
      await tester.pumpAndSettle();

      expect(find.byType(RescanComparisonScreen), findsOneWidget);
      expect(decision, isNull);
      expect(find.text('Could not save the rescan: disk full'), findsOneWidget);
      expect(confirmEnabled(tester), isTrue, reason: 'retry allowed, box still ticked');

      fail = false;
      await tester.tap(key('rescan-confirm'));
      await tester.pumpAndSettle();
      expect(confirms, 2);
      expect(decision, RescanDecision.saved);
    });

    testWidgets('after a failure the reviewer can still cancel', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.failed('nope'));
      await tick(tester);
      await tester.tap(key('rescan-confirm'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(key('rescan-cancel'));
      await tester.tap(key('rescan-cancel'));
      await tester.pumpAndSettle();
      expect(decision, RescanDecision.cancelled);
    });

    testWidgets('when the original changed or was deleted, retrying is disabled but Cancel/Retake remain', (tester) async {
      await open(tester, onConfirm: () async {
        return const RescanConfirmOutcome.failed('The original sheet was deleted while you were comparing.',
            canRetry: false);
      });
      await tick(tester);
      await tester.tap(key('rescan-confirm'));
      await tester.pumpAndSettle();

      expect(find.textContaining('deleted while you were comparing'), findsOneWidget);
      expect(confirmEnabled(tester), isFalse);
      expect(tester.widget<OutlinedButton>(key('rescan-retake')).onPressed, isNotNull);
      expect(tester.widget<TextButton>(key('rescan-cancel')).onPressed, isNotNull);
    });

    testWidgets('an exception from the save is shown as a failure, not a crash', (tester) async {
      await open(tester, onConfirm: () async => throw StateError('boom'));
      await tick(tester);
      await tester.tap(key('rescan-confirm'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save the rescan'), findsOneWidget);
      expect(decision, isNull);
    });
  });

  group('visual identity verification unavailable', () {
    for (final entry in {
      'the original sheet photo': _data(originalSheet: false),
      'the original name crops': _data(originalCrops: false),
      'the new sheet photo': _data(candidateSheet: false),
      'the new name crops': _data(candidateCrops: false),
    }.entries) {
      testWidgets('missing ${entry.key}: explained, no checkbox, Confirm can never be enabled', (tester) async {
        var confirms = 0;
        await open(tester, data: entry.value, onConfirm: () async {
          confirms++;
          return const RescanConfirmOutcome.saved();
        });

        expect(key('rescan-unavailable'), findsOneWidget);
        expect(find.textContaining('Visual identity verification is unavailable'), findsOneWidget);
        expect(find.textContaining(entry.key), findsWidgets);
        expect(key('rescan-confirm-check'), findsNothing, reason: 'no way to tick past it');
        expect(confirmEnabled(tester), isFalse);
        await tester.ensureVisible(key('rescan-confirm'));
        await tester.tap(key('rescan-confirm'), warnIfMissed: false);
        await tester.pump();
        expect(confirms, 0);
        // Cancel and Retake are still there.
        expect(tester.widget<TextButton>(key('rescan-cancel')).onPressed, isNotNull);
        expect(tester.widget<OutlinedButton>(key('rescan-retake')).onPressed, isNotNull);
      });
    }
  });

  group('layout and zoom', () {
    testWidgets('narrow screens stack the original above the new scan', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved(), size: const Size(400, 2400));
      final o = tester.getTopLeft(key('rescan-original-card'));
      final n = tester.getTopLeft(key('rescan-new-card'));
      expect(n.dy, greaterThan(o.dy));
      expect(n.dx, o.dx);
    });

    testWidgets('wide screens put the two scans side by side', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved(), size: const Size(1100, 1800));
      final o = tester.getTopLeft(key('rescan-original-card'));
      final n = tester.getTopLeft(key('rescan-new-card'));
      expect(n.dx, greaterThan(o.dx));
      expect(n.dy, o.dy);
    });

    testWidgets('tapping a sheet photo opens a full-screen zoomable view', (tester) async {
      await open(tester, onConfirm: () async => const RescanConfirmOutcome.saved());
      await tester.ensureVisible(key('rescan-sheet-original-sheet'));
      await tester.tap(key('rescan-sheet-original-sheet'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('Original sheet'), findsOneWidget);
    });
  });
}
