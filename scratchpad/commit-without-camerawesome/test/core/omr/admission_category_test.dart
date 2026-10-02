import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/omr/admission_category.dart';

void main() {
  group('admissionCategory — named boundaries', () {
    test('lower boundary 0 -> A', () {
      expect(admissionCategory(0), AdmissionCategory.a);
    });
    test('upper A boundary 54 -> A', () {
      expect(admissionCategory(54), AdmissionCategory.a);
    });
    test('gap 55 -> null', () {
      expect(admissionCategory(55), isNull);
    });
    test('gap 56 -> null', () {
      expect(admissionCategory(56), isNull);
    });
    test('gap 57 -> null', () {
      expect(admissionCategory(57), isNull);
    });
    test('lower B boundary 58 -> B', () {
      expect(admissionCategory(58), AdmissionCategory.b);
    });
    test('upper B boundary 60 -> B', () {
      expect(admissionCategory(60), AdmissionCategory.b);
    });
    test('lower C boundary 61 -> C', () {
      expect(admissionCategory(61), AdmissionCategory.c);
    });
    test('upper C boundary 64 -> C', () {
      expect(admissionCategory(64), AdmissionCategory.c);
    });
    test('lower D boundary 65 -> D', () {
      expect(admissionCategory(65), AdmissionCategory.d);
    });
    test('upper D boundary 72 -> D', () {
      expect(admissionCategory(72), AdmissionCategory.d);
    });
    test('invalid -1 -> null', () {
      expect(admissionCategory(-1), isNull);
    });
    test('invalid 73 -> null', () {
      expect(admissionCategory(73), isNull);
    });
  });

  group('admissionCategory — full-range sweep of every band', () {
    test('0..54 all map to A', () {
      for (var s = 0; s <= 54; s++) {
        expect(admissionCategory(s), AdmissionCategory.a, reason: 'score $s');
      }
    });
    test('55..57 all map to null (the gap)', () {
      for (var s = 55; s <= 57; s++) {
        expect(admissionCategory(s), isNull, reason: 'score $s');
      }
    });
    test('58..60 all map to B', () {
      for (var s = 58; s <= 60; s++) {
        expect(admissionCategory(s), AdmissionCategory.b, reason: 'score $s');
      }
    });
    test('61..64 all map to C', () {
      for (var s = 61; s <= 64; s++) {
        expect(admissionCategory(s), AdmissionCategory.c, reason: 'score $s');
      }
    });
    test('65..72 all map to D', () {
      for (var s = 65; s <= 72; s++) {
        expect(admissionCategory(s), AdmissionCategory.d, reason: 'score $s');
      }
    });
    test('out-of-range values map to null', () {
      for (final s in [-1000, -2, -1, 73, 74, 100, 1000]) {
        expect(admissionCategory(s), isNull, reason: 'score $s');
      }
    });
  });

  group('AdmissionCategory enum', () {
    test('has exactly a, b, c, d in order', () {
      expect(AdmissionCategory.values, const [
        AdmissionCategory.a,
        AdmissionCategory.b,
        AdmissionCategory.c,
        AdmissionCategory.d,
      ]);
    });
  });
}
