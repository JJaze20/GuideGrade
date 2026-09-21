import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Coverage for [bubblesForOverlayItem] -- the shared exact-lookup-first,
/// item-number-fallback-second resolver both the Mobile and Web graded
/// overlays use to find a [ScoredItem]'s bubbles. Exists specifically to
/// cover the backward-compatibility gap the AT/QTM 9-fiducial redesign
/// opened: a scan decoded before that redesign has its section name frozen
/// as AT's old single "Answer Document" section or QTM's old single
/// "Qualifying Test in Mathematics" section, neither of which matches any
/// of the current "Section 1".."Section 6" names.
void main() {
  final at = omrTemplates['AT']!;
  final qtm = omrTemplates['QTM']!;
  final tat = omrTemplates['TAT']!;
  final legacyAt = overlayTemplateForScan(at, scanTemplateVersion: 'AT-v1')!;
  final legacyQtm = overlayTemplateForScan(qtm, scanTemplateVersion: 'QTM-v1')!;

  group('legacy/current overlay template selection', () {
    test(
      'legacy templates contain every historical item and no interior mesh',
      () {
        expect(legacyAt.sections.single.itemCount, equals(72));
        expect(legacyAt.sections.single.items.length, equals(72));
        expect(legacyQtm.sections.single.itemCount, equals(60));
        expect(legacyQtm.sections.single.items.length, equals(60));
        expect(legacyAt.interiorFiducials, isEmpty);
        expect(legacyQtm.interiorFiducials, isEmpty);
      },
    );

    test(
      'historical items beyond the old partial sample retain exact coordinates',
      () {
        expect(
          legacyAt.sections.single.items[72],
          equals(const [
            BubblePos('F', 0.65851, 0.94430),
            BubblePos('G', 0.70219, 0.94430),
            BubblePos('H', 0.74587, 0.94430),
            BubblePos('J', 0.78954, 0.94430),
            BubblePos('K', 0.83322, 0.94430),
          ]),
        );
        expect(
          legacyQtm.sections.single.items[60],
          equals(const [
            BubblePos('A', 0.78105, 0.89957),
            BubblePos('B', 0.82353, 0.89957),
            BubblePos('C', 0.86601, 0.89957),
            BubblePos('D', 0.90850, 0.89957),
          ]),
        );
      },
    );

    test('current AT/QTM and TAT retain their existing template geometry', () {
      expect(at.templateVersion, equals('AT-redesign-v1'));
      expect(qtm.templateVersion, equals('QTM-redesign-v1'));
      expect(tat.templateVersion, equals('TAT-portrait-v5'));
      expect(at.interiorFiducials, hasLength(5));
      expect(qtm.interiorFiducials, hasLength(5));
      expect(tat.interiorFiducials, hasLength(10));
    });

    test(
      'legacy AT scans without a recorded version resolve to the historical template geometry',
      () {
        final resolved = overlayTemplateForScan(
          at,
          scanTemplateVersion: null,
          sectionName: 'Answer Document',
        );
        expect(resolved, isNotNull);
        expect(resolved!.templateVersion, equals('AT-v1'));
        expect(resolved.sections.first.name, equals('Answer Document'));
      },
    );

    test(
      'legacy QTM scans without a recorded version resolve to the historical template geometry',
      () {
        final resolved = overlayTemplateForScan(
          qtm,
          scanTemplateVersion: null,
          sectionName: 'Qualifying Test in Mathematics',
        );
        expect(resolved, isNotNull);
        expect(resolved!.templateVersion, equals('QTM-v1'));
        expect(
          resolved.sections.first.name,
          equals('Qualifying Test in Mathematics'),
        );
      },
    );

    test(
      'current scans still use the redesign template even when legacy names are absent',
      () {
        final resolved = overlayTemplateForScan(
          at,
          scanTemplateVersion: at.templateVersion,
          sectionName: 'Section 4',
        );
        expect(resolved, isNotNull);
        expect(resolved!.templateVersion, equals(at.templateVersion));
      },
    );

    test(
      'unknown recorded versions fail closed instead of guessing geometry',
      () {
        final resolved = overlayTemplateForScan(
          at,
          scanTemplateVersion: 'AT-never-seen-v99',
          sectionName: 'Section 4',
        );
        expect(resolved, isNull);
      },
    );
  });

  OmrSection sectionNamed(OmrExamTemplate template, String name) =>
      template.sections.firstWhere((s) => s.name == name);

  group('A. legacy AT ("Answer Document")', () {
    test('item 37 falls back to the current Section 4 bubbles', () {
      final expected = sectionNamed(at, 'Section 4').items[37];
      final result = bubblesForOverlayItem(at, 'Answer Document', 37);
      expect(result, isNotNull);
      expect(result, equals(expected));
    });
  });

  group('B. legacy QTM ("Qualifying Test in Mathematics")', () {
    test('item 51 falls back to the current Section 6 bubbles', () {
      final expected = sectionNamed(qtm, 'Section 6').items[51];
      final result = bubblesForOverlayItem(
        qtm,
        'Qualifying Test in Mathematics',
        51,
      );
      expect(result, isNotNull);
      expect(result, equals(expected));
    });
  });

  group('C. current AT', () {
    test('"Section 4" + item 37 resolves via the exact lookup', () {
      final expected = sectionNamed(at, 'Section 4').items[37];
      expect(bubblesForOverlayItem(at, 'Section 4', 37), equals(expected));
    });
  });

  group('D. current QTM', () {
    test('"Section 6" + item 51 resolves via the exact lookup', () {
      final expected = sectionNamed(qtm, 'Section 6').items[51];
      expect(bubblesForOverlayItem(qtm, 'Section 6', 51), equals(expected));
    });
  });

  group('E. TAT', () {
    test('"Test I" + item 1 resolves via the exact lookup', () {
      final expected = sectionNamed(tat, 'Test I').items[1];
      expect(bubblesForOverlayItem(tat, 'Test I', 1), equals(expected));
    });
  });

  group('F. TAT wrong section name', () {
    test('a valid item number with an unknown section name returns null, '
        'never another Test section\'s bubbles for the same number', () {
      final result = bubblesForOverlayItem(tat, 'Not A Real Section', 1);
      expect(result, isNull);
      // Sanity: item 1 does exist under every TAT section, so a naive
      // number-only fallback would have found *something* here -- proving
      // this null is the disabled-fallback path, not a coincidental miss.
      expect(sectionNamed(tat, 'Test I').items[1], isNotNull);
      expect(sectionNamed(tat, 'Test II').items[1], isNotNull);
      expect(sectionNamed(tat, 'Test III').items[1], isNotNull);
    });
  });

  group('G. missing item number', () {
    test('AT item 999 with an invalid section name returns null', () {
      expect(bubblesForOverlayItem(at, 'Not A Real Section', 999), isNull);
    });
  });

  group('H. duplicate item numbers disable the fallback entirely', () {
    test('a synthetic template with the same item number in two sections '
        'returns null instead of guessing either one', () {
      const bubblesInSectionOne = [
        BubblePos('A', 0.1, 0.1),
        BubblePos('B', 0.2, 0.1),
      ];
      const bubblesInSectionTwo = [
        BubblePos('C', 0.5, 0.5),
        BubblePos('D', 0.6, 0.5),
      ];
      final synthetic = OmrExamTemplate(
        examCode: 'ZZZ',
        templateVersion: 'test-only',
        pageWidthPt: 100,
        pageHeightPt: 100,
        bubbleRadiusPt: 5,
        bubbleRadiusYPt: 5,
        cornerMarkers: const [
          OmrCorner(0, 0),
          OmrCorner(1, 0),
          OmrCorner(0, 1),
          OmrCorner(1, 1),
        ],
        sections: const [
          OmrSection(
            name: 'Section A',
            itemCount: 1,
            items: {5: bubblesInSectionOne},
          ),
          OmrSection(
            name: 'Section B',
            itemCount: 1,
            items: {5: bubblesInSectionTwo},
          ),
        ],
        lastNameFieldRect: const OmrFieldRect(0, 0, 1, 1),
        firstNameFieldRect: const OmrFieldRect(0, 0, 1, 1),
        middleNameFieldRect: const OmrFieldRect(0, 0, 1, 1),
      );

      final result = bubblesForOverlayItem(synthetic, 'Not A Real Section', 5);
      expect(result, isNull);
    });
  });

  group('safety rule: fallback never overrides a successful exact match', () {
    test(
      'current-format AT item still returns the exact match even though '
      'a legacy-style lookup for the same item number would also succeed',
      () {
        final exact = bubblesForOverlayItem(at, 'Section 4', 37);
        final viaLegacyName = bubblesForOverlayItem(at, 'Answer Document', 37);
        // Both resolve to the same bubbles, but for different reasons: the
        // first is the untouched exact path, the second only exists because
        // of the fallback -- proven separately by cases A and C above.
        expect(exact, equals(viaLegacyName));
      },
    );
  });
}
