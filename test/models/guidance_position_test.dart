import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/guidance_position.dart';

void main() {
  group('GuidancePositions.defaults', () {
    test('the three original positions are available with their canonical labels', () {
      expect(GuidancePositions.defaults, hasLength(3));
      expect(
        GuidancePositions.defaults,
        containsAll(const [
          GuidancePosition(value: 'guidance_head', label: 'Guidance Head'),
          GuidancePosition(value: 'psychometrician', label: 'Psychometrician'),
          GuidancePosition(value: 'guidance_staff', label: 'Guidance Staff'),
        ]),
      );
    });
  });

  group('GuidancePositions.fromFirestoreField', () {
    test('parses a well-formed positions map, including an admin-added position', () {
      final parsed = GuidancePositions.fromFirestoreField({
        'guidance_head': 'Guidance Head',
        'psychometrician': 'Psychometrician',
        'guidance_staff': 'Guidance Staff',
        'auditing': 'Auditing',
      });
      expect(parsed, hasLength(4));
      expect(parsed, contains(const GuidancePosition(value: 'auditing', label: 'Auditing')));
    });

    test('falls back to defaults when the field is null (document/field missing)', () {
      expect(GuidancePositions.fromFirestoreField(null), GuidancePositions.defaults);
    });

    test('falls back to defaults when the field is not a map', () {
      expect(GuidancePositions.fromFirestoreField('not a map'), GuidancePositions.defaults);
      expect(GuidancePositions.fromFirestoreField(42), GuidancePositions.defaults);
    });

    test('falls back to defaults when the map is empty', () {
      expect(GuidancePositions.fromFirestoreField(<String, dynamic>{}), GuidancePositions.defaults);
    });

    test('skips blank/malformed entries but keeps well-formed ones', () {
      final parsed = GuidancePositions.fromFirestoreField({
        'auditing': 'Auditing',
        '': 'Blank key',
        'blank_label': '   ',
        'wrong_type': 5,
      });
      expect(parsed, [const GuidancePosition(value: 'auditing', label: 'Auditing')]);
    });
  });

  group('GuidancePositions.labelFor', () {
    test('returns the matching label', () {
      expect(GuidancePositions.labelFor('guidance_head', GuidancePositions.defaults), 'Guidance Head');
    });

    test('returns null for a null value', () {
      expect(GuidancePositions.labelFor(null, GuidancePositions.defaults), isNull);
    });

    test('returns null for a value not present in the list -- never guesses or falls back', () {
      expect(GuidancePositions.labelFor('auditing', GuidancePositions.defaults), isNull);
    });
  });

  group('GuidancePositions.ensureIncludes', () {
    test('adds a synthetic entry when currentValue is missing from positions', () {
      final result = GuidancePositions.ensureIncludes(GuidancePositions.defaults, 'auditing');
      expect(result, hasLength(4));
      expect(result.last, const GuidancePosition(value: 'auditing', label: 'auditing'));
    });

    test('is a no-op when currentValue is already present', () {
      final result = GuidancePositions.ensureIncludes(GuidancePositions.defaults, 'guidance_head');
      expect(result, GuidancePositions.defaults);
    });

    test('is a no-op when currentValue is null or blank', () {
      expect(GuidancePositions.ensureIncludes(GuidancePositions.defaults, null), GuidancePositions.defaults);
      expect(GuidancePositions.ensureIncludes(GuidancePositions.defaults, '   '), GuidancePositions.defaults);
    });
  });

  group('GuidancePositions.slugify', () {
    test('lowercases and joins words with underscores', () {
      expect(GuidancePositions.slugify('Auditing'), 'auditing');
      expect(GuidancePositions.slugify('Data Analysis'), 'data_analysis');
    });

    test('collapses runs of non-alphanumeric characters and trims underscores', () {
      expect(GuidancePositions.slugify('  Data   Analysis!!  '), 'data_analysis');
      expect(GuidancePositions.slugify('Co-Curricular / Advisor'), 'co_curricular_advisor');
    });

    test('matches the project\'s existing internal-value convention for the originals', () {
      expect(GuidancePositions.slugify('Guidance Head'), 'guidance_head');
      expect(GuidancePositions.slugify('Guidance Staff'), 'guidance_staff');
    });
  });

  group('GuidancePositions.validateNewLabel', () {
    test('rejects a blank label', () {
      expect(GuidancePositions.validateNewLabel('   ', GuidancePositions.defaults), isNotNull);
    });

    test('rejects a label matching an existing one, case-insensitively and trimmed', () {
      expect(GuidancePositions.validateNewLabel('guidance head', GuidancePositions.defaults), isNotNull);
      expect(GuidancePositions.validateNewLabel('  Guidance Head  ', GuidancePositions.defaults), isNotNull);
    });

    test('rejects a label whose slug collides with an existing internal value', () {
      // Different label text, but slugifies to the same existing value.
      expect(GuidancePositions.validateNewLabel('Guidance-Head', GuidancePositions.defaults), isNotNull);
    });

    test('accepts a genuinely new label', () {
      expect(GuidancePositions.validateNewLabel('Auditing', GuidancePositions.defaults), isNull);
    });
  });

  group('GuidancePositions.build', () {
    test('builds the value/label pair for a validated label', () {
      final built = GuidancePositions.build('Auditing');
      expect(built.value, 'auditing');
      expect(built.label, 'Auditing');
    });
  });
}
