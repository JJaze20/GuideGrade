import 'package:flutter/material.dart';

import '../../../core/omr/scan_quality_gate.dart';

/// What the operator decided about a scan that did not clear every check.
enum ScanQualityChoice {
  /// Keep it as the decoder read it. The flagged items stay flagged.
  scanAnyway,

  /// Throw this session away and capture the sheets again. Also what
  /// dismissing the dialog means -- the safer of the three, since an
  /// accidental tap outside should never silently accept a flagged sheet.
  scanAgain,

  /// Keep it, then send the items the decoder could not resolve to the vision
  /// model for adjudication (see `OmrVisionAdjudicator`). Only ever offered
  /// when a model is actually configured for this build.
  forceScan,
}

/// Asks what to do with a scan that did not clear every quality check.
///
/// [forceScanAvailable] is false when no vision model is configured, which
/// hides "Force Scan" rather than offering a button that can only fail.
///
/// Advisory, not a block. See [ScanQualityGate] for why: the checks establish
/// that nothing detectable went wrong, which is a necessary condition for a
/// good read and not a sufficient one. There are real sheets that fail a
/// check and are read perfectly -- an examinee who genuinely left half the
/// paper blank trips the blank-rate check -- so the person holding the sheet
/// has to be the one to decide.
Future<ScanQualityChoice> showScanQualityDialog(
  BuildContext context,
  List<SheetQualityReport> failed, {
  bool forceScanAvailable = false,
}) async {
  final chosen = await showGeneralDialog<ScanQualityChoice>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Scan quality',
    barrierColor: Colors.black.withOpacity(0.55),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (context, animation, _, __) {
      // Pop in, and back out the same way on dismissal. easeOutBack overshoots
      // slightly on the way in so the dialog reads as arriving rather than
      // fading up; the reverse curve is plain easeIn, because an overshoot on
      // the way out looks like a bounce nobody asked for.
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1.0).animate(curved),
          child: _ScanQualityDialog(
            failed: failed,
            forceScanAvailable: forceScanAvailable,
          ),
        ),
      );
    },
  );
  return chosen ?? ScanQualityChoice.scanAgain;
}

class _ScanQualityDialog extends StatelessWidget {
  final List<SheetQualityReport> failed;
  final bool forceScanAvailable;

  const _ScanQualityDialog({
    required this.failed,
    required this.forceScanAvailable,
  });

  @override
  Widget build(BuildContext context) {
    final multiple = failed.length > 1;

    return Dialog(
      backgroundColor: const Color(0xFF0F172A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
              child: Row(
                children: [
                  const Icon(Icons.fact_check_outlined,
                      color: Color(0xFFFBBF24), size: 20),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      multiple
                          ? '${failed.length} sheets need a second look'
                          : 'Sheet ${failed.first.sheetNumber} needs a second look',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: Text(
                'These conditions have to hold for a read to be trusted. '
                'Rescanning usually costs less than correcting afterwards.',
                style: TextStyle(
                  color: Color(0xFF94A3B8),
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final report in failed) ...[
                      if (multiple)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 4),
                          child: Text(
                            'Sheet ${report.sheetNumber}',
                            style: const TextStyle(
                              color: Color(0xFFE2E8F0),
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      // Passing rows are shown too, not just failures: a
                      // checklist that only ever lists problems reads as an
                      // error, when the useful information is which specific
                      // condition broke out of the set.
                      for (final check in report.checks)
                        _CheckRow(check: check),
                      const SizedBox(height: 6),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Color(0xFF1E293B)),
            if (forceScanAvailable)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 10, 18, 0),
                child: Text(
                  'Force Scan keeps this sheet and lets the vision model settle '
                  'the answers that could not be read. It takes a moment and '
                  'may change nothing.',
                  style: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              // Wrap, not Row: three actions on a 420px dialog overflow at
              // large text scales, and a wrapped button is readable where a
              // clipped one is not.
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: [
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(ScanQualityChoice.scanAnyway),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF94A3B8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                    ),
                    child: const Text(
                      'Scan Anyway',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (forceScanAvailable)
                    OutlinedButton(
                      onPressed: () => Navigator.of(context)
                          .pop(ScanQualityChoice.forceScan),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFBBF24),
                        side: const BorderSide(color: Color(0xFFFBBF24)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 11),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text(
                        'Force Scan',
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ElevatedButton(
                    onPressed: () =>
                        Navigator.of(context).pop(ScanQualityChoice.scanAgain),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF16A34A),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 11),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text(
                      'Scan Again',
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  final ScanQualityCheck check;

  const _CheckRow({required this.check});

  @override
  Widget build(BuildContext context) {
    final colour =
        check.passed ? const Color(0xFF34D399) : const Color(0xFFF87171);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            check.passed ? Icons.check_circle : Icons.cancel,
            size: 16,
            color: colour,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  check.label,
                  style: TextStyle(
                    color: check.passed
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFFF1F5F9),
                    fontSize: 12.5,
                    fontWeight:
                        check.passed ? FontWeight.w500 : FontWeight.w700,
                  ),
                ),
                if (!check.passed && check.detail.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    check.detail,
                    style: const TextStyle(
                      color: Color(0xFF94A3B8),
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
