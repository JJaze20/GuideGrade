import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/features/guidance_web/export/guidance_web_certificate.dart';

ExportCertificate? cert(
  String exam,
  int? raw, {
  String? name = 'Andulana, Robert P.',
  String? status = 'Graded',
}) => buildCertificate(
  examCode: exam,
  rawScore: raw,
  status: status,
  name: name,
);

List<String> headings(ExportCertificate c) => [
  for (final col in c.columns)
    for (final e in col)
      if (e.isHeading) e.text,
];

List<String> courses(ExportCertificate c) => [
  for (final col in c.columns)
    for (final e in col)
      if (!e.isHeading) e.text,
];

void main() {
  group('who gets a certificate', () {
    test('a scan with no name still gets a certificate with a blank name', () {
      expect(cert('AT', 70, name: null)!.name, '');
      expect(cert('AT', 70, name: '  ')!.name, '');
      expect(cert('AT', 70, name: 'Unnamed')!.name, '');
      expect(cert('AT', 70, name: null)!.letter, 'D');
    });

    test('no certificate when ungraded or without a score', () {
      expect(cert('AT', 70, status: 'Ungraded'), isNull);
      expect(cert('AT', null), isNull);
    });

    test('no certificate for the unclassified score gaps', () {
      expect(cert('AT', 55), isNull);
      expect(cert('AT', 57), isNull);
      expect(cert('QTM', 46), isNull);
      expect(cert('QTM', 47), isNull);
      expect(cert('TAT', 122), isNull);
      expect(cert('TAT', 127), isNull);
    });

    test('unknown exam code has no certificate', () {
      expect(cert('XYZ', 10), isNull);
    });
  });

  group('category and printed name', () {
    test('AT letters follow the admission category bands', () {
      expect(cert('AT', 68)!.letter, 'D');
      expect(cert('AT', 62)!.letter, 'C');
      expect(cert('AT', 59)!.letter, 'B');
      expect(cert('AT', 30)!.letter, 'A');
    });

    test('the name is printed upper-case', () {
      expect(cert('AT', 68)!.name, 'ANDULANA, ROBERT P.');
    });

    test('QTM and TAT letters', () {
      expect(cert('QTM', 55)!.letter, 'D');
      expect(cert('QTM', 49)!.letter, 'B');
      expect(cert('TAT', 150)!.letter, 'D');
      expect(cert('TAT', 100)!.letter, 'A');
    });

    test('QTM B and A labels are the legend percentages, not raw scores', () {
      expect(cert('QTM', 49)!.rangeLabel, '(80% - 84%)');
      expect(cert('QTM', 20)!.rangeLabel, '(76% and below)');
    });

    test('TAT reads "teach", AT and QTM read "take the"', () {
      expect(cert('TAT', 150)!.verb, 'teach');
      expect(cert('AT', 68)!.verb, 'take the');
      expect(cert('QTM', 55)!.verb, 'take the');
    });
  });

  group('C.2 / D.2 course groups follow the existing eligibility rules', () {
    test('QTM 18+ prints both C.2 and D.2 groups', () {
      final c = cert('QTM', 52)!; // category C
      expect(headings(c), ['C.2 (30%):', 'D.2 (25%):']);
      expect(courses(c), contains('BS – COMPUTER SCIENCE'));
      expect(courses(c), contains('BS – ARCHITECTURE'));
    });

    test('QTM 15–17 prints D.2 only (no Computer Science)', () {
      final c = cert('QTM', 16)!; // category A
      expect(headings(c), ['D.2 (25%):']);
      expect(courses(c), isNot(contains('BS – COMPUTER SCIENCE')));
      expect(courses(c), contains('BS – ARCHITECTURE'));
    });

    test('QTM below 15 prints neither group but keeps the plain courses', () {
      final c = cert('QTM', 10)!;
      expect(headings(c), isEmpty);
      expect(courses(c), ['BSED – MATHEMATICS', 'BSED – SCIENCE']);
    });

    test('QTM category D has no group headings', () {
      expect(headings(cert('QTM', 55)!), isEmpty);
    });

    test('TAT C.2 needs 48 or more', () {
      expect(headings(cert('TAT', 100)!), ['C.2 (30%):']);
      expect(headings(cert('TAT', 40)!), isEmpty);
      expect(courses(cert('TAT', 40)!), isNot(contains('BSED – ENGLISH')));
      expect(headings(cert('TAT', 48)!), ['C.2 (30%):']);
      expect(courses(cert('TAT', 48)!), contains('BSED – ENGLISH'));
    });
  });

  group('course lists', () {
    test('a duplicated course is printed once', () {
      final c = cert('AT', 62)!; // category C listed Marketing twice
      expect(
        courses(c).where((t) => t == 'BSBA – MARKETING MANAGEMENT'),
        hasLength(1),
      );
    });

    test('a joined line was split into separate courses', () {
      final c = cert('AT', 62)!;
      expect(courses(c), contains('BSBA – FINANCIAL MANAGEMENT'));
      expect(courses(c), contains('AB – PSYCHOLOGY'));
      expect(
        courses(c).any((t) => t.contains('FINANCIAL MANAGEMENT AB')),
        isFalse,
      );
    });
  });

  group('certificate intro text -- formal exam name, not the legacy OMR '
      'section identifier or the old incorrect catalog title', () {
    test('QTM intro uses the formal name "Qualifying Test for Mathematics"', () {
      final intro = cert('QTM', 55)!.intro;
      expect(intro, contains('Qualifying Test for Mathematics'));
    });

    test('QTM intro does not contain "Quantitative"', () {
      final intro = cert('QTM', 55)!.intro;
      expect(intro, isNot(contains('Quantitative')));
    });

    test('QTM intro does not need a "(QTM)" suffix -- certificate wording '
        'reads as a plain exam name, matching AT/TAT\'s own intro format', () {
      final intro = cert('QTM', 55)!.intro;
      expect(intro, isNot(contains('(QTM)')));
    });

    test('QTM intro is NOT the legacy OMR section identifier '
        '("in Mathematics") -- that string is frozen for physical-sheet/'
        'legacy-scan compatibility and must never appear here', () {
      final intro = cert('QTM', 55)!.intro;
      expect(intro, isNot(contains('Qualifying Test in Mathematics')));
    });

    test('AT certificate intro remains unchanged', () {
      expect(
        cert('AT', 70)!.intro,
        'You have successfully passed the Admission Test of the Notre Dame of Marbel University.',
      );
    });

    test('TAT certificate intro remains unchanged', () {
      expect(
        cert('TAT', 150)!.intro,
        'You have successfully passed the Teaching Aptitude Test of the Notre Dame of Marbel University.',
      );
    });
  });
}
