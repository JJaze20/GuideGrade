import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../models/answer_correction.dart';
import '../../../models/answer_key.dart';
import '../../../models/local_batch.dart';
import '../../../models/omr_scan_result.dart';

/// Everything the editor needs to know about one item.
class AnswerEditTarget {
  /// The section's name (TAT: e.g. "Test II") and item number — together the
  /// item's identity, since numbers repeat across TAT's sections.
  final String sectionName;
  final int itemNumber;

  /// What the decoder read — never editable, always shown.
  final OmrItemResult detected;

  /// What the item reads as now (the detected value, or the active
  /// correction's value).
  final CorrectedAnswer current;

  /// The answer key's correct choice, or null when the exam has no key.
  final String? keyChoice;

  /// The item's real choice labels from the sheet template (A–E, T/F, …).
  final List<String> choices;

  /// The correction currently in force on this capture, if any.
  final AnswerCorrection? active;

  /// A correction made on an EARLIER capture (before a rescan) that has not
  /// been reviewed on this one.
  final AnswerCorrection? fromEarlierCapture;

  const AnswerEditTarget({
    required this.sectionName,
    required this.itemNumber,
    required this.detected,
    required this.current,
    required this.keyChoice,
    required this.choices,
    this.active,
    this.fromEarlierCapture,
  });
}

/// The fractional page region an item occupies (its number gutter, badge and
/// every bubble), padded a little — used to show the counselor the part of
/// the sheet they are correcting.
Rect itemRegionFraction(OmrExamTemplate template, List<BubblePos> bubbles) {
  var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
  for (final b in bubbles) {
    if (b.xFrac < minX) minX = b.xFrac;
    if (b.xFrac > maxX) maxX = b.xFrac;
    if (b.yFrac < minY) minY = b.yFrac;
    if (b.yFrac > maxY) maxY = b.yFrac;
  }
  // Left gutter holds the printed number and the ✓/✕ badge.
  final padLeft = 34 / template.pageWidthPt;
  final padRight = (template.bubbleRadiusPt + 10) / template.pageWidthPt;
  final padY = (template.bubbleRadiusYPt + 8) / template.pageHeightPt;
  return Rect.fromLTRB(
    (minX - padLeft).clamp(0.0, 1.0),
    (minY - padY).clamp(0.0, 1.0),
    (maxX + padRight).clamp(0.0, 1.0),
    (maxY + padY).clamp(0.0, 1.0),
  );
}

/// A crop of the rectified sheet image showing just [region] (fractions of
/// the page). The rectified image is exactly page-proportioned, so a
/// fractional window into it is a faithful view of that part of the sheet.
class SheetRegionPreview extends StatelessWidget {
  final Uint8List? imageBytes;
  final String? imagePath;
  final Rect region;
  final double pageAspect; // pageWidthPt / pageHeightPt

  const SheetRegionPreview({
    super.key,
    this.imageBytes,
    this.imagePath,
    required this.region,
    required this.pageAspect,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final regionW = region.width <= 0 ? 1.0 : region.width;
        final regionH = region.height <= 0 ? 1.0 : region.height;
        final fullW = w / regionW;
        final fullH = fullW / pageAspect;
        // Window height that keeps the region's real proportions.
        final h = (regionH * fullH).clamp(24.0, 120.0);
        final image = imageBytes != null
            ? Image.memory(imageBytes!, fit: BoxFit.fill, gaplessPlayback: true)
            : Image.file(File(imagePath!), fit: BoxFit.fill, gaplessPlayback: true);
        return Semantics(
          label: 'The part of the scanned sheet for this question',
          image: true,
          child: Container(
            height: h,
            width: w,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFF64748B)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: fullW,
                maxWidth: fullW,
                minHeight: fullH,
                maxHeight: fullH,
                child: Transform.translate(
                  offset: Offset(-region.left * fullW, -region.top * fullH),
                  child: SizedBox(width: fullW, height: fullH, child: image),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Bottom sheet for correcting ONE item.
///
/// It edits what the student actually marked (a choice, nothing, or more than
/// one). It does not grade: correct/wrong still comes from the answer key and
/// the exam's scoring rules, so there is no way here to mark an answer right
/// or wrong by hand, to accept the key's yellow answer without choosing it as
/// the student's mark, or to change the key.
///
/// [onSave] and [onReset] are called at most once at a time. The sheet keeps
/// one request id for its whole life, so a double tap, or a retry after a
/// failure, sends the same id and cannot apply the correction twice.
Future<void> showAnswerCorrectionSheet(
  BuildContext context, {
  required AnswerEditTarget target,
  Widget? regionPreview,
  required Future<void> Function(CorrectedAnswer value, String? reason, String requestId) onSave,
  required Future<void> Function(String requestId) onReset,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (ctx) => _AnswerCorrectionSheet(
      target: target,
      regionPreview: regionPreview,
      onSave: onSave,
      onReset: onReset,
    ),
  );
}

class _AnswerCorrectionSheet extends StatefulWidget {
  final AnswerEditTarget target;
  final Widget? regionPreview;
  final Future<void> Function(CorrectedAnswer value, String? reason, String requestId) onSave;
  final Future<void> Function(String requestId) onReset;

  const _AnswerCorrectionSheet({
    required this.target,
    required this.regionPreview,
    required this.onSave,
    required this.onReset,
  });

  @override
  State<_AnswerCorrectionSheet> createState() => _AnswerCorrectionSheetState();
}

class _AnswerCorrectionSheetState extends State<_AnswerCorrectionSheet> {
  static const _border = Color(0xFF64748B);

  late CorrectedAnswer _selected = widget.target.current;
  final _reasonCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  /// One id for this sheet's lifetime — see the class comment on idempotency.
  late final String _requestId =
      'c_${DateTime.now().microsecondsSinceEpoch}_${widget.target.sectionName}_${widget.target.itemNumber}';

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  bool get _changed => _selected != widget.target.current;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return; // ignore repeated taps while a save is in flight
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is StateError ? e.message : 'Couldn’t save the correction. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.target;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFCBD5E1),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${t.sectionName} · Question ${t.itemNumber}',
              key: const Key('answerCorrection.title'),
              style: AppTextStyles.heading(size: 15),
            ),
            const SizedBox(height: 10),
            if (widget.regionPreview != null) ...[
              widget.regionPreview!,
              const SizedBox(height: 10),
            ],
            _infoRow('Detected by the scanner', t.detected.isAmbiguous
                ? 'Multiple marks'
                : (t.detected.markedChoice ?? 'Blank')),
            if (t.active != null)
              _infoRow('Currently corrected to', t.active!.corrected.label),
            if (t.keyChoice != null) _keyNote(t.keyChoice!),
            if (t.fromEarlierCapture != null) _earlierCaptureNote(t.fromEarlierCapture!),
            const SizedBox(height: 12),
            Text(
              'What did the student actually mark?',
              style: AppTextStyles.body(size: 12, weight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'This fixes a misread. It does not mark the answer right or wrong — '
              'the answer key and the exam’s scoring rules decide that.',
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in t.choices)
                  _choiceChip(
                    label: c,
                    value: CorrectedAnswer.choice(c),
                    semantics: 'Choice $c',
                  ),
                _choiceChip(
                  label: 'Blank',
                  value: const CorrectedAnswer.blank(),
                  semantics: 'No mark',
                ),
                _choiceChip(
                  label: 'Multiple marks',
                  value: const CorrectedAnswer.multiple(),
                  semantics: 'More than one mark',
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('answerCorrection.reason'),
              controller: _reasonCtrl,
              enabled: !_busy,
              maxLength: 140,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. mark was faint',
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border, width: 1.2),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _border, width: 1.2),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.primaryGreen, width: 2),
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  key: const Key('answerCorrection.error'),
                  style: const TextStyle(color: Color(0xFFB91C1C), fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
            // Reset gets its own line: with all three buttons in one Row their
            // natural widths exceed a phone-width sheet (and the 640dp cap on
            // wide screens under larger fonts), overflowing the Row. Cancel and
            // Save stay together on the right, where they always fit.
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (t.active != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('answerCorrection.reset'),
                      onPressed: _busy ? null : () => _run(() => widget.onReset(_requestId)),
                      child: const Text('Reset to detected answer'),
                    ),
                  ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _busy ? null : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      key: const Key('answerCorrection.save'),
                      onPressed: (_busy || !_changed)
                          ? null
                          : () => _run(() => widget.onSave(_selected, _reasonCtrl.text, _requestId)),
                      style: FilledButton.styleFrom(backgroundColor: AppColors.primaryGreen),
                      child: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Save correction'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Text('$label: ', style: AppTextStyles.body(size: 11.5, color: AppColors.textGray)),
            Text(value, style: AppTextStyles.body(size: 12, weight: FontWeight.w800)),
          ],
        ),
      );

  /// Spells out what the yellow ring means, so the key's answer is never
  /// mistaken for the student's mark or accepted by tapping it.
  Widget _keyNote(String keyChoice) => Container(
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF9C3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFCA8A04)),
        ),
        child: Text.rich(
          TextSpan(
            style: AppTextStyles.body(size: 11, color: const Color(0xFF713F12)),
            children: [
              const TextSpan(text: 'Answer key: ', style: TextStyle(fontWeight: FontWeight.w800)),
              TextSpan(text: keyChoice, style: const TextStyle(fontWeight: FontWeight.w900)),
              const TextSpan(
                text: '. The yellow ring on the sheet marks the key’s answer — it is NOT what the '
                    'student marked. Choosing it below records that the student marked it.',
              ),
            ],
          ),
        ),
      );

  Widget _earlierCaptureNote(AnswerCorrection old) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF3B82F6)),
        ),
        child: Text(
          'This sheet was rescanned. Before the rescan this item was corrected to '
          '“${old.corrected.label}”. That correction is kept in the history but is not '
          'applied to the new scan — check the sheet above and choose the answer again if it still applies.',
          key: const Key('answerCorrection.earlierCapture'),
          style: AppTextStyles.body(size: 10.5, color: const Color(0xFF1E3A8A)),
        ),
      );

  Widget _choiceChip({
    required String label,
    required CorrectedAnswer value,
    required String semantics,
  }) {
    final selected = _selected == value;
    return Semantics(
      button: true,
      selected: selected,
      label: semantics,
      child: ChoiceChip(
        key: Key('answerCorrection.choice.$label'),
        label: Text(label),
        selected: selected,
        showCheckmark: true,
        onSelected: _busy ? null : (_) => setState(() => _selected = value),
        selectedColor: AppColors.emerald100,
        backgroundColor: Colors.white,
        side: BorderSide(color: selected ? AppColors.primaryGreen : _border, width: selected ? 2 : 1.2),
        labelStyle: TextStyle(
          fontWeight: FontWeight.w800,
          color: selected ? AppColors.primaryGreen : AppColors.textDark,
        ),
      ),
    );
  }
}

/// What a screen needs to make answers on one saved scan correctable: the
/// scan as it stands, the exam's answer key, and the two actions (each
/// returns the scan after the change). Screens without one show their scan
/// read-only.
class ScanEditing {
  final LocalScan scan;
  final AnswerKey? answerKey;
  final Future<LocalScan> Function(
    String sectionName,
    int itemNumber,
    CorrectedAnswer value,
    String? reason,
    String requestId,
  ) onCorrect;
  final Future<LocalScan> Function(String sectionName, int itemNumber, String requestId) onReset;

  const ScanEditing({
    required this.scan,
    required this.answerKey,
    required this.onCorrect,
    required this.onReset,
  });
}

/// Opens the editor for one item of [scan] and returns the scan after the
/// change, or null when nothing was saved. [template] supplies the item's real
/// choice labels and where it sits on the sheet.
Future<LocalScan?> editScanItem(
  BuildContext context, {
  required ScanEditing editing,
  required LocalScan scan,
  required OmrExamTemplate template,
  required String sectionName,
  required int itemNumber,
  Uint8List? rectifiedBytes,
  String? rectifiedPath,
}) async {
  OmrItemResult? detected;
  for (final i in scan.decoded.items) {
    if (i.sectionName == sectionName && i.itemNumber == itemNumber) detected = i;
  }
  if (detected == null) return null;

  List<BubblePos> bubbles = const [];
  for (final s in template.sections) {
    if (s.name == sectionName) bubbles = s.items[itemNumber] ?? const [];
  }
  final choices = [for (final b in bubbles) b.choice];

  final key = AnswerCorrection.keyFor(sectionName, itemNumber);
  final active = CorrectionRules.activeFor(scan.corrections, scan.captureRevision)[key];
  AnswerCorrection? earlier;
  for (final e in CorrectionRules.needingReview(scan.corrections, scan.captureRevision)) {
    if (e.itemKey == key) earlier = e;
  }

  final target = AnswerEditTarget(
    sectionName: sectionName,
    itemNumber: itemNumber,
    detected: detected,
    current: CorrectionRules.currentValue(detected, scan.corrections, scan.captureRevision),
    keyChoice: editing.answerKey?.choiceFor(sectionName, itemNumber),
    choices: choices,
    active: active,
    fromEarlierCapture: earlier,
  );

  Widget? preview;
  if (bubbles.isNotEmpty && (rectifiedBytes != null || rectifiedPath != null) && template.pageHeightPt > 0) {
    preview = SheetRegionPreview(
      imageBytes: rectifiedBytes,
      imagePath: rectifiedPath,
      region: itemRegionFraction(template, bubbles),
      pageAspect: template.pageWidthPt / template.pageHeightPt,
    );
  }

  LocalScan? result;
  await showAnswerCorrectionSheet(
    context,
    target: target,
    regionPreview: preview,
    onSave: (value, reason, requestId) async {
      result = await editing.onCorrect(sectionName, itemNumber, value, reason, requestId);
    },
    onReset: (requestId) async {
      result = await editing.onReset(sectionName, itemNumber, requestId);
    },
  );
  return result;
}
