import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:guidegrade/shared/widgets/app_header_bar.dart';

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  Future<void> pump(WidgetTester tester, AppHeaderBar bar) =>
      tester.pumpWidget(MaterialApp(home: Scaffold(appBar: bar, body: const SizedBox())));

  testWidgets('with showLogo the app logo (an image) is shown, not a text "G"', (tester) async {
    await pump(tester, const AppHeaderBar(title: 'GUIDE GRADE', showLogo: true));

    final badge = find.byKey(const ValueKey('app-header-logo'));
    expect(badge, findsOneWidget);
    final image = tester.widget<Image>(find.descendant(of: badge, matching: find.byType(Image)));
    expect((image.image as AssetImage).assetName, 'assets/images/guidegrade logo1 trimmed.png');
    expect(find.text('G'), findsNothing, reason: 'the gold script letter is gone');
    expect(find.text('GUIDE GRADE'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'badge fits the bar without overflowing');
  });

  testWidgets('the logo sits on a white badge so the green mark stays visible on the green bar', (tester) async {
    await pump(tester, const AppHeaderBar(title: 'GUIDE GRADE', showLogo: true));
    final box = tester.widget<Container>(find.byKey(const ValueKey('app-header-logo')));
    expect((box.decoration as BoxDecoration).color, Colors.white);
  });

  testWidgets('without showLogo (Exams, Archive) nothing changes: no logo, same bar height', (tester) async {
    await pump(tester, const AppHeaderBar(title: 'EXAMS'));
    expect(find.byKey(const ValueKey('app-header-logo')), findsNothing);
    expect(find.text('EXAMS'), findsOneWidget);
    expect(const AppHeaderBar(title: 'EXAMS').preferredSize.height, 52);
    expect(const AppHeaderBar(title: 'X', showLogo: true).preferredSize.height, 60);
  });
}
