import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_sign_in/google_sign_in.dart';

import 'firestore_service.dart';
import 'logging_service.dart';
import '../../models/user.dart';

export 'firestore_service.dart' show FirestoreService;

/// Thrown when the signed-in Firebase identity has no approved Firestore
/// user record, or that record's role isn't one this app recognizes.
/// Both cases mean the same thing to the app: this identity is not
/// authorized to use it.
class UserNotConfiguredException implements Exception {
  final String message;
  UserNotConfiguredException(this.message);
}

class UserDeactivatedException implements Exception {
  final String message;
  UserDeactivatedException(this.message);
}

/// Thrown when the Firestore lookup needed to authorize the user couldn't
/// be completed at all (network error, rules denial, etc.) — kept distinct
/// from [UserNotConfiguredException] so "we don't know" is never confused
/// with "we know you're not allowed," and both fail closed identically.
class UserVerificationException implements Exception {
  final String message;
  UserVerificationException(this.message);
}

/// Thrown when an otherwise-valid, active, known-role account signs in
/// through the wrong platform's login screen — e.g. a `guidance_council`
/// account using the Web Admin login, or a `system_admin` account using the
/// mobile login. The account itself isn't invalid (unlike
/// [UserNotConfiguredException]/[UserDeactivatedException]); it just isn't
/// authorized to enter *this* portal.
class WrongPortalException implements Exception {
  final String message;
  WrongPortalException(this.message);
}

/// Wraps Firebase Auth and Google Sign-In for the login screens.
///
/// Authentication (Firebase) proves *who* signed in; this class is where
/// authorization (Firestore) decides *whether* that identity may actually
/// use the app, and with which role. [_authorize] is the single place that
/// makes that decision — both login screens call [signInWithEmail] /
/// [signInWithGoogle] and get back an approved, active [UserModel] or an
/// exception; neither screen resolves role on its own anymore.
///
/// Every denial path signs the Firebase (and Google, where applicable)
/// session back out before throwing, so a rejected sign-in never leaves an
/// authenticated-but-unauthorized session behind — this matters because
/// route guards elsewhere key off `FirebaseAuth.instance.currentUser`.
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

  /// The only roles this app knows how to act on. A Firestore user document
  /// with any other value in `role` is treated as unauthorized, not as a
  /// silently-broader or silently-narrower access level.
  static const Set<String> _knownRoles = {'system_admin', 'guidance_council'};

  User? get currentUser => _auth.currentUser;

  /// Get current user from Firestore (the caller is assumed to already be
  /// signed in and authorized; this does not itself authorize anything).
  Future<UserModel?> getCurrentFirestoreUser() async {
    return await _firestoreService.getCurrentUser();
  }

  /// Signs in with email/password, then authorizes the result against
  /// Firestore. Returns the approved, active [UserModel] on success.
  /// Throws on any failure (see [_authorize]) — the caller never receives
  /// a "success" it has to double-check.
  ///
  /// [requiredRole] is the role this login *portal* is for (e.g. the Web
  /// Admin screen passes `'system_admin'`, the mobile screen passes
  /// `'guidance_council'`) — an otherwise-valid account whose role doesn't
  /// match is denied with [WrongPortalException], not silently let through
  /// and routed elsewhere. This is a platform/portal check, separate from
  /// (and in addition to) the account-validity checks in [_authorize].
  Future<UserModel> signInWithEmail({
    required String email,
    required String password,
    required String requiredRole,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(email: email, password: password);
    return _authorize(credential.user, requiredRole: requiredRole);
  }

  Future<UserModel> signInWithGoogle({required String requiredRole}) async {
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
    return _authorize(authCredential.user, requiredRole: requiredRole);
  }

  /// Restores an already-authenticated session's approved [UserModel]
  /// *without* a fresh interactive sign-in — for a cold app start, where
  /// Firebase Auth already has a persisted session (it keeps one in local,
  /// secure storage that survives an app restart or being fully killed,
  /// independent of network) but nothing in this app's own state
  /// remembers who that is, since [UserModel] only ever lived in
  /// [AppState.currentUser] — an in-memory field, gone the instant the
  /// process is. Call this once at startup, before the route guard runs
  /// (see AppRoutes.onGenerateRoute's doc comment), to skip straight past
  /// the login screen when possible.
  ///
  /// Deliberately **does not** call [signOut] on an ambiguous failure (no
  /// network and nothing cached yet, or any other lookup error) — unlike
  /// [_authorize], which is right to sign out on failure since that path
  /// only ever runs during an interactive attempt that hasn't actually let
  /// anyone in yet. Signing out *here* would destroy the one thing making
  /// offline use possible at all, the next time this device has no
  /// connection, over what might just be "haven't gone online since
  /// install." Returns null in that case — the caller falls back to
  /// showing the login screen for *this* launch, exactly as if this method
  /// didn't exist, and Firebase's session stays intact to try again.
  ///
  /// A **definitive** denial (the Firestore record was found — fresh or
  /// from cache — and says inactive, or an unrecognized role) is still
  /// signed out, same as [_authorize]: that's a real, trustworthy answer
  /// either way, not a "we don't know."
  ///
  /// `cloud_firestore` keeps its own on-device cache of every document
  /// already fetched (enabled by default on mobile, not configured
  /// anywhere in this app) — the user document this reads was already
  /// fetched once during the original interactive login, so this resolves
  /// from that cache with no network needed on every restore after the
  /// first.
  Future<UserModel?> restoreSession() async {
    final user = _auth.currentUser;
    if (user == null) return null;

    UserModel? firestoreUser;
    try {
      firestoreUser = await _firestoreService
          .getUserById(user.uid)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      print('Auth: session restore lookup failed for ${user.uid} (leaving session intact): $e');
      return null;
    }

    if (firestoreUser == null) return null;

    if (!firestoreUser.isActive || !_knownRoles.contains(firestoreUser.role)) {
      await signOut();
      return null;
    }

    return firestoreUser;
  }

  Future<void> signOut() async {
    await _auth.signOut();
    final googleSignIn = _googleSignIn;
    if (googleSignIn != null) {
      await googleSignIn.signOut();
    }
  }

  /// Authorizes an already-Firebase-authenticated [user] against Firestore,
  /// for the login portal that requires [requiredRole].
  /// Fails closed on every path:
  ///
  /// - No Firestore user record -> deny. Accounts are provisioned by an
  ///   administrator beforehand (there is no in-app user-management screen
  ///   yet); signing in with Firebase never creates one anymore.
  /// - Record exists but `isActive == false` -> deny.
  /// - Record exists, active, but `role` isn't one this app recognizes ->
  ///   deny (never falls back to a default role).
  /// - Record exists, active, known role, but that role isn't
  ///   [requiredRole] -> deny with [WrongPortalException] (the account is
  ///   valid, it's just using the wrong portal — e.g. a `guidance_council`
  ///   account on the Web Admin login).
  /// - The Firestore lookup itself fails (network, rules, etc.) -> deny;
  ///   never treated as "not found" and never silently let through.
  ///
  /// Every deny path signs the user back out before throwing.
  Future<UserModel> _authorize(User? user, {required String requiredRole}) async {
    if (user == null) {
      throw UserVerificationException('Sign-in succeeded but no user profile was returned.');
    }

    UserModel? firestoreUser;
    try {
      firestoreUser = await _firestoreService.getUserById(user.uid);
    } catch (e) {
      await signOut();
      print('Auth: Firestore lookup failed while authorizing ${user.uid}: $e');
      throw UserVerificationException('Unable to verify your account. Please try again.');
    }

    if (firestoreUser == null) {
      await signOut();
      throw UserNotConfiguredException(
        'Your account is not authorized to access this system. Please contact the System Administrator.',
      );
    }

    if (!firestoreUser.isActive) {
      await signOut();
      throw UserDeactivatedException(
        'Your account has been deactivated. Please contact the System Administrator.',
      );
    }

    if (!_knownRoles.contains(firestoreUser.role)) {
      await signOut();
      print('Auth: user ${user.uid} has an unrecognized role "${firestoreUser.role}"');
      throw UserNotConfiguredException(
        'Your account is not authorized to access this system. Please contact the System Administrator.',
      );
    }

    if (firestoreUser.role != requiredRole) {
      await signOut();
      throw WrongPortalException(
        requiredRole == 'system_admin'
            ? 'This login is for System Administrators only. Guidance Council staff should use the GuideGrade mobile app.'
            : 'This app is for Guidance Council staff only. System Administrators should use the Web admin console.',
      );
    }

    try {
      await _firestoreService.updateLastLogin(user.uid);
    } catch (e) {
      // Last-login is a courtesy timestamp, not an authorization signal —
      // don't block an already-approved sign-in over it.
      print('Auth: failed to update lastLoginAt for ${user.uid}: $e');
    }

    // Only System Administrator logins are logged in v1 (Guidance Council
    // login logging is explicitly out of scope for now — see the System
    // Logs design). This runs only after authentication AND authorization
    // have both fully succeeded, per the requirement that LOGIN_SUCCESS
    // never fires for a denied or partially-completed sign-in.
    if (firestoreUser.role == 'system_admin') {
      await LoggingService().logLoginSuccess(firestoreUser);
    }

    return firestoreUser;
  }

  static String messageFor(dynamic error) {
    if (error is UserNotConfiguredException) {
      return error.message;
    }

    if (error is UserDeactivatedException) {
      return error.message;
    }

    if (error is UserVerificationException) {
      return error.message;
    }

    if (error is WrongPortalException) {
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
        // Deliberately generic: avoid surfacing raw Firebase SDK error text.
        return 'Sign-in failed. Please try again.';
    }
  }
}
