import 'package:cloud_firestore/cloud_firestore.dart';

/// Fixed, code-defined log categories. Never accept an arbitrary string from
/// the UI or a caller -- [LoggingService.createLog] asserts against [all],
/// and the deployed Firestore rules independently re-validate the same set
/// server-side.
class LogCategory {
  LogCategory._();

  static const String authentication = 'AUTHENTICATION';
  static const String userManagement = 'USER_MANAGEMENT';
  static const String authorization = 'AUTHORIZATION';

  static const Set<String> all = {authentication, userManagement, authorization};
}

/// Fixed, code-defined severities. Intentionally just two levels -- see
/// LogCategory doc.
class LogSeverity {
  LogSeverity._();

  static const String info = 'INFO';
  static const String warning = 'WARNING';

  static const Set<String> all = {info, warning};
}

/// Fixed, code-defined actions. This is the complete v1 event set -- no
/// other action string is ever written by [LoggingService].
class LogAction {
  LogAction._();

  // AUTHENTICATION
  static const String loginSuccess = 'LOGIN_SUCCESS';
  static const String logout = 'LOGOUT';

  // USER_MANAGEMENT
  static const String userCreated = 'USER_CREATED';
  static const String userActivated = 'USER_ACTIVATED';
  static const String userDeactivated = 'USER_DEACTIVATED';
  static const String passwordResetSent = 'PASSWORD_RESET_SENT';
  static const String duplicateEmailAttempt = 'DUPLICATE_EMAIL_ATTEMPT';

  // AUTHORIZATION
  static const String adminGuidanceRouteDenied = 'ADMIN_GUIDANCE_ROUTE_DENIED';

  static const Set<String> all = {
    loginSuccess,
    logout,
    userCreated,
    userActivated,
    userDeactivated,
    passwordResetSent,
    duplicateEmailAttempt,
    adminGuidanceRouteDenied,
  };
}

/// A single append-only System Logs entry (`logs/{logId}` in Firestore).
///
/// Unlike the app's other models, this one deliberately depends on
/// `cloud_firestore` directly (for [Timestamp]/[FieldValue]) rather than
/// storing an ISO-8601 string: a log's timestamp must be server-assigned
/// (`FieldValue.serverTimestamp()`), never a client-computed `DateTime.now()`
/// -- see [LoggingService.createLog].
class LogEntry {
  final String logId;

  /// Null only for the brief local-cache window before Firestore resolves
  /// the server timestamp placeholder into a real value.
  final DateTime? timestamp;

  final String actorUid;
  final String actorEmail;
  final String actorRole;
  final String action;
  final String category;
  final String? targetUserId;
  final String? targetUserEmail;
  final String description;
  final bool success;
  final String severity;

  const LogEntry({
    required this.logId,
    required this.timestamp,
    required this.actorUid,
    required this.actorEmail,
    required this.actorRole,
    required this.action,
    required this.category,
    this.targetUserId,
    this.targetUserEmail,
    required this.description,
    required this.success,
    required this.severity,
  });

  factory LogEntry.fromFirestore(Map<String, dynamic> data, String documentId) {
    final rawTimestamp = data['timestamp'];
    return LogEntry(
      logId: documentId,
      timestamp: rawTimestamp is Timestamp ? rawTimestamp.toDate() : null,
      actorUid: data['actorUid'] as String,
      actorEmail: data['actorEmail'] as String,
      actorRole: data['actorRole'] as String,
      action: data['action'] as String,
      category: data['category'] as String,
      targetUserId: data['targetUserId'] as String?,
      targetUserEmail: data['targetUserEmail'] as String?,
      description: data['description'] as String? ?? '',
      success: data['success'] as bool? ?? true,
      severity: data['severity'] as String? ?? LogSeverity.info,
    );
  }
}
