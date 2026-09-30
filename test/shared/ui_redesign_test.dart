import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:guidegrade/core/routes/app_routes.dart';
import 'package:guidegrade/features/exam/widgets/exam_category_card.dart';
import 'package:guidegrade/shared/widgets/app_bottom_nav.dart';

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('exam card fits a narrow screen with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = false;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              ExamCategoryCard(
                icon: FontAwesomeIcons.calculator,
                label: 'Quantitative Math Test (QTM)',
                iconColor: Colors.green,
                iconBg: Colors.white,
                onTap: () => selected = true,
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Quantitative Math Test (QTM)'));
    expect(selected, isTrue);
  });

  for (final destination in <String, String>{
    'Home': AppRoutes.staffHome,
    'Exams': AppRoutes.examHub,
    'Archive': AppRoutes.cloudArchive,
  }.entries) {
    testWidgets('${destination.key} keeps its existing route', (tester) async {
      String? opened;
      await tester.pumpWidget(MaterialApp(
        home: const Scaffold(
          bottomNavigationBar: AppBottomNav(activeTab: 'home'),
        ),
        onGenerateRoute: (settings) {
          opened = settings.name;
          return MaterialPageRoute<void>(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('Destination')),
          );
        },
      ));
      await tester.tap(find.text(destination.key));
      await tester.pumpAndSettle();
      expect(opened, destination.value);
      expect(find.text('Destination'), findsOneWidget);
    });
  }
}

