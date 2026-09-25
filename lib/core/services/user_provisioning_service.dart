import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firestore_service.dart';
import 'logging_service.dart';
import '../../models/user.dart';

/// Thrown when the email being provisioned already belongs to an existing
/// account (checked both in Firestore and, authoritatively, by Firebase
/// Auth itself).
class EmailAlreadyExistsException implements Exception {
  final String message;
  EmailAlreadyExistsException([this.message = 'An account with this email already exists.']);
}

/// Thrown for any other provisioning failure (account creation itself,
/// or the follow-up Firestore write).
class UserProvisioningException implements Exception {
  final String message;
  UserProvisioningException(this.message);
}

/// Creates new Guidance Council accounts from the System Administrator's Web
/// console: a real Firebase Authentication identity plus a matching
/// `users/{uid}` Firestore document.
///
/// This deliberately does NOT use the Firebase Admin SDK -- no
/// service-account credential exists anywhere in this client app, and none
/// should. Creating a Firebase Auth user via the normal client SDK signs
/// the caller in *as* that new user, which would silently end the admin's
/// own session if done on `FirebaseAuth.instance`. To avoid that, account
/// creation runs on a second, throwaway `FirebaseApp`/`FirebaseAuth`
/// instance; the admin's primary session (`FirebaseAuth.instance`) is never
/// touched, so they remain signed in throughout.
///
/// The admin never sees, chooses, or stores the new account's password --
/// a single-use, securely-random password is used only to satisfy Firebase
/// Auth's account-creation call, and is immediately followed by a
/// password-reset email so the new user sets their own password.
class UserProvisioningService {
  UserProvisioningService({FirestoreService? firestoreService, LoggingService? loggingService})
      : _firestoreService = firestoreService ?? FirestoreService(),
        _loggingService = loggingService ?? LoggingService();

  final FirestoreService _firestoreService;
  final LoggingService _loggingService;

  /// Creates a new, active `guidance_council` account for [email].
  ///
  /// [actor] is the System Administrator performing this action -- their
  /// UID becomes the new record's `createdBy`, and (per
  /// [LoggingService.createLog]'s own actor/session cross-check) they're
  /// who USER_CREATED / DUPLICATE_EMAIL_ATTEMPT log entries are attributed
  /// to. Never accept this as an arbitrary string; it must be the actually
  /// signed-in admin's own [UserModel] (e.g. `AppState.currentUser`).
  ///
  /// Order of operations (see class doc for why): create the Firebase Auth
  /// account on a secondary app instance, email the new user a
  /// password-setup link, then write the Firestore `users/{uid}` document
  /// using the caller's own (primary, still-signed-in-admin) session. If
  /// the Firestore write fails, the just-created Auth account is deleted
  /// (best-effort, while still reachable on the secondary instance) before
  /// this throws -- so a failed creation never leaves behind an account
  /// that could sign in without a matching Firestore record.
  ///
  /// Throws [EmailAlreadyExistsException] if the email is already
  /// registered, or [UserProvisioningException] for any other failure.
  /// The admin's own signed-in session (`FirebaseAuth.instance`) is never
  /// touched by any path through this method. A logging failure never
  /// surfaces as a failure of this method -- see [LoggingService.createLog].
  Future<UserModel> createGuidanceCouncilUser({
    required String email,
    required String displayName,
    required String firstName,
    required String middleInitial,
    required String lastName,
    required UserModel actor,
    String? guidancePosition,
    String institution = 'NDMU',
  }) async {
    // The structured name is required for a Guidance Council account. Checked
    // first, before anything is looked up or created, so a bad name never
    // leaves an Auth account behind.
    final nameError = UserNameRules.validateFirstName(firstName) ??
        UserNameRules.validateMiddleInitial(middleInitial) ??
        UserNameRules.validateLastName(lastName);
    if (nameError != null) throw UserProvisioningException(nameError);

    final normalizedEmail = email.trim();

    final existing = await _firestoreService.getUserByEmail(normalizedEmail);
    if (existing != null) {
      await _loggingService.logDuplicateEmailAttempt(actor, attemptedEmail: normalizedEmail);
      throw EmailAlreadyExistsException();
    }

    FirebaseApp? provisioningApp;
    UserCredential? credential;
    try {
      provisioningApp = await Firebase.initializeApp(
        name: 'user-provisioning-${DateTime.now().microsecondsSinceEpoch}',
        options: Firebase.app().options,
      );
      final provisioningAuth = FirebaseAuth.instanceFor(app: provisioningApp);

      credential = await provisioningAuth.createUserWithEmailAndPassword(
        email: normalizedEmail,
        password: _generateOneTimePassword(),
      );
      final newUid = credential.user?.uid;
      if (newUid == null) {
        throw UserProvisioningException('Account creation did not return a user ID. Please try again.');
      }

      // The new user sets their own password via this link -- this app
      // never stores, displays, or even holds the one-time password beyond
      // the call above.
      try {
        await provisioningAuth.sendPasswordResetEmail(email: normalizedEmail);
      } catch (e) {
        // Non-fatal: the account is still valid; a reset email can be
        // re-sent later from Edit User if this particular send failed.
        print('UserProvisioning: could not send the setup email to $normalizedEmail: $e');
      }

      final newUser = buildGuidanceCouncilUser(
        userId: newUid,
        email: normalizedEmail,
        displayName: displayName,
        firstName: firstName,
        middleInitial: middleInitial,
        lastName: lastName,
        createdBy: actor.userId,
        guidancePosition: guidancePosition,
        institution: institution,
        createdAt: DateTime.now(),
      );

      try {
        // Runs on FirestoreService's default-app Firestore instance, which
        // is bound to the ADMIN's primary FirebaseAuth session (untouched
        // by the secondary app above) -- so the deployed isSystemAdmin()
        // rule sees the real admin as the caller, exactly as intended.
        await _firestoreService.createUserWithId(newUser);
      } catch (e) {
        // Best-effort rollback: delete the orphaned Auth account while it's
        // still reachable on the secondary, still-signed-in instance, so a
        // failed creation never leaves behind an account with no matching
        // Firestore document that could otherwise sit around unused.
        try {
          await credential.user?.delete();
        } catch (_) {
          // If cleanup itself fails, the orphaned account still has no
          // users/{uid} document -- AuthService._authorize() denies any
          // sign-in for it with UserNotConfiguredException, so it cannot
          // access the application either way.
        }
        throw UserProvisioningException(
          'The account was created but the user record could not be saved, so it has been rolled back. Please try again.',
        );
      }

      // Both Firebase Authentication account creation AND the Firestore
      // users/{uid} write have now succeeded -- log exactly once, here,
      // not at any earlier point that could still fail or roll back.
      await _loggingService.logUserCreated(actor, targetUserId: newUid, targetUserEmail: normalizedEmail);

      return newUser;
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        await _loggingService.logDuplicateEmailAttempt(actor, attemptedEmail: normalizedEmail);
        throw EmailAlreadyExistsException();
      }
      throw UserProvisioningException(_messageForCreateError(e));
    } finally {
      if (provisioningApp != null) {
        try {
          final provisioningAuth = FirebaseAuth.instanceFor(app: provisioningApp);
          await provisioningAuth.signOut();
        } catch (_) {
          // Ignore -- deleting the app below is what actually matters.
        }
        try {
          await provisioningApp.delete();
        } catch (_) {
          // A leftover throwaway FirebaseApp instance doesn't expose
          // anything and doesn't affect the admin's primary session.
        }
      }
    }
  }

  /// The `users/{uid}` profile written for a newly created Guidance Council
  /// account. Pure (no Firebase), so what gets stored can be checked directly.
  ///
  /// [displayName] is stored exactly as the System Administrator entered it
  /// (only trimmed) -- it is an independent field and is NEVER derived from
  /// the structured name. The names are trimmed, and the middle initial is
  /// normalized to "X." (see [UserNameRules.normalizeMiddleInitial]).
  static UserModel buildGuidanceCouncilUser({
    required String userId,
    required String email,
    required String displayName,
    required String firstName,
    required String middleInitial,
    required String lastName,
    required String createdBy,
    required DateTime createdAt,
    String? guidancePosition,
    String institution = 'NDMU',
  }) {
    return UserModel(
      userId: userId,
      email: email.trim(),
      displayName: displayName.trim(),
      role: 'guidance_council',
      guidancePosition: guidancePosition,
      isActive: true,
      createdAt: createdAt,
      lastLoginAt: null,
      passwordResetRequired: true,
      createdBy: createdBy,
      institution: institution,
      firstName: firstName.trim(),
      middleInitial: UserNameRules.normalizeMiddleInitial(middleInitial),
      lastName: lastName.trim(),
    );
  }

  /// A single-use password satisfying Firebase Auth's minimum requirements,
  /// generated with a cryptographically secure source. Never logged,
  /// stored, returned, or displayed -- used only to complete the account-
  /// creation call above, immediately followed by a password-reset email.
  String _generateOneTimePassword() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%^&*';
    final random = Random.secure();
    return List.generate(32, (_) => chars[random.nextInt(chars.length)]).join();
  }

  String _messageForCreateError(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-email':
        return 'That email address is not valid.';
      case 'operation-not-allowed':
        return 'Email/password accounts are not enabled for this project.';
      default:
        return 'Could not create the account. Please try again.';
    }
  }
}
