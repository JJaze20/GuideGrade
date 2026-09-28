import 'package:flutter/material.dart';

import '../../../core/omr/exam_score.dart';
import '../../../core/omr/rescan_comparison.dart';
import '../../../models/local_batch.dart';

/// How the comparison panel was left.
enum RescanDecision {
  /// The replacement was confirmed and saved.
  saved,

  /// Cancel, back navigation or dismissal: the candidate is discarded and the
  /// original sheet is exactly as it was.
  cancelled,

  /// "Retake photo": the candidate is discarded and the scanner takes over
  /// again.
  retake,
}

/// What a confirm attempt did. [canRetry] is false when trying the same
/// candidate again cannot succeed (the original changed or was deleted).
class RescanConfirmOutcome {
  final bool saved;
  final String? message;
  final bool canRetry;
  const RescanConfirmOutcome.saved() : saved = true, message = null, canRetry = true;
  const RescanConfirmOutcome.failed(this.message, {this.canRetry = true}) : saved = false;
}

/// Everything the panel shows. Images are plain [ImageProvider]s (null when
/// unavailable), so the panel neither reads storage nor knows how they were
/// obtained.
class RescanComparisonData {
  final RescanComparison comparison;

  /// The stored sheet's saved identity — what a replacement will keep.
  final ExamineeInfo? originalExaminee;

  /// The sheet's own date. A rescan never changes it.
  final DateTime originalCapturedAt;

  final ImageProvider? originalSheet;
  final ImageProvider? originalCropLast;
  final ImageProvider? originalCropFirst;
  final ImageProvider? originalCropMiddle;

  final ImageProvider? candidateSheet;
  final ImageProvider? candidateCropLast;
  final ImageProvider? candidateCropFirst;
  final ImageProvider? candidateCropMiddle;

  /// On-device OCR of the new photo's name crops. Unverified suggestions —
  /// never the saved identity.
  final String? ocrLastName;
  final String? ocrFirstName;
  final String? ocrMiddleName;

  /// Whether confirming will save the OCR suggestion into this sheet's blank
  /// name fields (true only when the sheet has no confirmed name yet). The
  /// panel says so either way, so nothing is written without being announced.
  final bool ocrSuggestionWillBeSaved;

  const RescanComparisonData({
    required this.comparison,
    required this.originalExaminee,
    required this.originalCapturedAt,
    required this.originalSheet,
    required this.originalCropLast,
    required this.originalCropFirst,
    this.originalCropMiddle,
    required this.candidateSheet,
    required this.candidateCropLast,
    required this.candidateCropFirst,
    this.candidateCropMiddle,
    this.ocrLastName,
    this.ocrFirstName,
    this.ocrMiddleName,
    this.ocrSuggestionWillBeSaved = false,
  });

  /// What is missing for a person to compare the two photos, or empty when
  /// everything needed is there. Visual verification needs both sheet photos
  /// and both sides' identifying (last and first name) crops.
  List<String> get missingForVerification => [
        if (originalSheet == null) 'the original sheet photo',
        if (originalCropLast == null || originalCropFirst == null) 'the original name crops',
        if (candidateSheet == null) 'the new sheet photo',
        if (candidateCropLast == null || candidateCropFirst == null) 'the new name crops',
      ];

  bool get canVerifyVisually => missingForVerification.isEmpty;

  bool get hasOcrSuggestion =>
      (ocrLastName ?? '').isNotEmpty || (ocrFirstName ?? '').isNotEmpty || (ocrMiddleName ?? '').isNotEmpty;
}

const _ink = Color(0xFF111827);
const _muted = Color(0xFF6B7280);
const _border = Color(0xFFE5E7EB);
const _amber = Color(0xFF92400E);
const _amberBg = Color(0xFFFEF3C7);
const _green = Color(0xFF166534);
const _red = Color(0xFF991B1B);

/// Side-by-side check, before anything is saved, that a replacement photo is
/// of the same original answer sheet. A HUMAN verification safeguard: the
/// panel shows both photos, the handwritten-name crops, the saved identity,
/// the scores and the answers that changed, and only offers to replace once
/// the reviewer states they verified the sheet. It never decides anything
/// itself — matching answers or a matching OCR name are not proof of
/// identity, and many changed answers are not grounds to refuse a
/// legitimate rescan.
///
/// Popping with [RescanDecision]: [RescanDecision.saved] after a successful
/// [onConfirm]; [RescanDecision.cancelled] for Cancel, the close button and
/// system back; [RescanDecision.retake] for Retake photo.
class RescanComparisonScreen extends StatefulWidget {
  final RescanComparisonData data;

  /// Saves the replacement. Called at most once at a time; a failure keeps
  /// the panel open (and the original untouched) for retry or cancel.
  final Future<RescanConfirmOutcome> Function() onConfirm;

  const RescanComparisonScreen({super.key, required this.data, required this.onConfirm});

  static const confirmationText =
      'I verified that this is the same original answer sheet for this examinee.';

  @override
  State<RescanComparisonScreen> createState() => _RescanComparisonScreenState();
}

class _RescanComparisonScreenState extends State<RescanComparisonScreen> {
  bool _verified = false;
  bool _saving = false;
  bool _locked = false; // a retry of this candidate can't succeed
  String? _error;

  RescanComparisonData get data => widget.data;
  bool get _canConfirm => data.canVerifyVisually && _verified && !_saving && !_locked;

  void _leave(RescanDecision decision) {
    if (_saving) return;
    Navigator.of(context).pop(decision);
  }

  Future<void> _confirm() async {
    if (!_canConfirm) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    RescanConfirmOutcome outcome;
    try {
      outcome = await widget.onConfirm();
    } catch (e) {
      outcome = RescanConfirmOutcome.failed('Could not save the rescan: $e');
    }
    if (!mounted) return;
    if (outcome.saved) {
      Navigator.of(context).pop(RescanDecision.saved);
      return;
    }
    setState(() {
      _saving = false;
      _error = outcome.message ?? 'Could not save the rescan.';
      _locked = !outcome.canRetry;
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave(RescanDecision.cancelled);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF9FAFB),
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: _ink,
          elevation: 0.5,
          title: const Text('Compare rescan', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          leading: IconButton(
            key: const ValueKey('rescan-close'),
            icon: const Icon(Icons.close),
            tooltip: 'Cancel',
            onPressed: _saving ? null : () => _leave(RescanDecision.cancelled),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth >= 720;
                    final original = _buildOriginalCard();
                    final replacement = _buildNewCard();
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildReminder(),
                          const SizedBox(height: 12),
                          if (wide)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: original),
                                const SizedBox(width: 12),
                                Expanded(child: replacement),
                              ],
                            )
                          else ...[
                            original,
                            const SizedBox(height: 12),
                            replacement,
                          ],
                          const SizedBox(height: 12),
                          _buildScores(),
                          if (data.comparison.correctionsThatWillStopApplying > 0) ...[
                            const SizedBox(height: 12),
                            _buildCorrectionsNotice(),
                          ],
                          const SizedBox(height: 12),
                          _buildChanges(),
                          const SizedBox(height: 12),
                          _buildVerification(),
                        ],
                      ),
                    );
                  },
                ),
              ),
              _buildActions(),
            ],
          ),
        ),
      ),
    );
  }

  // --- cards ---------------------------------------------------------------

  Widget _buildReminder() => Container(
        key: const ValueKey('rescan-reminder'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _amberBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFCD34D)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.fact_check_outlined, size: 18, color: _amber),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Nothing has been saved yet. Look at both photos and the handwritten name to decide '
                'whether this is the SAME original answer sheet. Matching answers or a matching name '
                'suggestion do not prove it, and changed answers do not by themselves rule it out.',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: _amber),
              ),
            ),
          ],
        ),
      );

  Widget _buildOriginalCard() {
    final examinee = data.originalExaminee;
    final tagged = examinee != null && !examinee.isEmpty;
    final name = tagged && examinee.displayName.trim().isNotEmpty ? examinee.displayName : 'No name saved';
    final id = tagged && examinee.examineeNumber.trim().isNotEmpty ? examinee.examineeNumber : '—';
    return _Card(
      key: const ValueKey('rescan-original-card'),
      title: 'Original scan',
      subtitle: 'Saved record — kept unless you confirm',
      children: [
        _SheetImage(label: 'Original sheet', image: data.originalSheet, missingText: 'Original photo unavailable'),
        const SizedBox(height: 10),
        _NameCrops(
          last: data.originalCropLast,
          first: data.originalCropFirst,
          middle: data.originalCropMiddle,
          missingText: 'Original name crops unavailable',
        ),
        const SizedBox(height: 10),
        _kv('Saved name', name, key: const ValueKey('rescan-saved-name')),
        _kv('Examinee ID', id, key: const ValueKey('rescan-saved-id')),
        _kv('Scan date', _fmtDate(data.originalCapturedAt)),
        _kv('Total score', _scoreText(data.comparison.originalScore), key: const ValueKey('rescan-score-original')),
      ],
    );
  }

  Widget _buildNewCard() {
    final cmp = data.comparison;
    return _Card(
      key: const ValueKey('rescan-new-card'),
      title: 'New scan',
      subtitle: 'Replacement photo — not saved',
      children: [
        _SheetImage(label: 'New sheet', image: data.candidateSheet, missingText: 'New photo unavailable'),
        const SizedBox(height: 10),
        _NameCrops(
          last: data.candidateCropLast,
          first: data.candidateCropFirst,
          middle: data.candidateCropMiddle,
          missingText: 'New name crops unavailable',
        ),
        const SizedBox(height: 10),
        Container(
          key: const ValueKey('rescan-ocr-suggestion'),
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('OCR suggestion — unverified',
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: _muted)),
              const SizedBox(height: 2),
              Text(
                data.hasOcrSuggestion
                    ? [data.ocrFirstName, data.ocrMiddleName, data.ocrLastName]
                        .where((s) => (s ?? '').isNotEmpty)
                        .join(' ')
                    : 'No suggestion available',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _ink),
              ),
              const SizedBox(height: 2),
              Text(
                key: const ValueKey('rescan-ocr-note'),
                data.ocrSuggestionWillBeSaved
                    ? 'A machine guess at the handwriting. This sheet has no confirmed name yet, so '
                        'when you confirm, it will be saved into the blank name fields only. '
                        'Check it afterwards with Edit student.'
                    : 'A machine guess at the handwriting. It is not the saved name and will not be '
                        'saved: this sheet already has a name, and typed names are never overwritten.',
                style: const TextStyle(fontSize: 10.5, color: _muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _kv('Proposed score', _scoreText(cmp.proposedScore), key: const ValueKey('rescan-score-proposed')),
      ],
    );
  }

  Widget _buildScores() {
    final cmp = data.comparison;
    final delta = cmp.scoreDelta;
    final deltaText = delta == null ? '' : ' (${delta > 0 ? '+' : ''}$delta)';
    return _Card(
      key: const ValueKey('rescan-scores'),
      title: 'Score',
      children: [
        Text(
          '${_scoreText(cmp.originalScore)}  →  ${_scoreText(cmp.proposedScore)}$deltaText',
          key: const ValueKey('rescan-score-summary'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink),
        ),
        const SizedBox(height: 4),
        if (cmp.originalScore?.isTat == true || cmp.proposedScore?.isTat == true) ...[
          Text('Original: ${_tatBreakdown(cmp.originalScore)}', style: const TextStyle(fontSize: 11, color: _muted)),
          Text('New: ${_tatBreakdown(cmp.proposedScore)}', style: const TextStyle(fontSize: 11, color: _muted)),
        ],
        const Text(
          'The new score is exactly what will be saved, using the same scoring rules as any scan.',
          style: TextStyle(fontSize: 10.5, color: _muted),
        ),
      ],
    );
  }

  Widget _buildCorrectionsNotice() {
    final n = data.comparison.correctionsThatWillStopApplying;
    return Container(
      key: const ValueKey('rescan-corrections-notice'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _amberBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFCD34D)),
      ),
      child: Text(
        'This sheet has $n manual correction${n == 1 ? '' : 's'} counted in the original score. '
        'They belong to the old photo: if you replace it they stay in the history but no longer change '
        'the answers, and the new score above does not include them. Re-review the sheet afterwards.',
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: _amber),
      ),
    );
  }

  Widget _buildChanges() {
    final cmp = data.comparison;
    return _Card(
      key: const ValueKey('rescan-changes'),
      title: 'Answers that changed',
      subtitle: cmp.changedCount == 0
          ? 'None of the ${cmp.comparedItems} answers differ'
          : '${cmp.changedCount} of ${cmp.comparedItems} answers differ — advisory only',
      children: [
        for (final c in cmp.changes) _ChangeRow(change: c),
      ],
    );
  }

  Widget _buildVerification() {
    final missing = data.missingForVerification;
    if (missing.isNotEmpty) {
      return Container(
        key: const ValueKey('rescan-unavailable'),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEE2E2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFCA5A5)),
        ),
        child: Text(
          'Visual identity verification is unavailable because ${missing.join(', ')} '
          '${missing.length == 1 ? 'is' : 'are'} missing. A replacement cannot be confirmed without being '
          'able to compare the sheets, so this rescan cannot be saved. Cancel, or retake the photo.',
          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: _red),
        ),
      );
    }
    // The surface is a Material (not a coloured DecoratedBox) so the tile's ink
    // and selection effects paint on it rather than being hidden behind it.
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: _border),
      ),
      child: CheckboxListTile(
        key: const ValueKey('rescan-confirm-check'),
        value: _verified,
        onChanged: (_saving || _locked) ? null : (v) => setState(() => _verified = v ?? false),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
        dense: true,
        title: const Text(
          RescanComparisonScreen.confirmationText,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink),
        ),
      ),
    );
  }

  Widget _buildActions() => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: _border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('rescan-error'),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _red),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  key: const ValueKey('rescan-cancel'),
                  onPressed: _saving ? null : () => _leave(RescanDecision.cancelled),
                  child: const Text('Cancel'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('rescan-retake'),
                  onPressed: _saving ? null : () => _leave(RescanDecision.retake),
                  icon: const Icon(Icons.camera_alt_outlined, size: 16),
                  label: const Text('Retake photo'),
                ),
                FilledButton.icon(
                  key: const ValueKey('rescan-confirm'),
                  onPressed: _canConfirm ? _confirm : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.check, size: 16),
                  label: Text(_saving ? 'Saving…' : 'Confirm replacement'),
                ),
              ],
            ),
          ],
        ),
      );

  // --- helpers -------------------------------------------------------------

  static String _scoreText(ExamScore? s) {
    if (s == null || !s.isGraded) return 'Not graded';
    return '${s.rawScore} / ${s.maxScore}';
  }

  static String _tatBreakdown(ExamScore? s) {
    if (s == null || !s.isTat || !s.isGraded) return '—';
    return 'Test I ${s.tatTest1Score} · Test II ${s.tatTest2Score} · Test III ${s.tatTest3Score}';
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  static String _fmtDate(DateTime d) {
    final l = d.toLocal();
    return '${_months[l.month - 1]} ${l.day}, ${l.year}';
  }

  Widget _kv(String k, String v, {Key? key}) => Padding(
        key: key,
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              child: Text(k, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _muted)),
            ),
            Expanded(child: Text(v, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: _ink))),
          ],
        ),
      );
}

class _Card extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const _Card({super.key, required this.title, this.subtitle, required this.children});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink)),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(subtitle!, style: const TextStyle(fontSize: 11, color: _muted)),
              ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );
}

/// A sheet photo that opens full screen (pinch/zoom) when tapped.
class _SheetImage extends StatelessWidget {
  final String label;
  final ImageProvider? image;
  final String missingText;
  const _SheetImage({required this.label, required this.image, required this.missingText});

  @override
  Widget build(BuildContext context) {
    final img = image;
    if (img == null) return _Missing(text: missingText, height: 120);
    return InkWell(
      key: ValueKey('rescan-sheet-${label.toLowerCase().replaceAll(' ', '-')}'),
      onTap: () => openFullScreenImage(context, title: label, image: img),
      child: Stack(
        children: [
          Container(
            height: 280,
            width: double.infinity,
            color: const Color(0xFFF3F4F6),
            child: Image(image: img, fit: BoxFit.contain),
          ),
          const Positioned(
            right: 6,
            bottom: 6,
            child: Icon(Icons.zoom_out_map, size: 18, color: _muted),
          ),
        ],
      ),
    );
  }
}

/// Enlarged last / first / middle name crops, each tappable for full screen.
class _NameCrops extends StatelessWidget {
  final ImageProvider? last;
  final ImageProvider? first;
  final ImageProvider? middle;
  final String missingText;
  const _NameCrops({required this.last, required this.first, required this.middle, required this.missingText});

  @override
  Widget build(BuildContext context) {
    if (last == null && first == null && middle == null) return _Missing(text: missingText, height: 56);
    Widget crop(String label, ImageProvider? img) {
      if (img == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: _muted)),
            const SizedBox(height: 2),
            InkWell(
              onTap: () => openFullScreenImage(context, title: label, image: img),
              child: Container(
                height: 64,
                width: double.infinity,
                decoration: BoxDecoration(color: Colors.white, border: Border.all(color: _border)),
                child: Image(image: img, fit: BoxFit.contain),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        crop('Last name (handwritten)', last),
        crop('First name (handwritten)', first),
        crop('Middle initial (handwritten)', middle),
      ],
    );
  }
}

class _Missing extends StatelessWidget {
  final String text;
  final double height;
  const _Missing({required this.text, required this.height});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _border),
        ),
        child: Text(text, style: const TextStyle(fontSize: 11.5, color: _muted)),
      );
}

class _ChangeRow extends StatelessWidget {
  final AnswerChange change;
  const _ChangeRow({required this.change});

  @override
  Widget build(BuildContext context) {
    final oRight = change.originalCorrect;
    final pRight = change.proposedCorrect;
    Color? tint;
    if (oRight == false && pRight == true) tint = _green;
    if (oRight == true && pRight == false) tint = _red;
    return Padding(
      key: ValueKey('rescan-change-${change.sectionName}|${change.itemNumber}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92,
            child: Text(
              '${change.sectionName} · Q${change.itemNumber}',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _ink),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: const TextStyle(fontSize: 12, color: _ink),
                children: [
                  TextSpan(text: change.original.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (change.originalWasCorrected) const TextSpan(text: ' (manual correction)', style: TextStyle(color: _amber, fontSize: 10.5)),
                  const TextSpan(text: '  →  '),
                  TextSpan(
                    text: change.proposed.label,
                    style: TextStyle(fontWeight: FontWeight.w700, color: tint),
                  ),
                  if (change.keyChoice != null)
                    TextSpan(text: '   key ${change.keyChoice}', style: const TextStyle(color: _muted, fontSize: 10.5)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen, pinch-zoomable view of one photo.
Future<void> openFullScreenImage(BuildContext context, {required String title, required ImageProvider image}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(title, style: const TextStyle(fontSize: 14)),
        ),
        body: SafeArea(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 8,
            child: Center(child: Image(image: image, fit: BoxFit.contain)),
          ),
        ),
      ),
    ),
  );
}
