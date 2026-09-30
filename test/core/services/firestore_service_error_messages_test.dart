import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guidegrade/core/services/firestore_service.dart';

void main() {
  group('FirestoreService.messageFor', () {
    test('1. permission-denied returns an authorization-specific message',
        () {
      final error = FirebaseException(plugin: 'firestore', code: 'permission-denied');
      final message = FirestoreService.messageFor(error);
      expect(message, contains('permission'));
      expect(message, isNot(contains('connection')));
    });

    test('2. unavailable returns a connectivity-specific message', () {
      final error = FirebaseException(plugin: 'firestore', code: 'unavailable');
      final message = FirestoreService.messageFor(error);
      expect(message, contains('server'));
      expect(message, isNot(contains('permission')));
    });

    test('3. network-request-failed returns the same connectivity-specific '
        'message as unavailable', () {
      final unavailable =
          FirestoreService.messageFor(FirebaseException(plugin: 'firestore', code: 'unavailable'));
      final networkFailed = FirestoreService.messageFor(
          FirebaseException(plugin: 'firestore', code: 'network-request-failed'));
      expect(networkFailed, unavailable);
    });

    test('4. an unrelated FirebaseException code falls back to the generic '
        'message (or the caller\'s own fallback)', () {
      final error = FirebaseException(plugin: 'firestore', code: 'not-found');
      expect(
        FirestoreService.messageFor(error),
        'Could not complete the request. Please try again.',
      );
      expect(
        FirestoreService.messageFor(error, fallback: 'Could not load X.'),
        'Could not load X.',
      );
    });

    test('5. an ordinary (non-FirebaseException) error falls back to the '
        'generic message (or the caller\'s own fallback)', () {
      final error = Exception('boom');
      expect(
        FirestoreService.messageFor(error),
        'Could not complete the request. Please try again.',
      );
      expect(
        FirestoreService.messageFor(error, fallback: 'Could not load X.'),
        'Could not load X.',
      );
    });
  });
}
