import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/models/user.dart';

Map<String, dynamic> _doc({Map<String, dynamic> extra = const {}}) => {
      'email': 'staff@ndmu.edu.ph',
      'displayName': 'J. Dela Cruz',
      'role': 'guidance_council',
      'guidancePosition': 'guidance_staff',
      'isActive': true,
      'createdAt': '2026-01-02T03:04:05.000',
      'lastLoginAt': null,
      'passwordResetRequired': false,
      'createdBy': 'admin-1',
      'institution': 'NDMU',
      ...extra,
    };

UserModel _user({String? first, String? mi, String? last}) => UserModel(
      userId: 'u1',
      email: 'staff@ndmu.edu.ph',
      displayName: 'J. Dela Cruz',
      role: 'guidance_council',
      isActive: true,
      createdAt: DateTime.utc(2026, 1, 2),
      firstName: first,
      middleInitial: mi,
      lastName: last,
    );

void main() {
  group('UserModel structured name', () {
    test('serializes firstName', () {
      expect(_user(first: 'Juan').toFirestore()['firstName'], 'Juan');
    });

    test('serializes middleInitial', () {
      expect(_user(mi: 'D.').toFirestore()['middleInitial'], 'D.');
    });

    test('serializes lastName', () {
      expect(_user(last: 'Dela Cruz').toFirestore()['lastName'], 'Dela Cruz');
    });

    test('reads a document that contains the new fields', () {
      final user = UserModel.fromFirestore(
        _doc(extra: {'firstName': 'Juan', 'middleInitial': 'D.', 'lastName': 'Dela Cruz'}),
        'uid-1',
      );
      expect(user.firstName, 'Juan');
      expect(user.middleInitial, 'D.');
      expect(user.lastName, 'Dela Cruz');
      expect(user.hasStructuredName, isTrue);
    });

    test('still reads an OLD document without the new fields', () {
      final user = UserModel.fromFirestore(_doc(), 'uid-old');
      expect(user.displayName, 'J. Dela Cruz');
      expect(user.email, 'staff@ndmu.edu.ph');
      expect(user.firstName, isNull);
      expect(user.middleInitial, isNull);
      expect(user.lastName, isNull);
      expect(user.hasStructuredName, isFalse);
    });

    test('blank or non-string stored values read as "no name"', () {
      final user = UserModel.fromFirestore(
        _doc(extra: {'firstName': '   ', 'middleInitial': 7, 'lastName': null}),
        'uid-x',
      );
      expect(user.firstName, isNull);
      expect(user.middleInitial, isNull);
      expect(user.lastName, isNull);
    });

    test('an old user is written back WITHOUT empty name fields', () {
      final map = _user().toFirestore();
      expect(map.containsKey('firstName'), isFalse);
      expect(map.containsKey('middleInitial'), isFalse);
      expect(map.containsKey('lastName'), isFalse);
      expect(map['displayName'], 'J. Dela Cruz');
    });

    test('a round trip keeps all three fields and the independent display name', () {
      final original = _user(first: 'Juan', mi: 'D.', last: 'Dela Cruz');
      final back = UserModel.fromFirestore(original.toFirestore(), 'u1');
      expect(back.firstName, 'Juan');
      expect(back.middleInitial, 'D.');
      expect(back.lastName, 'Dela Cruz');
      expect(back.displayName, 'J. Dela Cruz', reason: 'never derived from the name parts');
    });

    test('copyWith changes the name parts without touching displayName', () {
      final changed = _user(first: 'Juan', mi: 'D.', last: 'Dela Cruz')
          .copyWith(firstName: 'Jose', middleInitial: 'M.', lastName: 'Santos');
      expect(changed.firstName, 'Jose');
      expect(changed.middleInitial, 'M.');
      expect(changed.lastName, 'Santos');
      expect(changed.displayName, 'J. Dela Cruz');
    });

    test('copyWith with no name arguments keeps the existing ones', () {
      final same = _user(first: 'Juan', mi: 'D.', last: 'Dela Cruz').copyWith(institution: 'X');
      expect(same.firstName, 'Juan');
      expect(same.middleInitial, 'D.');
      expect(same.lastName, 'Dela Cruz');
    });
  });

  group('UserNameRules', () {
    test('First and Last Name are required', () {
      expect(UserNameRules.validateFirstName(null), isNotNull);
      expect(UserNameRules.validateFirstName('   '), isNotNull);
      expect(UserNameRules.validateFirstName('Juan'), isNull);
      expect(UserNameRules.validateLastName(''), isNotNull);
      expect(UserNameRules.validateLastName(' Dela Cruz '), isNull);
    });

    test('Middle Initial: one letter, optionally with a period', () {
      for (final ok in ['J', 'J.', 'm', 'M.', ' D. ', 'Ñ']) {
        expect(UserNameRules.validateMiddleInitial(ok), isNull, reason: '"$ok" should be accepted');
      }
      for (final bad in ['', '   ', 'Dc', 'Dela', 'Dela.', '12', '1', '.', '..', 'D..', 'J.M.']) {
        expect(UserNameRules.validateMiddleInitial(bad), isNotNull, reason: '"$bad" should be rejected');
      }
    });

    test('Middle Initial is stored consistently as an upper-case letter and a period', () {
      expect(UserNameRules.normalizeMiddleInitial('j'), 'J.');
      expect(UserNameRules.normalizeMiddleInitial('J.'), 'J.');
      expect(UserNameRules.normalizeMiddleInitial(' m '), 'M.');
      expect(UserNameRules.normalizeMiddleInitial('Dela'), 'Dela', reason: 'invalid input is left alone');
    });
  });
}
