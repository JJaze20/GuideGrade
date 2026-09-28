import '../../models/answer_correction.dart';
import '../../models/answer_key.dart';
import '../../models/local_batch.dart';
import '../../models/omr_scan_result.dart';
import 'exam_score.dart';
import 'omr_scorer.dart';

/// What one item reads as on a sheet.
enum AnswerStateKind { choice, blank, multiple, missing }

class AnswerState {
  final AnswerStateKind kind;
  final String? choice;
  const AnswerState._(this.kind, this.choice);

  const AnswerState.choice(String choice) : this._(AnswerStateKind.choice, choice);
  const AnswerState.blank() : this._(AnswerStateKind.blank, null);
  const AnswerState.multiple() : this._(AnswerStateKind.multiple, null);

  /// The item isn't on this sheet at all (a layout difference between the
  /// two captures) — distinct from blank.
  const AnswerState.missing() : this._(AnswerStateKind.missing, null);

  factory AnswerState.fromItem(OmrItemResult item) {
    if (item.isAmbiguous) return const AnswerState.multiple();
    final c = item.markedChoice;
    return c == null ? const AnswerState.blank() : AnswerState.choice(c);
  }

  String get label => switch (kind) {
        AnswerStateKind.choice => choice!,
        AnswerStateKind.blank => 'Blank',
        AnswerStateKind.multiple => 'Multiple marks',
        AnswerStateKind.missing => '—',
      };

  @override
  bool operator ==(Object other) =>
      other is AnswerState && other.kind == kind && other.choice == choice;

  @override
  int get hashCode => Object.hash(kind, choice);
}

/// One item whose reading differs between the original sheet and the new
/// photo, matched by section name AND item number (TAT restarts numbering in
/// every test, so the number alone would collide).
class AnswerChange {
  final String sectionName;
  final int itemNumber;
  final AnswerState original;
  final AnswerState proposed;

  /// The answer key's choice for this item, or null when the key doesn't
  /// cover it (or there is no key).
  final String? keyChoice;

  /// True when the original's reading here is a manual correction rather
  /// than what the scanner detected.
  final bool originalWasCorrected;

  const AnswerChange({
    required this.sectionName,
    required this.itemNumber,
    required this.original,
    required this.proposed,
    required this.keyChoice,
    required this.originalWasCorrected,
  });

  bool? _isRight(AnswerState s) {
    if (keyChoice == null) return null;
    return s.kind == AnswerStateKind.choice && s.choice == keyChoice;
  }

  /// Whether each side is right against the key; null when there's no key.
  bool? get originalCorrect => _isRight(original);
  bool? get proposedCorrect => _isRight(proposed);
}

/// Everything the rescan comparison panel shows about how a candidate photo
/// differs from the stored sheet it would replace. Pure data, built from the
/// candidate's ALREADY-DECODED result — nothing is decoded again.
///
/// This is advisory material for a human to look at. A high or low similarity
/// says nothing about whether the two photos are the same physical sheet.
class RescanComparison {
  final String examCode;

  /// The stored sheet as it reads today: the scanner's answers with its
  /// active manual corrections applied — what its saved score is built from.
  final ExamScore? originalScore;

  /// The candidate scored exactly as it will be saved. A replacement is a new
  /// capture, so the original's manual corrections do not apply to it (they
  /// stay in the history, flagged for review) — see [correctionsThatWillStopApplying].
  final ExamScore? proposedScore;

  /// Items whose reading differs, in the original's section/item order.
  final List<AnswerChange> changes;

  /// How many items were compared (present on either sheet).
  final int comparedItems;

  /// Manual corrections currently applied to the original that will no longer
  /// change its answers once it is replaced.
  final int correctionsThatWillStopApplying;

  const RescanComparison({
    required this.examCode,
    required this.originalScore,
    required this.proposedScore,
    required this.changes,
    required this.comparedItems,
    required this.correctionsThatWillStopApplying,
  });

  int get changedCount => changes.length;

  /// Proposed minus original headline score, or null if either is ungraded
  /// (no answer key, so neither number means anything).
  int? get scoreDelta {
    final o = originalScore;
    final p = proposedScore;
    if (o == null || p == null || !o.isGraded || !p.isGraded) return null;
    return p.rawScore - o.rawScore;
  }

  factory RescanComparison.build({
    required LocalScan original,
    required OmrScanResult candidate,
    required AnswerKey? answerKey,
  }) {
    final examCode = original.decoded.examCode;
    final originalEffective = original.effectiveDecoded;

    final originalByKey = <String, OmrItemResult>{
      for (final i in originalEffective.items) AnswerCorrection.keyFor(i.sectionName, i.itemNumber): i,
    };
    final candidateByKey = <String, OmrItemResult>{
      for (final i in candidate.items) AnswerCorrection.keyFor(i.sectionName, i.itemNumber): i,
    };
    final corrected = original.activeCorrections.keys.toSet();

    // Original's order first, then anything only the candidate has.
    final orderedKeys = <String>[
      ...originalByKey.keys,
      for (final k in candidateByKey.keys)
        if (!originalByKey.containsKey(k)) k,
    ];

    final changes = <AnswerChange>[];
    for (final key in orderedKeys) {
      final o = originalByKey[key];
      final p = candidateByKey[key];
      final oState = o == null ? const AnswerState.missing() : AnswerState.fromItem(o);
      final pState = p == null ? const AnswerState.missing() : AnswerState.fromItem(p);
      if (oState == pState) continue;
      final ref = o ?? p!;
      changes.add(AnswerChange(
        sectionName: ref.sectionName,
        itemNumber: ref.itemNumber,
        original: oState,
        proposed: pState,
        keyChoice: answerKey?.choiceFor(ref.sectionName, ref.itemNumber),
        originalWasCorrected: corrected.contains(key),
      ));
    }

    ExamScore? scoreOf(OmrScanResult r) => computeExamScoreForCode(scoreOmrResult(r, answerKey));

    return RescanComparison(
      examCode: examCode,
      originalScore: scoreOf(originalEffective),
      proposedScore: scoreOf(candidate),
      changes: changes,
      comparedItems: orderedKeys.length,
      correctionsThatWillStopApplying: corrected.length,
    );
  }
}
