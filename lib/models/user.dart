/// User model representing a user in the Firestore users collection.
class UserModel {
  final String userId;
  final String email;
  final String displayName;
  final String role; // 'system_admin' | 'guidance_council'
  final String? guidancePosition; // 'guidance_head' | 'psychometrician' | 'guidance_staff' | null
  final bool isActive;
  final DateTime createdAt;
  final DateTime? lastLoginAt;
  final bool passwordResetRequired;
  final String? createdBy;
  final String institution;

  /// The account holder's structured name (Guidance Council accounts). All
  /// three are optional here so a user document written before they existed
  /// (which has only [displayName]) still loads. [displayName] stays a
  /// separate, independently edited field -- it is never derived from these.
  final String? firstName;

  /// A single letter followed by a period, e.g. `D.` (see
  /// [UserNameRules.normalizeMiddleInitial]).
  final String? middleInitial;
  final String? lastName;

  const UserModel({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.role,
    this.guidancePosition,
    required this.isActive,
    required this.createdAt,
    this.lastLoginAt,
    this.passwordResetRequired = false,
    this.createdBy,
    this.institution = 'NDMU',
    this.firstName,
    this.middleInitial,
    this.lastName,
  });

  /// Creates a UserModel from Firestore document data
  factory UserModel.fromFirestore(Map<String, dynamic> data, String documentId) {
    return UserModel(
      userId: documentId,
      email: data['email'] as String,
      displayName: data['displayName'] as String,
      role: data['role'] as String,
      guidancePosition: data['guidancePosition'] as String?,
      isActive: data['isActive'] as bool,
      createdAt: DateTime.parse(data['createdAt'] as String),
      lastLoginAt: data['lastLoginAt'] != null 
          ? DateTime.parse(data['lastLoginAt'] as String) 
          : null,
      passwordResetRequired: data['passwordResetRequired'] as bool? ?? false,
      createdBy: data['createdBy'] as String?,
      institution: data['institution'] as String? ?? 'NDMU',
      firstName: _optionalName(data['firstName']),
      middleInitial: _optionalName(data['middleInitial']),
      lastName: _optionalName(data['lastName']),
    );
  }

  /// A stored name part, or null when the document has none (older users) or
  /// it is blank.
  static String? _optionalName(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Converts UserModel to Firestore document data
  Map<String, dynamic> toFirestore() {
    return {
      'email': email,
      'displayName': displayName,
      'role': role,
      'guidancePosition': guidancePosition,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
      'lastLoginAt': lastLoginAt?.toIso8601String(),
      'passwordResetRequired': passwordResetRequired,
      'createdBy': createdBy,
      'institution': institution,
      // Written only when present, so saving a user who has no structured
      // name (an older account) never adds empty fields to their document.
      if (firstName != null) 'firstName': firstName,
      if (middleInitial != null) 'middleInitial': middleInitial,
      if (lastName != null) 'lastName': lastName,
    };
  }

  /// Creates a copy of this UserModel with some fields replaced
  UserModel copyWith({
    String? userId,
    String? email,
    String? displayName,
    String? role,
    String? guidancePosition,
    bool? isActive,
    DateTime? createdAt,
    DateTime? lastLoginAt,
    bool? passwordResetRequired,
    String? createdBy,
    String? institution,
    String? firstName,
    String? middleInitial,
    String? lastName,
  }) {
    return UserModel(
      userId: userId ?? this.userId,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      role: role ?? this.role,
      guidancePosition: guidancePosition ?? this.guidancePosition,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      passwordResetRequired: passwordResetRequired ?? this.passwordResetRequired,
      createdBy: createdBy ?? this.createdBy,
      institution: institution ?? this.institution,
      firstName: firstName ?? this.firstName,
      middleInitial: middleInitial ?? this.middleInitial,
      lastName: lastName ?? this.lastName,
    );
  }

  /// Whether any part of the structured name is stored for this user.
  bool get hasStructuredName => firstName != null || middleInitial != null || lastName != null;

  /// Helper to check if user is System Admin
  bool get isSystemAdmin => role == 'system_admin';

  /// Helper to check if user is Guidance Council
  bool get isGuidanceCouncil => role == 'guidance_council';
}

/// Validation and normalization for a Guidance Council account's structured
/// name (First Name / Middle Initial / Last Name), shared by Create User, Edit
/// User and the provisioning service so they all apply the same rules.
class UserNameRules {
  const UserNameRules._();

  /// One letter (any alphabet), optionally followed by a period.
  static final RegExp _middleInitialPattern = RegExp(r'^\p{L}\.?$', unicode: true);

  static String? validateFirstName(String? value) =>
      (value == null || value.trim().isEmpty) ? 'First Name is required' : null;

  static String? validateLastName(String? value) =>
      (value == null || value.trim().isEmpty) ? 'Last Name is required' : null;

  /// Required; a single letter, with or without a trailing period ("J" or
  /// "J."). A full middle name is rejected.
  static String? validateMiddleInitial(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return 'Middle Initial is required';
    if (!_middleInitialPattern.hasMatch(trimmed)) {
      return 'Enter a single letter, e.g. D or D.';
    }
    return null;
  }

  /// The stored form of a valid middle initial: an upper-case letter and a
  /// period ("j" -> "J.", "M." -> "M."). Input that is not a valid initial is
  /// returned trimmed and unchanged.
  static String normalizeMiddleInitial(String value) {
    final trimmed = value.trim();
    if (!_middleInitialPattern.hasMatch(trimmed)) return trimmed;
    return '${trimmed.replaceAll('.', '').toUpperCase()}.';
  }
}
