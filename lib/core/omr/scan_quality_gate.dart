import '../../models/omr_scan_result.dart';

/// One condition a scan has to satisfy before it is accepted without comment.
class ScanQualityCheck {
  /// Short name, shown as the checklist row.
  final String label;

  final bool passed;

  /// What went wrong and what to do about it. Empty when [passed].
  final String detail;

  const ScanQualityCheck({
    required this.label,
    required this.passed,
    this.detail = '',
  });
}

/// Every check for one sheet, and whether it cleared them all.
class SheetQualityReport {
  /// 1-based, matching how sheets are numbered in the results screen.
  final int sheetNumber;
  final List<ScanQualityCheck> checks;

  const SheetQualityReport({required this.sheetNumber, required this.checks});

  bool get passed => checks.every((c) => c.passed);

  List<ScanQualityCheck> get failures =>
      checks.where((c) => !c.passed).toList(growable: false);
}

/// Pre-acceptance quality gate for a scanning session.
///
/// WHAT THIS IS NOT: a measurement of accuracy. The app has no answer key for
/// what is physically on the paper at scan time -- that is the entire problem
/// it is trying to solve -- so it cannot report how accurate a read was, and
/// anything claiming to would be inventing a number. Staff would reasonably
/// trust such a claim, and in a graded admission test a false confidence
/// statement is worse than none.
///
/// What it does instead is check the conditions that have to hold for a read
/// to be trustworthy, each one a signal the decoder genuinely produced:
///
///  * the sheet's geometry was correctable (see [OmrScanResult.meshVerdict]),
///  * no item came out too close to call,
///  * the sheet does not look substantially unread.
///
/// Those are necessary conditions, not sufficient ones: passing means nothing
/// detectable went wrong, not that every mark is right. The wording through-
/// out says so, deliberately.
///
/// Advisory by design. A hard block would be worse than the problem: this
/// codebase already learned that lesson once, when strict pre-capture gating
/// made genuinely valid photos impossible to even attempt (see
/// `AlignmentCheck.degraded`, which counts as aligned on purpose). So a
/// failing sheet is reported, with the reason, and the person decides.
class ScanQualityGate {
  /// Below this fraction of items read as blank, a sheet is assumed to be
  /// genuinely partly unanswered rather than badly read.
  ///
  /// Generous on purpose: examinees really do leave questions blank, and
  /// there is no way to tell a skipped item from a missed one. It is here to
  /// catch the case where a whole region was lost -- a shadow across the
  /// lower half, a column outside the crop -- which shows up as a blank rate
  /// no real paper produces.
  static const double blankRateLimit = 0.60;

  /// Checks one decoded sheet.
  static SheetQualityReport inspect(OmrScanResult result, int sheetNumber) {
    final total = result.items.length;
    final ambiguous = result.items.where((i) => i.isAmbiguous).length;
    final blank = result.items.where((i) => i.isBlank).length;

    final geometryIssue = result.geometryWarning;

    return SheetQualityReport(
      sheetNumber: sheetNumber,
      checks: [
        ScanQualityCheck(
          label: 'Sheet geometry',
          passed: geometryIssue == null,
          detail: geometryIssue ?? '',
        ),
        ScanQualityCheck(
          label: 'Every answer read clearly',
          passed: ambiguous == 0,
          detail: ambiguous == 0
              ? ''
              : '$ambiguous ${ambiguous == 1 ? 'item was' : 'items were'} too '
                  'close to call between two bubbles. Usually a half-erased '
                  'mark, a stray pencil line, or two bubbles filled.',
        ),
        ScanQualityCheck(
          label: 'Whole sheet was read',
          passed: total == 0 || blank / total <= blankRateLimit,
          detail: total == 0 || blank / total <= blankRateLimit
              ? ''
              : '$blank of $total items read as unanswered. If the examinee '
                  'did answer them, part of the sheet was lost -- usually a '
                  'shadow across it or an edge outside the frame.',
        ),
      ],
    );
  }

  /// Checks a whole session, returning only the sheets that failed.
  ///
  /// Sheets are numbered from 1 to match the results screen.
  static List<SheetQualityReport> inspectSession(
    List<OmrScanResult> results,
  ) {
    final failed = <SheetQualityReport>[];
    for (var i = 0; i < results.length; i++) {
      final report = inspect(results[i], i + 1);
      if (!report.passed) failed.add(report);
    }
    return failed;
  }
}
