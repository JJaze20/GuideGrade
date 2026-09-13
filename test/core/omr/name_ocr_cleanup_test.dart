import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/name_ocr_cleanup.dart';

void main() {
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
