import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../models/log_entry.dart';
import '../../models/user.dart';

/// One page of logs, newest first, plus the cursor needed to load the next
/// page via [LoggingService.getRecentLogs]'s `startAfter`.
class LogPage {
  final List<LogEntry> entries;
  final DocumentSnapshot? lastDocument;
  final bool hasMore;

  const LogPage({required this.entries, required this.lastDocument, required this.hasMore});

  static const empty = LogPage(entries: [], lastDocument: null, hasMore: false);
}

/// Writes and reads the append-only `logs` collection -- the System
/// Administrator's audit trail. Deliberately independent of
/// [FirestoreService] (a separate, narrowly-scoped concern, not another
/// method bolted onto an already-large service class).
///
/// Security posture, enforced both here AND (independently, authoritatively)
/// by the deployed Firestore rules:
/// - `actorUid`/`actorEmail` are always read live from
///   `FirebaseAuth.instance.currentUser` -- never accepted as a
///   caller-supplied value, so this can never be used to attribute a log
///   entry to anyone other than whoever is actually signed in when
///   [createLog] runs.
/// - `action`/`category`/`severity` must come from the fixed sets in
///   `log_entry.dart` -- asserted here, and re-validated server-side by the
///   rules regardless, since a client-side assertion alone is not a
///   security boundary.
/// - `timestamp` is always `FieldValue.serverTimestamp()`, never a
///   client-computed `DateTime.now()`.
/// - [createLog] never throws. A logging failure must never break the
///   feature that triggered it (user creation, activation, etc.) -- errors
///   are caught, printed for developers, and swallowed.
class LoggingService {
  LoggingService({FirebaseFirestore? firestore, FirebaseAuth? firebaseAuth})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = firebaseAuth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CollectionReference get _logsCollection => _firestore.collection('logs');

  /// Writes one append-only log entry, attributed to whoever is actually
  /// signed in right now.
  ///
  /// [actor] supplies the role to record (`actorRole`) and is a defensive
  /// cross-check, not the source of truth for identity: if [actor].userId
  /// doesn't match the live `FirebaseAuth.instance.currentUser`'s UID, the
  /// write is skipped rather than risking a misattributed entry. The
  /// `actorUid`/`actorEmail` actually written always come from the live
  /// Firebase session, never from [actor] directly.
  ///
  /// Never throws -- see class doc.
  Future<void> createLog({
    required UserModel actor,
    required String action,
    required String category,
    required String description,
    bool success = true,
    String severity = LogSeverity.info,
    String? targetUserId,
    String? targetUserEmail,
  }) async {
    assert(LogAction.all.contains(action), 'Unknown log action: $action');
    assert(LogCategory.all.contains(category), 'Unknown log category: $category');
    assert(LogSeverity.all.contains(severity), 'Unknown log severity: $severity');

    final currentUser = _auth.currentUser;
    if (currentUser == null || currentUser.uid != actor.userId) {
      // Defensive: never attribute a log entry to anyone other than whoever
      // is actually signed in right now. If this ever doesn't match,
      // something upstream is wrong -- skip the write rather than risk a
      // misattributed (and rules-rejected anyway, per actorUid ==
      // request.auth.uid) entry.
      print('LoggingService: refusing to write "$action" -- actor/session mismatch.');
      return;
    }

    try {
      await _logsCollection.add({
        'timestamp': FieldValue.serverTimestamp(),
        'actorUid': currentUser.uid,
        'actorEmail': currentUser.email ?? actor.email,
        'actorRole': actor.role,
        'action': action,
        'category': category,
        if (targetUserId != null) 'targetUserId': targetUserId,
        if (targetUserEmail != null) 'targetUserEmail': targetUserEmail,
        'description': description,
        'success': success,
        'severity': severity,
      });
    } catch (e) {
      // Logging must never break the feature that triggered it.
      print('LoggingService: failed to write log "$action": $e');
    }
  }

  // --------------------------------------------------------------------
  // Convenience wrappers for the fixed v1 event set -- these exist so
  // every call site uses exactly the right action/category/severity
  // pairing, rather than each caller reconstructing it by hand.
  // --------------------------------------------------------------------

  Future<void> logLoginSuccess(UserModel actor) {
    return createLog(
      actor: actor,
      action: LogAction.loginSuccess,
      category: LogCategory.authentication,
      description: 'System Administrator signed in.',
    );
  }

  Future<void> logLogout(UserModel actor) {
    return createLog(
      actor: actor,
      action: LogAction.logout,
      category: LogCategory.authentication,
      description: 'System Administrator signed out.',
    );
  }

  Future<void> logUserCreated(UserModel actor, {required String targetUserId, required String targetUserEmail}) {
    return createLog(
      actor: actor,
      action: LogAction.userCreated,
      category: LogCategory.userManagement,
      description: 'Created Guidance Council account for $targetUserEmail.',
      targetUserId: targetUserId,
      targetUserEmail: targetUserEmail,
    );
  }

  Future<void> logUserActivated(UserModel actor, {required String targetUserId, required String targetUserEmail}) {
    return createLog(
      actor: actor,
      action: LogAction.userActivated,
      category: LogCategory.userManagement,
      description: 'Activated the account for $targetUserEmail.',
      targetUserId: targetUserId,
      targetUserEmail: targetUserEmail,
    );
  }

  Future<void> logUserDeactivated(UserModel actor, {required String targetUserId, required String targetUserEmail}) {
    return createLog(
      actor: actor,
      action: LogAction.userDeactivated,
      category: LogCategory.userManagement,
      description: 'Deactivated the account for $targetUserEmail.',
      targetUserId: targetUserId,
      targetUserEmail: targetUserEmail,
    );
  }

  Future<void> logPasswordResetSent(UserModel actor, {required String targetUserId, required String targetUserEmail}) {
    return createLog(
      actor: actor,
      action: LogAction.passwordResetSent,
      category: LogCategory.userManagement,
      description: 'Sent a password reset email to $targetUserEmail.',
      targetUserId: targetUserId,
      targetUserEmail: targetUserEmail,
    );
  }

  Future<void> logDuplicateEmailAttempt(UserModel actor, {required String attemptedEmail}) {
    return createLog(
      actor: actor,
      action: LogAction.duplicateEmailAttempt,
      category: LogCategory.userManagement,
      description: 'Attempted to create an account with an email that already exists: $attemptedEmail.',
      targetUserEmail: attemptedEmail,
      success: false,
      severity: LogSeverity.warning,
    );
  }

  Future<void> logAdminGuidanceRouteDenied(UserModel actor, {required String route}) {
    return createLog(
      actor: actor,
      action: LogAction.adminGuidanceRouteDenied,
      category: LogCategory.authorization,
      description: 'Blocked access to the Guidance Council route "$route".',
      success: false,
      severity: LogSeverity.warning,
    );
  }

  // --------------------------------------------------------------------
  // Reading -- one-shot, paginated (not a live stream: logs only ever
  // grow, so an unbounded snapshots() listener isn't appropriate here the
  // way it is for the small, slow-changing users collection).
  // --------------------------------------------------------------------

  /// The most recent [limit] logs, newest first. Pass a previous
  /// [LogPage.lastDocument] as [startAfter] to load the next page.
  Future<LogPage> getRecentLogs({int limit = 100, DocumentSnapshot? startAfter}) async {
    try {
      Query query = _logsCollection.orderBy('timestamp', descending: true).limit(limit);
      if (startAfter != null) {
        query = query.startAfterDocument(startAfter);
      }
      final snapshot = await query.get();
      final entries = snapshot.docs
          .map((doc) => LogEntry.fromFirestore(doc.data() as Map<String, dynamic>, doc.id))
          .toList();
      return LogPage(
        entries: entries,
        lastDocument: snapshot.docs.isNotEmpty ? snapshot.docs.last : startAfter,
        hasMore: snapshot.docs.length == limit,
      );
    } catch (e) {
      print('LoggingService: failed to load logs: $e');
      return LogPage.empty;
    }
  }
}
