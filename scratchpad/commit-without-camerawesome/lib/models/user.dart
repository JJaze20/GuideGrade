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
    );
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
    );
  }

  /// Helper to check if user is System Admin
  bool get isSystemAdmin => role == 'system_admin';

  /// Helper to check if user is Guidance Council
  bool get isGuidanceCouncil => role == 'guidance_council';
}
