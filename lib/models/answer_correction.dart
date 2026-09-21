import 'omr_scan_result.dart';

/// What a counselor says a scanned item actually shows. Deliberately limited
/// to what [OmrItemResult] (and therefore the existing scoring model) can
/// represent: one marked choice, no mark, or several marks.
///
/// This is NOT a right/wrong grade. The exam-specific scoring rules still
/// decide correctness by comparing this value with the answer key, so a
/// correction can never silently "accept" a wrong answer or edit the key.
enum CorrectedAnswerKind {
  /// Exactly one bubble is marked — [CorrectedAnswer.choice] says which.
  choice,

  /// Nothing is marked.
  blank,

  /// Two or more bubbles are marked. Scores as neither correct nor wrong,
  /// exactly like a decoder-flagged ambiguous item.
  multiple,
}

class CorrectedAnswer {
  final CorrectedAnswerKind kind;
  final String? choice;

  const CorrectedAnswer._(this.kind, this.choice);

  const CorrectedAnswer.blank() : this._(CorrectedAnswerKind.blank, null);
  const CorrectedAnswer.multiple() : this._(CorrectedAnswerKind.multiple, null);
  const CorrectedAnswer.choice(String choice)
      : this._(CorrectedAnswerKind.choice, choice);

  /// The value the decoder produced for [item] — the "original" recorded
  /// alongside every correction.
  factory CorrectedAnswer.fromDetected(OmrItemResult item) {
    if (item.isAmbiguous) return const CorrectedAnswer.multiple();
    final c = item.markedChoice;
    return c == null ? const CorrectedAnswer.blank() : CorrectedAnswer.choice(c);
  }

  bool get isBlank => kind == CorrectedAnswerKind.blank;
  bool get isMultiple => kind == CorrectedAnswerKind.multiple;

  /// Short label for lists and the editor: "B", "Blank", "Multiple marks".
  String get label => switch (kind) {
        CorrectedAnswerKind.choice => choice ?? '—',
        CorrectedAnswerKind.blank => 'Blank',
        CorrectedAnswerKind.multiple => 'Multiple marks',
      };

  @override
  bool operator ==(Object other) =>
      other is CorrectedAnswer && other.kind == kind && other.choice == choice;

  @override
  int get hashCode => Object.hash(kind, choice);

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (choice != null) 'choice': choice,
      };

  factory CorrectedAnswer.fromJson(Map<String, dynamic> json) {
    final kind = CorrectedAnswerKind.values.firstWhere(
      (k) => k.name == json['kind'],
      orElse: () => CorrectedAnswerKind.blank,
    );
    final choice = json['choice'] as String?;
    if (kind == CorrectedAnswerKind.choice && choice != null) {
      return CorrectedAnswer.choice(choice);
    }
    return kind == CorrectedAnswerKind.multiple
        ? const CorrectedAnswer.multiple()
        : const CorrectedAnswer.blank();
  }
}

/// What one history entry did.
enum CorrectionAction {
  /// The counselor set a corrected value.
  set,

  /// The counselor reset the item back to the machine-detected value.
  reset,
}

/// One entry in a scan's append-only correction history.
///
/// Keyed by scan id + [sectionName] + [itemNumber] — question numbers repeat
/// across TAT sections, so the section is part of the key. History is never
/// rewritten: a reset is a new entry, not a deletion, and entries from an
/// earlier capture stay in the list (see [captureRevision]).
class AnswerCorrection {
  /// Unique per entry. Doubles as the idempotency key when an entry is
  /// merged (a retried write with the same id changes nothing).
  final String id;
  final String scanId;

  /// The template section's name (TAT: e.g. "TEST I") — the same section key
  /// the answer key and scorer use.
  final String sectionName;
  final int itemNumber;

  /// Which capture of this scan the entry was made against — see
  /// LocalScan.captureRevision. An entry only ever applies to the capture it
  /// was made on: a rescan produces a new capture that the counselor has not
  /// looked at, so older entries are kept for history and flagged for review
  /// rather than silently applied.
  final int captureRevision;

  final CorrectionAction action;

  /// The machine-detected value at the time (never edited afterwards).
  final CorrectedAnswer original;

  /// The value the counselor set. For a [CorrectionAction.reset] entry this
  /// equals [original].
  final CorrectedAnswer corrected;

  final String? reason;
  final String? editorUid;
  final String? editorName;
  final DateTime correctedAt;

  const AnswerCorrection({
    required this.id,
    required this.scanId,
    required this.sectionName,
    required this.itemNumber,
    required this.captureRevision,
    required this.action,
    required this.original,
    required this.corrected,
    this.reason,
    this.editorUid,
    this.editorName,
    required this.correctedAt,
  });

  /// Stable identity of the item this entry is about.
  String get itemKey => keyFor(sectionName, itemNumber);

  static String keyFor(String sectionName, int itemNumber) =>
      '$sectionName|$itemNumber';

  Map<String, dynamic> toJson() => {
        'id': id,
        'scanId': scanId,
        'sectionName': sectionName,
        'itemNumber': itemNumber,
        'captureRevision': captureRevision,
        'action': action.name,
        'original': original.toJson(),
        'corrected': corrected.toJson(),
        if (reason != null) 'reason': reason,
        if (editorUid != null) 'editorUid': editorUid,
        if (editorName != null) 'editorName': editorName,
        'correctedAt': correctedAt.toIso8601String(),
      };

  factory AnswerCorrection.fromJson(Map<String, dynamic> json) =>
      AnswerCorrection(
        id: json['id'] as String,
        scanId: json['scanId'] as String,
        sectionName: json['sectionName'] as String,
        itemNumber: json['itemNumber'] as int,
        captureRevision: json['captureRevision'] as int? ?? 0,
        action: CorrectionAction.values.firstWhere(
          (a) => a.name == json['action'],
          orElse: () => CorrectionAction.set,
        ),
        original:
            CorrectedAnswer.fromJson(json['original'] as Map<String, dynamic>),
        corrected:
            CorrectedAnswer.fromJson(json['corrected'] as Map<String, dynamic>),
        reason: json['reason'] as String?,
        editorUid: json['editorUid'] as String?,
        editorName: json['editorName'] as String?,
        correctedAt: DateTime.parse(json['correctedAt'] as String),
      );
}

/// Pure rules for a scan's correction history. No I/O — the repository
/// persists whatever these return.
class CorrectionRules {
  const CorrectionRules._();

  /// The entries that currently change how [captureRevision]'s capture is
  /// read: for each item, its newest entry on this capture, kept only when
  /// that entry is a [CorrectionAction.set]. (A later reset cancels an
  /// earlier set; an entry from another capture never applies.)
  static Map<String, AnswerCorrection> activeFor(
    List<AnswerCorrection> history,
    int captureRevision,
  ) {
    final latest = <String, AnswerCorrection>{};
    for (final entry in history) {
      if (entry.captureRevision != captureRevision) continue;
      latest[entry.itemKey] = entry; // history is append-ordered
    }
    latest.removeWhere((_, e) => e.action != CorrectionAction.set);
    return latest;
  }

  /// Corrections made on an EARLIER capture that are still standing (their
  /// item's newest entry there was a set) and have not been re-decided on the
  /// current capture. These are the ones a rescan leaves "needing review":
  /// preserved, visible, never applied on their own.
  static List<AnswerCorrection> needingReview(
    List<AnswerCorrection> history,
    int currentRevision,
  ) {
    final decidedNow = <String>{
      for (final e in history)
        if (e.captureRevision == currentRevision) e.itemKey,
    };
    final latestOld = <String, AnswerCorrection>{};
    for (final e in history) {
      if (e.captureRevision >= currentRevision) continue;
      latestOld[e.itemKey] = e;
    }
    return [
      for (final e in latestOld.values)
        if (e.action == CorrectionAction.set && !decidedNow.contains(e.itemKey)) e,
    ];
  }

  /// [decoded] with every active correction applied. The machine-detected
  /// [decoded] itself is never modified — this returns a new object, and the
  /// original stays available for display and history.
  static OmrScanResult effective(
    OmrScanResult decoded,
    List<AnswerCorrection> history,
    int captureRevision,
  ) {
    final active = activeFor(history, captureRevision);
    if (active.isEmpty) return decoded;
    final items = [
      for (final item in decoded.items)
        _apply(item, active[AnswerCorrection.keyFor(item.sectionName, item.itemNumber)]),
    ];
    return OmrScanResult(
      examCode: decoded.examCode,
      items: items,
      templateVersion: decoded.templateVersion,
      meshInteriorMeasuredFrac: decoded.meshInteriorMeasuredFrac,
    );
  }

  static OmrItemResult _apply(OmrItemResult item, AnswerCorrection? c) {
    if (c == null) return item;
    final v = c.corrected;
    return OmrItemResult(
      sectionName: item.sectionName,
      itemNumber: item.itemNumber,
      markedChoice: v.kind == CorrectedAnswerKind.choice ? v.choice : null,
      isAmbiguous: v.kind == CorrectedAnswerKind.multiple,
    );
  }

  /// The value the item currently reads as (correction applied, if any).
  static CorrectedAnswer currentValue(
    OmrItemResult detected,
    List<AnswerCorrection> history,
    int captureRevision,
  ) {
    final c = activeFor(history, captureRevision)[
        AnswerCorrection.keyFor(detected.sectionName, detected.itemNumber)];
    return c?.corrected ?? CorrectedAnswer.fromDetected(detected);
  }

  /// Returns [history] with a "set" entry appended, or [history] itself
  /// (same list, unchanged) when the request would change nothing:
  ///  * an entry with the same [id] is already there (a retried/duplicate
  ///    request), or
  ///  * [value] equals what the item already reads as (a repeated tap).
  /// So applying the same correction twice can never double-record it.
  static List<AnswerCorrection> withCorrection(
    List<AnswerCorrection> history, {
    required String id,
    required String scanId,
    required int captureRevision,
    required OmrItemResult detected,
    required CorrectedAnswer value,
    String? reason,
    String? editorUid,
    String? editorName,
    required DateTime at,
  }) {
    if (history.any((e) => e.id == id)) return history;
    final now = currentValue(detected, history, captureRevision);
    if (now == value) return history;
    final original = CorrectedAnswer.fromDetected(detected);
    final trimmed = reason?.trim();
    return [
      ...history,
      AnswerCorrection(
        id: id,
        scanId: scanId,
        sectionName: detected.sectionName,
        itemNumber: detected.itemNumber,
        captureRevision: captureRevision,
        // Setting the item back to exactly what the machine read is a reset.
        action: value == original ? CorrectionAction.reset : CorrectionAction.set,
        original: original,
        corrected: value,
        reason: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
        editorUid: editorUid,
        editorName: editorName,
        correctedAt: at,
      ),
    ];
  }

  /// Returns [history] with a reset entry appended, unchanged when the item
  /// has no active correction (nothing to reset) or [id] was already used.
  static List<AnswerCorrection> withReset(
    List<AnswerCorrection> history, {
    required String id,
    required String scanId,
    required int captureRevision,
    required OmrItemResult detected,
    String? editorUid,
    String? editorName,
    required DateTime at,
  }) {
    if (history.any((e) => e.id == id)) return history;
    final key = AnswerCorrection.keyFor(detected.sectionName, detected.itemNumber);
    if (!activeFor(history, captureRevision).containsKey(key)) return history;
    final original = CorrectedAnswer.fromDetected(detected);
    return [
      ...history,
      AnswerCorrection(
        id: id,
        scanId: scanId,
        sectionName: detected.sectionName,
        itemNumber: detected.itemNumber,
        captureRevision: captureRevision,
        action: CorrectionAction.reset,
        original: original,
        corrected: original,
        editorUid: editorUid,
        editorName: editorName,
        correctedAt: at,
      ),
    ];
  }

  /// Merges two histories of the same scan (e.g. local and cloud): union by
  /// entry id, ordered by time then id, so the result is identical no matter
  /// which side is merged into which and a duplicate delivery adds nothing.
  static List<AnswerCorrection> merge(
    List<AnswerCorrection> a,
    List<AnswerCorrection> b,
  ) {
    final byId = <String, AnswerCorrection>{
      for (final e in a) e.id: e,
      for (final e in b) e.id: e,
    };
    final merged = byId.values.toList()
      ..sort((x, y) {
        final t = x.correctedAt.compareTo(y.correctedAt);
        return t != 0 ? t : x.id.compareTo(y.id);
      });
    return merged;
  }
}
