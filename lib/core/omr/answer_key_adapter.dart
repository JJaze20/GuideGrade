import '../../models/answer_key.dart';
import 'omr_templates.dart';

/// Thrown by FirestoreService.getFinalAnswerKeyByExamId when more than one
/// current-schema Final answer key exists for the same exam -- this should
/// never happen if finalization always goes through the single-Final-key
/// guard in the answer key editor, but it's surfaced explicitly rather than
/// silently picking one, per the "never silently choose an arbitrary Final
/// key" requirement.
class MultipleFinalAnswerKeysException implements Exception {
  final String examId;
  const MultipleFinalAnswerKeysException(this.examId);

  @override
  String toString() => 'Multiple Final answer keys exist for exam $examId.';
}

/// Converts between the Firestore [AnswerKeyModel] and the local, scorer-
/// facing [AnswerKey] -- and handles what to do with answer keys written
/// before section support existed.
///
/// Two separate concerns live here, deliberately kept apart:
///   - [buildAnswerKeyForScoring] feeds the OFFICIAL scan/scoring path. It
///     only ever accepts a Final, current-schema key -- never a legacy one,
///     regardless of exam type. This is what stands between an incompatible
///     old key and a silently wrong score.
///   - [migrateLegacyAnswerKeyForEditing] only pre-fills the answer key
///     EDITOR so staff re-entering a legacy key don't have to retype
///     everything that's still verifiably correct. Its output is never used
///     for scoring by itself -- it has to be reviewed/saved by staff first,
///     which produces a fresh, current-schema document.

/// Outcome of trying to load a usable answer key for the official scan path.
enum AnswerKeyUsability {
  usable,
  missing,
  draftOnly,
  legacyIncompatible,
  multipleFinal,
  sectionMismatch,
}

class AnswerKeyLoadResult {
  final AnswerKeyUsability usability;
  final AnswerKey? answerKey; // non-null only when usability == usable
  final String message;

  const AnswerKeyLoadResult({required this.usability, this.answerKey, required this.message});

  bool get isUsable => usability == AnswerKeyUsability.usable;
}

/// Builds the local [AnswerKey] the scorer consumes from a Firestore
/// [AnswerKeyModel], or explains exactly why one can't be used yet.
///
/// [finalKey] should already be filtered to `status == 'Final'` by the
/// caller's Firestore query (see FirestoreService.getFinalAnswerKeyByExamId)
/// -- this function additionally refuses anything that isn't current-schema,
/// which is what keeps a legacy TAT/Admission key from ever silently
/// entering the scoring path.
AnswerKeyLoadResult buildAnswerKeyForScoring({
  required AnswerKeyModel? finalKey,
  required String examCode,
}) {
  if (finalKey == null) {
    return const AnswerKeyLoadResult(
      usability: AnswerKeyUsability.missing,
      message: 'No Final answer key exists yet for this exam. Ask Guidance Council to '
          'create and finalize one before scanning.',
    );
  }

  if (!finalKey.isFinal) {
    return const AnswerKeyLoadResult(
      usability: AnswerKeyUsability.draftOnly,
      message: 'This exam only has a Draft answer key. Ask Guidance Council to finalize '
          'it before scanning.',
    );
  }

  if (finalKey.isLegacy) {
    return const AnswerKeyLoadResult(
      usability: AnswerKeyUsability.legacyIncompatible,
      message: 'This exam\'s Final answer key predates section support and cannot be used '
          'for scoring. Ask Guidance Council to re-enter and re-finalize it.',
    );
  }

  final template = omrTemplates[examCode];
  if (template == null) {
    return AnswerKeyLoadResult(
      usability: AnswerKeyUsability.sectionMismatch,
      message: 'No sheet layout is defined for exam code "$examCode".',
    );
  }

  final correctChoices = <String, String>{};
  for (final section in template.sections) {
    final sectionAnswers = finalKey.answers[section.name];
    if (sectionAnswers == null) {
      return AnswerKeyLoadResult(
        usability: AnswerKeyUsability.sectionMismatch,
        message: 'The Final answer key is missing "${section.name}" -- it does not match this '
            'exam\'s current sheet layout. Ask Guidance Council to review it.',
      );
    }
    for (final itemNumber in section.items.keys) {
      final choice = sectionAnswers[itemNumber.toString()];
      final validChoices = section.items[itemNumber]!.map((b) => b.choice).toSet();
      if (choice == null || !validChoices.contains(choice)) {
        return AnswerKeyLoadResult(
          usability: AnswerKeyUsability.sectionMismatch,
          message: 'The Final answer key has a missing or invalid answer for '
              '${section.name} item $itemNumber. Ask Guidance Council to review it.',
        );
      }
      correctChoices[AnswerKey.keyFor(section.name, itemNumber)] = choice;
    }
  }

  return AnswerKeyLoadResult(
    usability: AnswerKeyUsability.usable,
    answerKey: AnswerKey(examCode: examCode, correctChoices: correctChoices),
    message: 'Final answer key loaded.',
  );
}

/// Empty section-shaped answers map for [template] -- every section present
/// as a key, every value an empty map ready to be filled in.
Map<String, Map<String, String>> emptySectionAnswers(OmrExamTemplate template) {
  return {for (final section in template.sections) section.name: <String, String>{}};
}

class LegacyMigrationResult {
  /// Section-shaped prefill for the editor. Never assume this is complete --
  /// always re-validate against the template before saving.
  final Map<String, Map<String, String>> prefill;

  /// Human-readable note to show staff explaining what happened.
  final String note;

  /// True when the legacy key's structure can't be safely reinterpreted at
  /// all (TAT) -- prefill is intentionally empty and every item needs
  /// re-entry.
  final bool blocked;

  const LegacyMigrationResult({required this.prefill, required this.note, required this.blocked});
}

/// Pre-fills the answer key editor from a legacy (pre-section-support)
/// [AnswerKeyModel], per exam type:
///
///   - QTM: structurally safe to reinterpret -- QTM was always a single
///     continuous 1..60 section, so the old flat map already matches it.
///     Values are still checked against the template's real per-item
///     choices before being trusted.
///   - TAT: never safe. A flat "1".."N" map can't be split back into
///     Test I/II/III without guessing where each boundary falls, so
///     [blocked] is true and staff must re-enter everything.
///   - Everything else (Admission): structurally positional (one section)
///     but the stored *values* may not match the sheet's real per-item
///     choices (e.g. old entries limited to A-D when even-numbered AT
///     items actually use F-K) -- each item is validated individually and
///     only matching ones are prefilled.
LegacyMigrationResult migrateLegacyAnswerKeyForEditing(
  AnswerKeyModel legacy,
  OmrExamTemplate template,
  String examCode,
) {
  final prefill = emptySectionAnswers(template);

  if (examCode == 'TAT') {
    return const LegacyMigrationResult(
      prefill: {},
      note: 'This answer key predates section support (Test I / Test II / Test III) and '
          'cannot be safely converted. Please re-enter all answers before finalizing.',
      blocked: true,
    );
  }

  // QTM and Admission are both currently single-section templates, so the
  // same positional-plus-validation logic applies to either.
  final section = template.sections.single;
  final converted = <String, String>{};
  final flagged = <int>[];
  for (final itemNumber in section.items.keys) {
    final stored = legacy.legacyFlatAnswers[itemNumber.toString()];
    if (stored == null || stored.isEmpty) continue;
    final validChoices = section.items[itemNumber]!.map((b) => b.choice).toSet();
    if (validChoices.contains(stored)) {
      converted[itemNumber.toString()] = stored;
    } else {
      flagged.add(itemNumber);
    }
  }
  prefill[section.name] = converted;

  final missingCount = section.itemCount - converted.length;
  final String note;
  if (flagged.isEmpty && missingCount == 0) {
    note = 'Loaded from a pre-section-support answer key -- please review before finalizing.';
  } else if (flagged.isNotEmpty) {
    note = 'Loaded from a pre-section-support answer key -- item(s) ${flagged.join(', ')} used '
        'choices that don\'t match this sheet and need re-entry.';
  } else {
    note = 'Loaded from a pre-section-support answer key -- $missingCount item(s) need re-entry.';
  }

  return LegacyMigrationResult(prefill: prefill, note: note, blocked: false);
}
