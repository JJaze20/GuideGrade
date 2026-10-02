import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

/// Geometry/mapping regression coverage for the redesigned AT and QTM
/// answer sheets, checked directly against the generated
/// lib/core/omr/omr_templates.dart (itself derived from the same
/// tool/generate_sheets.dart computation that draws answer_sheets/*.pdf --
/// see that file's own doc comment on why the two can never drift apart).
///
/// This locks down exactly the two things most likely to silently break in
/// a future layout tweak: AT's alternating A-E/F-K choice labels by
/// odd/even item number, and each exam's block-to-item-number assignment
/// (top blocks left-to-right, then bottom blocks left-to-right). It proves
/// the *mapping* is right; it cannot prove a real photo of the printed
/// sheet decodes correctly -- that needs a device capture.
void main() {
  group('QTM: 60 items, 4 choices (A-D), 6 blocks of 10', () {
    final qtm = omrTemplates['QTM']!;

    test('exactly 60 items across all sections', () {
      final allItems = {for (final s in qtm.sections) ...s.items.keys};
      expect(allItems, equals(Set<int>.from(List.generate(60, (i) => i + 1))));
    });

    test('every item has exactly the 4 choices A, B, C, D in order', () {
      for (final section in qtm.sections) {
        for (final entry in section.items.entries) {
          final choices = entry.value.map((b) => b.choice).toList();
          expect(choices, ['A', 'B', 'C', 'D'], reason: 'item ${entry.key}');
        }
      }
    });

    /// Section N covers a fixed range of item numbers per generate_sheets
    /// .dart's _layoutQtmGrid (column-major 3x2: left column 1-10/11-20,
    /// middle 21-30/31-40, right 41-50/51-60).
    void expectSectionRange(String name, int first, int last) {
      final section = qtm.sections.firstWhere((s) => s.name == name);
      expect(section.items.keys.toSet(), Set<int>.from(List.generate(last - first + 1, (i) => first + i)));
    }

    test('column-major block ranges match the spec (top: 1-10/21-30/41-50, bottom: 11-20/31-40/51-60)', () {
      expectSectionRange('Section 1', 1, 10);
      expectSectionRange('Section 2', 11, 20);
      expectSectionRange('Section 3', 21, 30);
      expectSectionRange('Section 4', 31, 40);
      expectSectionRange('Section 5', 41, 50);
      expectSectionRange('Section 6', 51, 60);
    });

    test('top blocks (1-10, 21-30, 41-50) sit above bottom blocks (11-20, 31-40, 51-60)', () {
      double yOf(int item) => qtm.sections.expand((s) => s.items.entries).firstWhere((e) => e.key == item).value.first.yFrac;
      for (final (topFirst, bottomFirst) in [(1, 11), (21, 31), (41, 51)]) {
        expect(yOf(topFirst), lessThan(yOf(bottomFirst)), reason: 'item $topFirst should sit above item $bottomFirst');
      }
    });

    test('left/middle/right blocks read left to right (1-20, 21-40, 41-60 by x position)', () {
      double xOf(int item) => qtm.sections.expand((s) => s.items.entries).firstWhere((e) => e.key == item).value.first.xFrac;
      expect(xOf(1), lessThan(xOf(21)));
      expect(xOf(21), lessThan(xOf(41)));
    });
  });

  group('AT: 72 items, 5 choices, alternating A-E/F-K by odd/even, 6 blocks of 12', () {
    final at = omrTemplates['AT']!;

    test('exactly 72 items across all sections', () {
      final allItems = {for (final s in at.sections) ...s.items.keys};
      expect(allItems, equals(Set<int>.from(List.generate(72, (i) => i + 1))));
    });

    test('odd items use A, B, C, D, E and even items use F, G, H, J, K', () {
      for (final section in at.sections) {
        for (final entry in section.items.entries) {
          final choices = entry.value.map((b) => b.choice).toList();
          final expected = entry.key.isOdd ? ['A', 'B', 'C', 'D', 'E'] : ['F', 'G', 'H', 'J', 'K'];
          expect(choices, expected, reason: 'item ${entry.key}');
        }
      }
    });

    /// Row-major 3x2 grid per generate_sheets.dart's _layoutAtGrid: top row
    /// left-to-right is Sections 1/2/3 (1-12/13-24/25-36), bottom row is
    /// Sections 4/5/6 (37-48/49-60/61-72).
    void expectSectionRange(String name, int first, int last) {
      final section = at.sections.firstWhere((s) => s.name == name);
      expect(section.items.keys.toSet(), Set<int>.from(List.generate(last - first + 1, (i) => first + i)));
    }

    test('row-major block ranges match the spec (top: 1-12/13-24/25-36, bottom: 37-48/49-60/61-72)', () {
      expectSectionRange('Section 1', 1, 12);
      expectSectionRange('Section 2', 13, 24);
      expectSectionRange('Section 3', 25, 36);
      expectSectionRange('Section 4', 37, 48);
      expectSectionRange('Section 5', 49, 60);
      expectSectionRange('Section 6', 61, 72);
    });

    test('top blocks (1-12, 13-24, 25-36) sit above bottom blocks (37-48, 49-60, 61-72)', () {
      double yOf(int item) => at.sections.expand((s) => s.items.entries).firstWhere((e) => e.key == item).value.first.yFrac;
      for (final (topFirst, bottomFirst) in [(1, 37), (13, 49), (25, 61)]) {
        expect(yOf(topFirst), lessThan(yOf(bottomFirst)), reason: 'item $topFirst should sit above item $bottomFirst');
      }
    });

    test('left/middle/right blocks read left to right (1-12, 13-24, 25-36 by x position)', () {
      double xOf(int item) => at.sections.expand((s) => s.items.entries).firstWhere((e) => e.key == item).value.first.xFrac;
      expect(xOf(1), lessThan(xOf(13)));
      expect(xOf(13), lessThan(xOf(25)));
    });
  });

  group('interior fiducials sit where the spec describes', () {
    void expectFiducialLayout(String code) {
      final t = omrTemplates[code]!;
      final byRole = {for (final f in t.interiorFiducials) f.role: f};
      final tl = t.cornerMarkers[0], tr = t.cornerMarkers[1];
      final bl = t.cornerMarkers[2];

      // Divider left/right sit at the same height as each other, strictly
      // between the top and bottom corners, and roughly under their own
      // side's corners (not swapped left<->right).
      final dl = byRole[OmrFiducialRole.dividerLeft]!;
      final dr = byRole[OmrFiducialRole.dividerRight]!;
      expect(dl.yFrac, closeTo(dr.yFrac, 1e-6), reason: '$code dividerLeft/Right must share the same row');
      expect(dl.yFrac, greaterThan(tl.yFrac));
      expect(dl.yFrac, lessThan(bl.yFrac));
      expect(dl.xFrac, lessThan(dr.xFrac));
      expect(dl.xFrac, closeTo(tl.xFrac, 1e-3), reason: '$code dividerLeft should align with the left edge');
      expect(dr.xFrac, closeTo(tr.xFrac, 1e-3), reason: '$code dividerRight should align with the right edge');

      // Center marks: above answers is between the top corners and the
      // divider row; below answers is between the divider row and the
      // bottom corners; at-divider sits on the divider row itself.
      final above = byRole[OmrFiducialRole.centerAboveAnswers]!;
      final atDivider = byRole[OmrFiducialRole.centerAtDivider]!;
      final below = byRole[OmrFiducialRole.centerBelowAnswers]!;
      expect(above.yFrac, greaterThan(tl.yFrac));
      expect(above.yFrac, lessThan(dl.yFrac));
      expect(atDivider.yFrac, closeTo(dl.yFrac, 1e-6));
      expect(below.yFrac, greaterThan(dl.yFrac));
      expect(below.yFrac, lessThan(bl.yFrac));
      // All 3 center marks share one horizontal position (the page's
      // content-horizontal-center), between the left and right edges.
      expect(above.xFrac, closeTo(atDivider.xFrac, 1e-6));
      expect(above.xFrac, closeTo(below.xFrac, 1e-6));
      expect(above.xFrac, greaterThan(tl.xFrac));
      expect(above.xFrac, lessThan(tr.xFrac));
    }

    test('AT', () => expectFiducialLayout('AT'));
    test('QTM', () => expectFiducialLayout('QTM'));
  });
}
