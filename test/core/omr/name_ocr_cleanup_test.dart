import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/name_ocr_cleanup.dart';

void main() {
  test('removes location and letterhead mixed with names', () {
    for (final raw in [
      'Koronadal\nLast Name De La Cruz',
      'De La Cruz Koronadal',
      'City of Koronadal, South Cotabato\nDe La Cruz',
      'NOTRE DAME OF\nMARBEL UNIVERSITY\nLast Name De La Cruz',
      'Guidance, Honors, and Scholarship Center\nDe La Cruz',
      'Guidance and Testing Center\nDe La Cruz',
    ]) {
      expect(cleanNameOcrText(raw, 'Last Name'), 'De La Cruz');
    }
  });
  test('removes neighboring captions and trailing captions', () {
    expect(cleanNameOcrText('Maria First Name', 'First Name'), 'Maria');
    expect(
      cleanNameOcrText('Last Name First Name Maria', 'First Name'),
      'Maria',
    );
    expect(
      cleanNameOcrText('School Last Attended\nMaria', 'First Name'),
      'Maria',
    );
    expect(
      cleanNameOcrText('Address of School Last Attended\nMaria', 'First Name'),
      'Maria',
    );
    expect(
      cleanNameOcrText('Date\nBatch\nExam Code\nMaria', 'First Name'),
      'Maria',
    );
    expect(cleanNameOcrText('Koronadal\nM.I. E', 'MI'), 'E');
  });
  test('printed text alone produces no name', () {
    for (final raw in [
      'Koronadal',
      'City of Koronadal, South Cotabato',
      'Notre Dame of Marbel University',
      'First Name Last Name Middle Initial',
      'Admission Test\nAnswer Sheet',
    ]) {
      expect(cleanNameOcrText(raw, 'Last Name'), isNull);
    }
  });
  test('does not remove fragments of names that resemble header words', () {
    expect(
      cleanNameOcrText('Dame Marbel South', 'Last Name'),
      'Dame Marbel South',
    );
    expect(cleanNameOcrText('Koronadales', 'Last Name'), 'Koronadales');
    expect(cleanNameOcrText('Mary Date', 'First Name'), 'Mary Date');
  });
  test('removes exact, misread, punctuated and joined captions', () {
    for (final caption in [
      'Last Name',
      'Last Narne:',
      'LastName:',
      'Last N ame',
    ]) {
      expect(cleanNameOcrText('$caption Doe', 'Last Name'), 'Doe');
    }
    expect(cleanNameOcrText('First Narme: Maria', 'First Name'), 'Maria');
  });
  test('removes separate captions before or after handwriting', () {
    expect(
      cleanNameOcrText('Last Narne\nDe La Cruz', 'Last Name'),
      'De La Cruz',
    );
    expect(cleanNameOcrText('Doe\nLast Name', 'Last Name'), 'Doe');
  });
  test('label-only and empty crops produce no suggestion', () {
    for (final text in ['', '  ', 'First Name:', 'First Narme']) {
      expect(cleanNameOcrText(text, 'First Name'), isNull);
    }
    expect(cleanNameOcrText('M.I.', 'MI'), isNull);
  });
  test('preserves short names, compound names and initials', () {
    expect(cleanNameOcrText('Last Name Li', 'Last Name'), 'Li');
    expect(cleanNameOcrText('First Name A', 'First Name'), 'A');
    expect(
      cleanNameOcrText("Last Name O'Neil-Santos", 'Last Name'),
      "O'neil-santos",
    );
    expect(cleanNameOcrText('M. I. E', 'MI'), 'E');
    expect(cleanNameOcrText('E', 'MI'), 'E');
    expect(cleanNameOcrText('Mila', 'MI'), 'Mila');
    expect(cleanNameOcrText('Firstman', 'First Name'), 'Firstman');
  });
}
