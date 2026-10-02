import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/routes/app_routes.dart';
import 'package:guidegrade/shared/widgets/app_bottom_nav.dart';

/// Three stand-in tabs wired through the real [AppRoutes.tabRoute], switched
/// the way the bottom nav does it (AppRoutes.switchTab).
Widget _app() => MaterialApp(
      initialRoute: AppRoutes.staffHome,
      onGenerateRoute: (settings) {
        switch (settings.name) {
          case AppRoutes.staffHome:
            return AppRoutes.tabRoute(AppRoutes.staffHome, const _Tab('home', 'home'));
          case AppRoutes.examHub:
            return AppRoutes.tabRoute(AppRoutes.examHub, const _Tab('exams', 'sheet'));
          case AppRoutes.cloudArchive:
            return AppRoutes.tabRoute(AppRoutes.cloudArchive, const _Tab('archive', 'cloud'));
        }
        return null;
      },
    );

class _Tab extends StatelessWidget {
  final String name;
  final String navId;
  const _Tab(this.name, this.navId);

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(child: Text(name, key: ValueKey('tab-$name'))),
        // Each real tab screen owns its bottom nav, exactly like this.
        bottomNavigationBar: AppBottomNav(activeTab: navId),
      );
}

void main() {

  Future<void> go(WidgetTester tester, String route) async {
    final ctx = tester.element(find.byType(Scaffold).last);
    AppRoutes.switchTab(ctx, route);
    await tester.pump(); // push
    await tester.pump(const Duration(milliseconds: 100)); // part-way through
  }

  double x(WidgetTester tester, String tab) => tester.getCenter(find.byKey(ValueKey('tab-$tab'))).dx;

  setUp(() {
    // The tab order is process-wide state; start every test from Home.
    AppRoutes.tabRoute(AppRoutes.staffHome, const SizedBox());
  });

  testWidgets('going to a tab on the RIGHT: it enters from the right while the old page leaves to the left',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final centre = x(tester, 'home');

    await go(tester, AppRoutes.examHub);

    expect(x(tester, 'exams'), greaterThan(centre), reason: 'new tab still to the right of centre');
    expect(find.byKey(const ValueKey('tab-home')), findsOneWidget, reason: 'the page being left is still on screen');
    expect(x(tester, 'home'), lessThan(centre), reason: 'and is sliding out to the left');

    await tester.pumpAndSettle();
    expect(x(tester, 'exams'), centre);
    expect(find.byKey(const ValueKey('tab-home')), findsNothing);
  });

  testWidgets('going to a tab on the LEFT: it enters from the left while the old page leaves to the right',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await go(tester, AppRoutes.cloudArchive); // Home -> Archive
    await tester.pumpAndSettle();
    final centre = x(tester, 'archive');

    await go(tester, AppRoutes.examHub); // Archive -> Exams (left)

    expect(x(tester, 'exams'), lessThan(centre));
    expect(x(tester, 'archive'), greaterThan(centre));
    await tester.pumpAndSettle();
    expect(x(tester, 'exams'), centre);
  });

  testWidgets('the direction follows tab position, so Home -> Archive swipes right and back swipes left',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final centre = x(tester, 'home');

    await go(tester, AppRoutes.cloudArchive);
    expect(x(tester, 'archive'), greaterThan(centre));
    await tester.pumpAndSettle();

    await go(tester, AppRoutes.staffHome);
    expect(x(tester, 'home'), lessThan(centre));
    await tester.pumpAndSettle();
  });

  testWidgets('re-selecting the current tab fades in place: nothing moves sideways', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final centre = x(tester, 'home');

    await go(tester, AppRoutes.staffHome);
    // Old and new Home are both on screen while it fades; neither moves sideways.
    for (final e in tester.widgetList(find.byKey(const ValueKey('tab-home'))).toList().asMap().keys) {
      expect(tester.getCenter(find.byKey(const ValueKey('tab-home')).at(e)).dx, centre);
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tab-home')), findsOneWidget);
  });

  testWidgets('a page pushed on top of a tab later does not drag the tab sideways', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await go(tester, AppRoutes.examHub);
    await tester.pumpAndSettle();
    // Past the swipe's lifetime, cover the tab with an ordinary route.
    await tester.pump(const Duration(seconds: 1));
    final centre = x(tester, 'exams');

    Navigator.of(tester.element(find.byType(Scaffold).last)).push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('detail'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Material's own page transition nudges the page below by a fraction of the width;
    // what matters is that OUR slide stays out of it (it would be a full-width jump).
    expect((x(tester, 'exams') - centre).abs(), lessThan(centre), reason: 'no full-width slide-out');
    await tester.pumpAndSettle();
  });

  testWidgets('with history underneath, switching tabs still clears it and the new tab still swipes in',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final centre = x(tester, 'home');
    final nav = Navigator.of(tester.element(find.byType(Scaffold).last));
    nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('detail'))));
    await tester.pumpAndSettle();
    expect(nav.canPop(), isTrue);

    await go(tester, AppRoutes.examHub);

    expect(x(tester, 'exams'), greaterThan(centre), reason: 'enters from the right');
    await tester.pumpAndSettle();
    expect(nav.canPop(), isFalse, reason: 'no history left behind, as before');
    expect(find.text('detail'), findsNothing);
  });

  group('the bottom nav stays put while pages swipe', () {
    Rect visibleNav(WidgetTester tester) {
      // Several navs exist mid-swipe (old page, new page, fixed copy); only the
      // one actually on top and receiving touches is what the user sees.
      final top = find.byType(NavigationBar).hitTestable();
      expect(top, findsOneWidget, reason: 'exactly one nav is visible/tappable');
      return tester.getRect(top);
    }

    testWidgets('across the whole swipe the visible nav does not move, in either direction', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      final resting = visibleNav(tester);
      final screenWidth = tester.getSize(find.byType(MaterialApp)).width;
      expect(resting.left, 0);
      expect(resting.width, screenWidth);

      for (final route in [AppRoutes.examHub, AppRoutes.cloudArchive, AppRoutes.staffHome]) {
        final ctx = tester.element(find.byType(Scaffold).last);
        AppRoutes.switchTab(ctx, route);
        await tester.pump();
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 40));
          expect(visibleNav(tester), resting, reason: 'frame $i of the swipe to $route');
        }
        await tester.pumpAndSettle();
        expect(visibleNav(tester), resting);
      }
    });

    testWidgets('the nav is not frozen: it shows the destination tab as selected and stays tappable', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      AppRoutes.switchTab(tester.element(find.byType(Scaffold).last), AppRoutes.examHub);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      final nav = tester.widget<NavigationBar>(find.byType(NavigationBar).hitTestable());
      expect(nav.selectedIndex, 1, reason: 'Exams is highlighted straight away');

      // Tapping it mid-swipe still works (goes to Archive).
      await tester.tap(find.text('Archive').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tab-archive')), findsOneWidget);
    });

    testWidgets('only one nav is left once the swipe ends', (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      AppRoutes.switchTab(tester.element(find.byType(Scaffold).last), AppRoutes.cloudArchive);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
    });
  });

  group('on a phone with system bars, the nav surface keeps its exact size during the swipe', () {
    // Regression: with a status bar and a gesture bar, the fixed copy of the nav
    // grew upward by the status-bar height while swiping.
    for (final insets in {
      'gesture bar only': const FakeViewPadding(bottom: 34),
      'status bar + gesture bar': const FakeViewPadding(top: 24, bottom: 48),
      'tall notch + 3-button bar': const FakeViewPadding(top: 47, bottom: 24),
    }.entries) {
      testWidgets('${insets.key}: top edge and height never change in either direction', (tester) async {
        tester.view.physicalSize = const Size(400, 800);
        tester.view.devicePixelRatio = 1;
        tester.view.padding = insets.value;
        tester.view.viewPadding = insets.value;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(_app());
        await tester.pumpAndSettle();

        // The white surface (what the user actually sees), not just the icon row.
        Rect surface() {
          final nav = find.byType(NavigationBar).hitTestable();
          return tester.getRect(find.ancestor(of: nav, matching: find.byType(Material)).first);
        }

        final resting = surface();
        expect(resting.bottom, 800);
        for (final route in [AppRoutes.examHub, AppRoutes.cloudArchive, AppRoutes.staffHome]) {
          AppRoutes.switchTab(tester.element(find.byType(Scaffold).last), route);
          await tester.pump();
          for (var i = 0; i < 7; i++) {
            await tester.pump(const Duration(milliseconds: 40));
            expect(surface(), resting, reason: 'frame $i of the swipe to $route');
          }
          await tester.pumpAndSettle();
          expect(surface(), resting);
        }
      });
    }
  });
}
