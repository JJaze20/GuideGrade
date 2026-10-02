// STOPGAP: this file did not exist in the repo — every file that references
// AnswerKeyModel (lib/core/omr/answer_key_adapter.dart,
// lib/core/services/firestore_service.dart,
// lib/features/guidance/screens/answer_key_management_screen.dart,
// lib/features/guidance/screens/edit_exam_screen.dart) already assumed this
// shape and has since 3f2c1bc, but the model class itself was never
// committed, so every release build fails at compile time. This
// reconstructs the exact shape those call sites already require (see their
// usage of the constructor, .isFinal, .isLegacy, .answers,
// .legacyFlatAnswers, .copyWith, .toFirestore/.fromFirestore) so the app
// compiles again — it is NOT a verified reimplementation of the intended
// Guidance Council answer-key schema. Whoever owns that feature should
// review this against their actual Firestore documents (especially
// fromFirestore's legacy-document field guesses) before relying on it.

/// A Guidance Council answer key document, as stored in Firestore's
/// `answerKeys` collection.
class AnswerKeyModel {
  /// Firestore document ID; empty string for a not-yet-created key.
  final String answerKeyId;
  final String examId;
  final String version;
  final String status; // 'Draft' | 'Final'
  final int schemaVersion;

  /// Section-shaped answers: section name -> item number (as string) ->
  /// correct choice. Only meaningful when this key is current-schema (see
  /// [isLegacy]) — a legacy document's real answers live in
  /// [legacyFlatAnswers] instead.
  final Map<String, Map<String, String>> answers;

  /// Flat item-number -> choice answers, as stored before section support
  /// existed. Only meaningful when [isLegacy] is true.
  final Map<String, String> legacyFlatAnswers;

  final int totalItems;
  final String createdByUid;
  final String createdByName;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The schema version current code writes. A document with a lower
  /// [schemaVersion] (or missing the field entirely) predates section
  /// support and is treated as legacy — see [isLegacy].
  static const int currentSchemaVersion = 2;

  const AnswerKeyModel({
    required this.answerKeyId,
    required this.examId,
    required this.version,
    required this.status,
    required this.schemaVersion,
    required this.answers,
    required this.legacyFlatAnswers,
    required this.totalItems,
    required this.createdByUid,
    required this.createdByName,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isFinal => status == 'Final';

  bool get isDraft => status == 'Draft';

  bool get isLegacy => schemaVersion < currentSchemaVersion;

  factory AnswerKeyModel.fromFirestore(Map<String, dynamic> data, String documentId) {
    final schemaVersion = data['schemaVersion'] as int? ?? 1;

    Map<String, Map<String, String>> parseAnswers(dynamic raw) {
      if (raw is! Map) return {};
      return raw.map(
        (sectionName, items) => MapEntry(
          sectionName as String,
          items is Map ? items.map((k, v) => MapEntry(k as String, v as String)) : <String, String>{},
        ),
      );
    }

    Map<String, String> parseFlatAnswers(dynamic raw) {
      if (raw is! Map) return {};
      return raw.map((k, v) => MapEntry(k as String, v as String));
    }

    final rawAnswers = data['answers'];
    return AnswerKeyModel(
      answerKeyId: documentId,
      examId: data['examId'] as String,
      version: data['version'] as String? ?? '1.0',
      status: data['status'] as String? ?? 'Draft',
      schemaVersion: schemaVersion,
      // A legacy (pre-section-support) document stored its answers as a
      // flat item-number map directly under 'answers'; a current-schema
      // document stores them nested under section name. Since the two
      // shapes are structurally distinguishable (nested map vs. flat
      // string map) this reads whichever actually matches instead of
      // trusting schemaVersion alone.
      answers: schemaVersion >= currentSchemaVersion ? parseAnswers(rawAnswers) : {},
      legacyFlatAnswers: schemaVersion < currentSchemaVersion
          ? parseFlatAnswers(data['legacyFlatAnswers'] ?? rawAnswers)
          : {},
      totalItems: data['totalItems'] as int? ?? 0,
      createdByUid: data['createdByUid'] as String? ?? '',
      createdByName: data['createdByName'] as String? ?? 'Unknown',
      createdAt: DateTime.tryParse(data['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(data['updatedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'examId': examId,
      'version': version,
      'status': status,
      'schemaVersion': schemaVersion,
      'answers': answers,
      'legacyFlatAnswers': legacyFlatAnswers,
      'totalItems': totalItems,
      'createdByUid': createdByUid,
      'createdByName': createdByName,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  AnswerKeyModel copyWith({
    String? answerKeyId,
    String? examId,
    String? version,
    String? status,
    int? schemaVersion,
    Map<String, Map<String, String>>? answers,
    Map<String, String>? legacyFlatAnswers,
    int? totalItems,
    String? createdByUid,
    String? createdByName,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AnswerKeyModel(
      answerKeyId: answerKeyId ?? this.answerKeyId,
      examId: examId ?? this.examId,
      version: version ?? this.version,
      status: status ?? this.status,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      answers: answers ?? this.answers,
      legacyFlatAnswers: legacyFlatAnswers ?? this.legacyFlatAnswers,
      totalItems: totalItems ?? this.totalItems,
      createdByUid: createdByUid ?? this.createdByUid,
      createdByName: createdByName ?? this.createdByName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
