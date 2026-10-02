import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import '../../../models/omr_scan_result.dart';
import '../../../shared/widgets/examinee_dialog.dart';
import '../../../shared/widgets/name_crop_strip.dart';
import '../../../shared/widgets/primary_button.dart';
import '../widgets/scan_editing_factory.dart';
import '../widgets/scan_result_summary.dart';
import 'omr_debug_viewer_screen.dart';
import 'scanned_image_viewer_screen.dart';

/// Exam Results — shows what the OMR decoder read off each scanned sheet in
/// this session (AppState.scannedResults), and persists the whole session
/// into its bound batch: every captured image is copied into the batch
/// container and each sheet is graded against the loaded Final answer key
/// (see [AppState.persistCapturedSessionToBatch]). The batch then becomes
/// the durable record, visible in the Archive.
///
/// Persistence runs once, from a post-frame callback, guarded inside
/// AppState against repeat calls — never as a side effect of build().
class ExamResultsScreen extends StatefulWidget {
  const ExamResultsScreen({super.key});

  @override
  State<ExamResultsScreen> createState() => _ExamResultsScreenState();
}

class _ExamResultsScreenState extends State<ExamResultsScreen> {
  bool _persistTriggered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_persistTriggered) return;
    _persistTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _persist());
  }

  Future<void> _persist() async {
    if (!mounted) return;
    final appState = AppStateScope.of(context);
    await appState.persistCapturedSessionToBatch();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text(
          'Scan Results — ${appState.activeExamCode}',
          style: AppTextStyles.heading(size: 13),
        ),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            final results = appState.scannedResults;
            return Column(
              children: [
                _buildPersistenceBanner(appState),
                Expanded(
                  child: results.isEmpty
                      ? _buildEmptyState()
                      : _buildResultsList(results, appState),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: PrimaryButton(
                    label: 'RETURN HOME',
                    color: AppColors.darkNavy,
                    onPressed: () =>
                        Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (r) => false),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPersistenceBanner(AppState appState) {
    if (appState.scanBatch == null) return const SizedBox.shrink();

    String message;
    Color background;
    Color foreground;
    IconData icon;

    if (appState.isSavingToBatch) {
      message = 'Saving scans and results to ${appState.scanBatchCode}…';
      background = AppColors.lightBg;
      foreground = AppColors.textGray;
      icon = Icons.cloud_upload_outlined;
    } else if (appState.batchSaveError != null) {
      message = appState.batchSaveError!;
      background = const Color(0xFFFEE2E2);
      foreground = const Color(0xFF991B1B);
      icon = Icons.warning_amber_rounded;
    } else if (appState.sessionPersistedToBatch) {
      final g = appState.savedGradedCount;
      final n = appState.savedScanCount;
      message = g == n
          ? 'Saved $n scan${n == 1 ? '' : 's'} to ${appState.scanBatchCode} — all graded.'
          : 'Saved $n scan${n == 1 ? '' : 's'} to ${appState.scanBatchCode} ($g graded).';
      background = AppColors.emerald100;
      foreground = const Color(0xFF065F46);
      icon = Icons.check_circle_outline;
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: foreground),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaIcon(FontAwesomeIcons.fileCircleQuestion, color: AppColors.textGray, size: 28),
            const SizedBox(height: 12),
            Text('No decoded sheets to show.', style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsList(List<OmrScanResult> results, AppState appState) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: results.length,
      itemBuilder: (context, sheetIndex) {
        final imagePath = sheetIndex < appState.capturedPages.length
            ? appState.capturedPages[sheetIndex].path
            : null;
        // Available only once the session is persisted — that's when the
        // batch holds the LocalScan this card can be tagged against.
        // sheetIndex is relative to *this session's* sheets; scanning onto
        // a batch that already has scans from an earlier session means
        // those land first in batch.scans, so sessionScanOffset must be
        // added before indexing (see its doc comment) — otherwise this
        // picks up an earlier session's already-tagged scan instead.
        final batch = appState.scanBatch;
        final scanIndex = appState.sessionScanOffset + sheetIndex;
        final scan = (appState.sessionPersistedToBatch &&
                batch != null &&
                scanIndex < batch.scans.length)
            ? batch.scans[scanIndex]
            : null;
        // What the sheet reads as NOW: the detected answers with any manual
        // corrections applied, once the scan is saved.
        final result = results[sheetIndex];
        final scored = scoreOmrResult(scan?.effectiveDecoded ?? result, appState.answerKeys[result.examCode]);
        return _buildSheetCard(context, appState, sheetIndex, scored, imagePath, scan);
      },
    );
  }

  Future<void> _tagExaminee(
    BuildContext context,
    AppState appState,
    int sheetIndex,
    ExamineeInfo? current, {
    LocalScan? scan,
  }) async {
    final batch = appState.scanBatch;
    final scanIndex = appState.sessionScanOffset + sheetIndex;
    if (batch == null || scanIndex >= batch.scans.length) return;
    final thisId = batch.scans[scanIndex].id;
    final others = <String>{
      for (final s in batch.scans)
        if (s.id != thisId) (s.examinee?.examineeNumber.trim() ?? ''),
    }..removeWhere((e) => e.isEmpty);

    final res = await showExamineeDialog(
      context,
      initial: current,
      sheetLabel: 'Sheet ${sheetIndex + 1}',
      otherNumbers: others,
      batchId: batch.id,
      scan: scan,
      repository: appState.batchRepository,
      onReviewAnswers: scan == null ? null : () => _openViewer(context, appState, sheetIndex, scan),
    );
    if (res == null) return;
    await appState.tagSessionScanExaminee(sheetIndex, res.cleared ? null : res.info);
  }

  /// Opens View Scan for a sheet. When the sheet has been saved to the batch
  /// ([scan] non-null) answers can be corrected from there.
  Future<void> _openViewer(
    BuildContext context,
    AppState appState,
    int sheetIndex,
    LocalScan? scan,
  ) {
    final results = appState.scannedResults;
    final result = results[sheetIndex];
    final imagePath = sheetIndex < appState.capturedPages.length ? appState.capturedPages[sheetIndex].path : null;
    // The latest saved copy, so corrections made earlier are already in it.
    final batch = appState.scanBatch;
    final scanIndex = appState.sessionScanOffset + sheetIndex;
    final fresh = (batch != null && scan != null && scanIndex < batch.scans.length) ? batch.scans[scanIndex] : scan;
    final scored = scoreOmrResult(fresh?.effectiveDecoded ?? result, appState.answerKeys[result.examCode]);
    final examinee = fresh?.examinee;
    final tagged = examinee != null && !examinee.isEmpty;
    final title = tagged ? 'Sheet ${sheetIndex + 1} — ${examinee.displayName}' : 'Sheet ${sheetIndex + 1}';
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScannedImageViewerScreen(
          imagePath: imagePath,
          title: title,
          scoredItems: scored.items,
          rectifiedImagePath:
              sheetIndex < appState.rectifiedImagePaths.length ? appState.rectifiedImagePaths[sheetIndex] : null,
          template: omrTemplates[scored.examCode],
          scanTemplateVersion: scored.templateVersion,
          meshInteriorMeasuredFrac: scored.meshInteriorMeasuredFrac,
          geometryWarning: scored.geometryWarning,
          editing: (fresh != null && batch != null) ? scanEditingFor(appState, batch.id, fresh) : null,
        ),
      ),
    );
  }

  Widget _buildSheetCard(
    BuildContext context,
    AppState appState,
    int sheetIndex,
    ScoredResult scored,
    String? imagePath,
    LocalScan? scan,
  ) {
    final blankCount = scored.items.where((i) => i.isBlank).length;
    final ambiguousCount = scored.items.where((i) => i.isAmbiguous).length;
    final examinee = scan?.examinee;
    final tagged = examinee != null && !examinee.isEmpty;
    final cardTitle = tagged ? examinee.displayName : 'Unnamed examinee';

    final bySection = <String, List<ScoredItem>>{};
    for (final item in scored.items) {
      bySection.putIfAbsent(item.sectionName, () => []).add(item);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const FaIcon(FontAwesomeIcons.fileLines, color: AppColors.primaryGreen, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cardTitle,
                  style: AppTextStyles.heading(size: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            tagged
                ? 'Sheet ${sheetIndex + 1} · Examinee ${examinee.examineeNumber}'
                : 'Sheet ${sheetIndex + 1} · ${scored.items.length} items · $blankCount blank · $ambiguousCount flagged',
            style: AppTextStyles.body(size: 9, color: AppColors.textGray),
          ),
          if (scan != null) ...[
            const SizedBox(height: 8),
            NameCropStrip(
              batchId: appState.scanBatch!.id,
              scan: scan,
              repository: appState.batchRepository,
            ),
          ],
          const SizedBox(height: 8),
          ScanResultSummary(
            examCode: appState.scanBatch?.examCode ?? appState.activeExamCode,
            result: scan?.result,
            live: scored,
          ),
          const SizedBox(height: 8),
          _buildExamineeRow(context, appState, sheetIndex, scan, tagged, examinee),
          if (imagePath != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _openViewer(context, appState, sheetIndex, scan),
                icon: const FaIcon(FontAwesomeIcons.image, size: 12, color: AppColors.primaryGreen),
                label: const Text('View Scan', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryGreen,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
          if (appState.lastDebugImagesDir != null) ...[
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => OmrDebugViewerScreen(
                      debugDir: appState.lastDebugImagesDir!,
                      // The decoder numbers pages from 1; this list is 0-based.
                      pageIndex: sheetIndex + 1,
                      title: 'How it was read — Sheet ${sheetIndex + 1}',
                      meshVerdict: scored.meshVerdict,
                    ),
                  ),
                ),
                icon: const FaIcon(FontAwesomeIcons.layerGroup,
                    size: 12, color: Color(0xFF94A3B8)),
                label: const Text('How it was read',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF94A3B8),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          ...bySection.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.key, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: entry.value.map(_buildItemChip).toList(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Per-sheet student tagging. Disabled until the session has been
  /// persisted (there's no LocalScan to attach to before then).
  Widget _buildExamineeRow(
    BuildContext context,
    AppState appState,
    int sheetIndex,
    LocalScan? scan,
    bool tagged,
    ExamineeInfo? examinee,
  ) {
    if (scan == null) {
      return Row(
        children: [
          const FaIcon(FontAwesomeIcons.userClock, size: 11, color: AppColors.textGray),
          const SizedBox(width: 6),
          Text('Saving to batch…', style: AppTextStyles.body(size: 9.5, color: AppColors.textGray)),
        ],
      );
    }

    if (tagged) {
      // Every saved scan receives a generated Examinee ID (see
      // AppState.persistCapturedSessionToBatch), so an incomplete tag here
      // normally means the NAME is missing (or only partly filled in), not
      // the number. The number can still be absent if staff explicitly
      // cleared it, so the label names whichever piece is actually missing
      // rather than always assuming one of them.
      final complete = examinee!.isComplete;
      final hasName = examinee.firstName.trim().isNotEmpty || examinee.lastName.trim().isNotEmpty;
      final hasNumber = examinee.examineeNumber.trim().isNotEmpty;
      final displayName = hasName ? examinee.displayName : 'Unnamed examinee';
      final icon = complete ? FontAwesomeIcons.userCheck : FontAwesomeIcons.userPen;
      final color = complete ? AppColors.primaryGreen : AppColors.amber800;
      final label = complete
          ? '$displayName · #${examinee.examineeNumber}'
          : hasNumber
              ? '$displayName · #${examinee.examineeNumber} — needs name'
              : '$displayName — needs examinee #';
      return Row(
        children: [
          FaIcon(icon, size: 11, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.body(size: 9.5, weight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => _tagExaminee(context, appState, sheetIndex, examinee, scan: scan),
            style: TextButton.styleFrom(
              foregroundColor: color,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Edit', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
          ),
        ],
      );
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton.icon(
        onPressed: () => _tagExaminee(context, appState, sheetIndex, null, scan: scan),
        icon: const FaIcon(FontAwesomeIcons.userPlus, size: 11, color: AppColors.darkNavy),
        label: const Text('Tag student'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.darkNavy,
          side: const BorderSide(color: Color(0xFFCBD5E1)),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _buildItemChip(ScoredItem item) {
    final Color background;
    final Color foreground;
    final String label;
    if (item.isAmbiguous) {
      background = const Color(0xFFFEF3C7);
      foreground = const Color(0xFF92400E);
      label = '${item.itemNumber}: ⚠';
    } else if (item.isBlank) {
      background = const Color(0xFFF1F5F9);
      foreground = AppColors.textGray;
      label = '${item.itemNumber}: —';
    } else if (item.isCorrect == false) {
      background = const Color(0xFFFEE2E2);
      foreground = const Color(0xFF991B1B);
      label = '${item.itemNumber}: ${item.markedChoice}';
    } else {
      background = AppColors.emerald100;
      foreground = const Color(0xFF065F46);
      label = '${item.itemNumber}: ${item.markedChoice}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: foreground)),
    );
  }
}
