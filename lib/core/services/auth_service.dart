import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

import 'firestore_service.dart';
import '../../models/user.dart';

export 'firestore_service.dart' show FirestoreService;

/// Custom exceptions for user access validation
class UserNotConfiguredException implements Exception {
  final String message;
  UserNotConfiguredException(this.message);
}

class UserDeactivatedException implements Exception {
  final String message;
  UserDeactivatedException(this.message);
}

/// Wraps Firebase Auth and Google Sign-In for the login screen.
/// Integrates with Firestore for user document validation.
class AuthService {
  AuthService({
    FirebaseAuth? firebaseAuth,
    GoogleSignIn? googleSignIn,
    FirestoreService? firestoreService,
  })  : _auth = firebaseAuth ?? FirebaseAuth.instance,
        _googleSignIn = googleSignIn ?? (kIsWeb ? null : GoogleSignIn()),
        _firestoreService = firestoreService ?? FirestoreService();

  final FirebaseAuth _auth;
  final GoogleSignIn? _googleSignIn;
  final FirestoreService _firestoreService;

  User? get currentUser => _auth.currentUser;

  /// Get current user from Firestore
  Future<UserModel?> getCurrentFirestoreUser() async {
    return await _firestoreService.getCurrentUser();
  }

  Future<UserCredential> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(email: email, password: password);
    
    // Validate user access with Firestore after successful authentication
    await _validateUserAccess(credential.user);
    
    return credential;
  }

  Future<UserCredential> signInWithGoogle() async {
    final googleSignIn = _googleSignIn;
    if (googleSignIn == null) {
      throw FirebaseAuthException(
        code: 'google-sign-in-not-available',
        message: 'Google Sign-in is not available on this platform.',
      );
    }

    final googleUser = await googleSignIn.signIn();
    if (googleUser == null) {
      throw FirebaseAuthException(
        code: 'sign-in-cancelled',
        message: 'Google sign-in was cancelled.',
      );
    }

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final authCredential = await _auth.signInWithCredential(credential);
    
    // Validate user access with Firestore after successful authentication
    await _validateUserAccess(authCredential.user);
    
    return authCredential;
  }

  Future<void> signOut() async {
    await _auth.signOut();
    final googleSignIn = _googleSignIn;
    if (googleSignIn != null) {
      await googleSignIn.signOut();
    }
  }

  /// Validate user access from Firestore
  /// Users must exist in Firestore and be active to access the application
  Future<void> _validateUserAccess(User? user) async {
    if (user == null) return;

    try {
      final firestoreUser = await _firestoreService.getUserById(user.uid);
      
      if (firestoreUser == null) {
        // TODO: Remove this automatic user creation after User Management module is implemented
        // Development mode: Automatically create user document if it doesn't exist
        await _firestoreService.createUserWithId(UserModel(
          userId: user.uid,
          email: user.email ?? '',
          displayName: user.displayName ?? '',
          role: 'guidance_council',
          guidancePosition: 'guidance_staff',
          isActive: true,
          createdAt: DateTime.now(),
          lastLoginAt: DateTime.now(),
          institution: 'NDMU',
        ));
        print('Development mode: Auto-created user document for ${user.email}');
      } else {
        // User exists, check if active
        if (!firestoreUser.isActive) {
          // User exists but is deactivated
          throw UserDeactivatedException(
            'Your account has been deactivated. Please contact the System Administrator.'
          );
        }
        
        // Update last login timestamp for active users
        await _firestoreService.updateLastLogin(user.uid);
      }
      
    } catch (e) {
      if (e is UserDeactivatedException) {
        rethrow; // Re-throw our custom exception
      }
      print('Error validating user access: $e');
      // Don't block authentication for other Firestore errors
    }
  }

  static String messageFor(dynamic error) {
    if (error is UserNotConfiguredException) {
      return error.message;
    }
    
    if (error is UserDeactivatedException) {
      return error.message;
    }
    
    if (error is FirebaseAuthException) {
      return _messageForFirebaseAuth(error);
    }
    
    return 'An error occurred. Please try again.';
  }

  static String _messageForFirebaseAuth(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Invalid email or password.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'sign-in-cancelled':
        return 'Sign-in was cancelled.';
      case 'network-request-failed':
        return 'Network error. Check your connection and try again.';
      case 'google-sign-in-not-available':
        return 'Google Sign-in is not available on this platform.';
      default:
        return error.message ?? 'Sign-in failed. Please try again.';
    }
  }
}
