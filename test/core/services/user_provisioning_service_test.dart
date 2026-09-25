import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/firestore_service.dart';
import 'package:guidegrade/core/services/logging_service.dart';
import 'package:guidegrade/core/services/user_provisioning_service.dart';
import 'package:guidegrade/models/user.dart';

/// Any call to these means provisioning went past the name check -- which the
/// invalid-name tests must never do (no Firebase exists in a unit test).
class _NoFirestore implements FirestoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Firestore must not be reached: ${invocation.memberName}');
}

class _NoLogging implements LoggingService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Logging must not be reached: ${invocation.memberName}');
}

UserModel get _admin => UserModel(
      userId: 'admin-1',
      email: 'admin@ndmu.edu.ph',
      displayName: 'Admin',
      role: 'system_admin',
      isActive: true,
      createdAt: DateTime.utc(2026),
    );

void main() {
  group('buildGuidanceCouncilUser (what is stored in users/{uid})', () {
    UserModel build({
      String displayName = 'J. Dela Cruz',
      String first = 'Juan',
      String mi = 'D.',
      String last = 'Dela Cruz',
    }) =>
        UserProvisioningService.buildGuidanceCouncilUser(
          userId: 'new-uid',
          email: ' staff@ndmu.edu.ph ',
          displayName: displayName,
          firstName: first,
          middleInitial: mi,
          lastName: last,
          createdBy: 'admin-1',
          createdAt: DateTime.utc(2026, 1, 2),
          guidancePosition: 'guidance_staff',
        );

    test('stores all three structured name fields', () {
      final user = build();
      expect(user.firstName, 'Juan');
      expect(user.middleInitial, 'D.');
      expect(user.lastName, 'Dela Cruz');

      final doc = user.toFirestore();
      expect(doc['firstName'], 'Juan');
      expect(doc['middleInitial'], 'D.');
      expect(doc['lastName'], 'Dela Cruz');
    });

    test('Display Name is stored exactly as entered, independent of the name parts', () {
      expect(build(displayName: 'J. Dela Cruz').displayName, 'J. Dela Cruz');
      expect(build(displayName: 'Juan Dela Cruz').displayName, 'Juan Dela Cruz');
      expect(build(displayName: 'Ma\'am Jane').displayName, 'Ma\'am Jane');
      expect(build(displayName: '  Padded Name  ').displayName, 'Padded Name', reason: 'only trimmed, as before');
    });

    test('names are trimmed and the middle initial is normalized', () {
      final user = build(first: '  Juan ', mi: 'd', last: ' Dela Cruz  ');
      expect(user.firstName, 'Juan');
      expect(user.middleInitial, 'D.');
      expect(user.lastName, 'Dela Cruz');
    });

    test('the existing provisioning fields are unchanged', () {
      final user = build();
      expect(user.userId, 'new-uid');
      expect(user.email, 'staff@ndmu.edu.ph');
      expect(user.role, 'guidance_council');
      expect(user.isActive, isTrue);
      expect(user.passwordResetRequired, isTrue);
      expect(user.createdBy, 'admin-1');
      expect(user.guidancePosition, 'guidance_staff');
      expect(user.institution, 'NDMU');
      expect(user.lastLoginAt, isNull);
    });
  });

  group('createGuidanceCouncilUser rejects an invalid structured name before creating anything', () {
    final service = UserProvisioningService(
      firestoreService: _NoFirestore(),
      loggingService: _NoLogging(),
    );

    Future<void> expectRejected({String first = 'Juan', String mi = 'D.', String last = 'Dela Cruz'}) {
      return expectLater(
        service.createGuidanceCouncilUser(
          email: 'staff@ndmu.edu.ph',
          displayName: 'J. Dela Cruz',
          firstName: first,
          middleInitial: mi,
          lastName: last,
          actor: _admin,
        ),
        throwsA(isA<UserProvisioningException>()),
      );
    }

    test('blank First Name', () => expectRejected(first: '  '));
    test('blank Last Name', () => expectRejected(last: ''));
    test('blank Middle Initial', () => expectRejected(mi: ''));
    test('a full middle name in Middle Initial', () => expectRejected(mi: 'Dela'));
  });
}
