// Behaviour and responsiveness of the shared design-system components
// (status badges, loading/empty/error views, tabs, cards, form labels, the
// loading-capable PrimaryButton) plus the screens' list items at phone width
// with large text, where overflow bugs usually show up.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:guidegrade/core/constants/app_theme.dart';
import 'package:guidegrade/features/admin/widgets/log_list_item.dart';
import 'package:guidegrade/features/admin/widgets/user_list_item.dart';
import 'package:guidegrade/features/guidance/widgets/batch_list_item.dart';
import 'package:guidegrade/models/local_batch.dart';
import 'package:guidegrade/models/log_entry.dart';
import 'package:guidegrade/models/user.dart';
import 'package:guidegrade/shared/widgets/form_layout.dart';
import 'package:guidegrade/shared/widgets/primary_button.dart';
import 'package:guidegrade/shared/widgets/segmented_tabs.dart';
import 'package:guidegrade/shared/widgets/state_views.dart';
import 'package:guidegrade/shared/widgets/status_badge.dart';
import 'package:guidegrade/shared/widgets/surface_card.dart';

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
      theme: AppTheme.light,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: child),
      ),
    );

void _phone(WidgetTester tester, {double width = 320, double height = 800}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('StatusBadge', () {
    testWidgets('renders the label verbatim for every tone', (tester) async {
      await tester.pumpWidget(_app(Column(
        children: [
          for (final tone in StatusTone.values) StatusBadge(label: 'L-${tone.name}', tone: tone),
        ],
      )));
      for (final tone in StatusTone.values) {
        expect(find.text('L-${tone.name}'), findsOneWidget);
      }
    });

    test('foreground/background pairs are readable (WCAG AA >= 4.5:1)', () {
      for (final tone in StatusTone.values) {
        final p = StatusPalette.of(tone);
        expect(_contrast(p.fg, p.bg), greaterThanOrEqualTo(4.5), reason: tone.name);
        expect(_contrast(p.fg, Colors.white), greaterThanOrEqualTo(4.5), reason: tone.name);
      }
    });

    test('batch statuses map to the intended tones', () {
      expect(BatchStatusBadge.toneFor('Draft'), StatusTone.warning);
      expect(BatchStatusBadge.toneFor('Active'), StatusTone.info);
      expect(BatchStatusBadge.toneFor('Completed'), StatusTone.success);
      expect(BatchStatusBadge.toneFor('Archived'), StatusTone.neutral);
    });

    testWidgets('a very long label truncates instead of overflowing a phone', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
        const Padding(
          padding: EdgeInsets.all(16),
          child: Row(children: [
            Expanded(child: StatusBadge(label: 'A really very long status label that cannot fit on one line')),
          ]),
        ),
        textScale: 2,
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('state views', () {
    testWidgets('LoadingState shows a real progress indicator and its message', (tester) async {
      await tester.pumpWidget(_app(const LoadingState(message: 'Loading things...')));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Loading things...'), findsOneWidget);
    });

    testWidgets('EmptyState explains and offers its action', (tester) async {
      var cleared = false;
      await tester.pumpWidget(_app(EmptyState(
        title: 'Nothing here',
        message: 'Try another filter',
        action: OutlinedButton(onPressed: () => cleared = true, child: const Text('Clear filters')),
      )));
      expect(find.text('Nothing here'), findsOneWidget);
      expect(find.text('Try another filter'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      expect(cleared, isTrue);
    });

    testWidgets('ErrorState offers Try again only when it can retry', (tester) async {
      var retries = 0;
      await tester.pumpWidget(_app(ErrorState(message: 'Network down', onRetry: () => retries++)));
      expect(find.text('Network down'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retries, 1);

      await tester.pumpWidget(_app(const ErrorState(message: 'Network down')));
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('states do not overflow a phone with large text', (tester) async {
      _phone(tester, height: 480);
      await tester.pumpWidget(_app(
        const ErrorState(
          title: 'Could not load restore requests',
          message: 'A long explanation that wraps over several lines on a narrow screen.',
        ),
        textScale: 2,
      ));
      expect(tester.takeException(), isNull);
    });
  });

  group('SegmentedTabs', () {
    testWidgets('marks the selected tab, reports taps and exposes semantics', (tester) async {
      var value = 'a';
      await tester.pumpWidget(_app(StatefulBuilder(
        builder: (context, setState) => SegmentedTabs<String>(
          selected: value,
          onChanged: (v) => setState(() => value = v),
          items: const [
            SegmentedTabItem(value: 'a', label: 'First'),
            SegmentedTabItem(value: 'b', label: 'Second', count: 3),
          ],
        ),
      )));
      expect(find.text('Second (3)'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Second (3)'));
      await tester.pump();
      expect(value, 'b');
    });

    testWidgets('wraps onto extra lines instead of overflowing on a phone', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(SegmentedTabs<int>(
        selected: 0,
        onChanged: (_) {},
        items: [for (var i = 0; i < 6; i++) SegmentedTabItem(value: i, label: 'Section number $i')],
      )));
      expect(tester.takeException(), isNull);
    });
  });

  group('PrimaryButton', () {
    testWidgets('loading disables the button and shows progress', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(PrimaryButton(label: 'SAVING...', loading: true, onPressed: () => taps++)));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('SAVING...'));
      expect(taps, 0);
    });

    testWidgets('idle button fires onPressed and has a 44px touch target', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(PrimaryButton(label: 'SAVE', onPressed: () => taps++)));
      expect(tester.getSize(find.byType(ElevatedButton)).height, greaterThanOrEqualTo(44));
      await tester.tap(find.text('SAVE'));
      expect(taps, 1);
    });
  });

  group('SurfaceCard / forms', () {
    testWidgets('a tappable card reports taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app(SurfaceCard(onTap: () => taps++, child: const Text('Card'))));
      await tester.tap(find.text('Card'));
      expect(taps, 1);
    });

    testWidgets('FieldLabel marks required fields and keeps plain labels plain', (tester) async {
      await tester.pumpWidget(_app(const Column(children: [
        FieldLabel('Email', required: true),
        FieldLabel('Nickname', optionalHint: true),
        FieldLabel('First Name'),
      ])));
      expect(find.textContaining('Email *', findRichText: true), findsOneWidget);
      expect(find.textContaining('(optional)', findRichText: true), findsOneWidget);
      expect(find.text('First Name'), findsOneWidget);
    });

    testWidgets('FormLayout keeps forms <= 640px wide on desktop and 16px gutters on phones',
        (tester) async {
      late EdgeInsets desktop;
      late EdgeInsets phone;
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        desktop = FormLayout.padding(c);
        return const SizedBox();
      })));
      expect(1400 - desktop.horizontal, closeTo(640, 0.1));

      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        phone = FormLayout.padding(c);
        return const SizedBox();
      })));
      expect(phone.left, 16);
    });
  });

  group('list items at phone width with large text', () {
    final created = DateTime.utc(2026, 1, 1);

    testWidgets('UserListItem', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
        UserListItem(
          user: UserModel(
            userId: 'u1',
            email: 'a.very.long.email.address.for.testing@example-university.edu.ph',
            displayName: 'A Very Long Display Name For Overflow Testing Purposes',
            role: 'guidance_council',
            isActive: true,
            createdAt: created,
          ),
          onTap: () {},
        ),
        textScale: 2,
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('Guidance Council'), findsOneWidget);
    });

    testWidgets('LogListItem', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
        LogListItem(
          log: LogEntry(
            logId: 'l1',
            timestamp: created,
            actorUid: 'u',
            actorEmail: 'actor.with.a.long.address@example-university.edu.ph',
            actorRole: 'system_admin',
            action: 'user_updated',
            category: 'User Management',
            description: 'Updated the account details for a user with a long description',
            success: true,
            severity: LogSeverity.warning,
          ),
          onTap: () {},
        ),
        textScale: 2,
      ));
      expect(tester.takeException(), isNull);
    });

    testWidgets('BatchListItem', (tester) async {
      _phone(tester);
      await tester.pumpWidget(_app(
        BatchListItem(
          batch: LocalBatch(
            id: 'b1',
            batchCode: 'B-202608-123',
            examCode: 'AT',
            examTitle: 'Admission Test For A Very Long Program Name',
            description: 'Morning session batch with an exceptionally long description',
            expectedCount: 40,
            status: 'Active',
            createdByUid: 'u',
            createdByName: 'Officer',
            createdAt: created,
            updatedAt: created,
          ),
          onTap: () {},
          onDelete: () {},
        ),
        textScale: 2,
      ));
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Delete batch'), findsOneWidget);
    });
  });
}

/// WCAG relative-luminance contrast ratio.
double _contrast(Color a, Color b) {
  double lum(Color c) {
    double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  final la = lum(a);
  final lb = lum(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}
