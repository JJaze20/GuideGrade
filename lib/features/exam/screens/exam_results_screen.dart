import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/omr_scan_result.dart';
import '../../../models/result.dart';
import '../../../shared/widgets/primary_button.dart';

/// Exam Results — mirrors SCREENS.AT_RESULTS.
///
/// Shows what the OMR decoder read off each scanned sheet in this session
/// (AppState.scannedResults), and — when this session has a real
/// exam+batch+examinee identity (see AppState.setScanSession, populated by
/// Exam Setup) and a usable Final answer key was loaded — persists one
/// ResultModel for the selected examinee to Firestore, which becomes the
/// durable record (survives navigating away and coming back, unlike
/// AppState.scannedResults, which is only ever in-memory for this run).
///
/// Persistence happens once, from an explicit post-frame method
/// ([_persistResults]) guarded against repeat calls — never as a side
/// effect inside build().
class ExamResultsScreen extends StatefulWidget {
  const ExamResultsScreen({super.key});

  @override
  State<ExamResultsScreen> createState() => _ExamResultsScreenState();
}

class _ExamResultsScreenState extends State<ExamResultsScreen> {
  final FirestoreService _firestoreService = FirestoreService();

  bool _persistAttempted = false;
  bool _isPersisting = false;
  String? _persistError;
  ResultModel? _persistedResult;
  ResultPersistOutcome? _persistOutcome;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_persistAttempted) {
      _persistAttempted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _persistResults());
    }
  }

  /// One-time, explicit persistence step. Never called from build() --
  /// triggered once via the post-frame callback in [didChangeDependencies],
  /// and guarded by [_isPersisting] against overlapping/duplicate calls.
  Future<void> _persistResults() async {
    if (_isPersisting) return;
    if (!mounted) return;
    final appState = AppStateScope.of(context);

    // No real exam/batch/examinee identity for this session (e.g. a
    // manual/local-only run) -- nothing durable to save. The in-memory
    // scannedResults still render below as before.
    if (!appState.hasRealScanSession) return;

    final examId = appState.scanExamId!;
    final batchId = appState.scanBatchId!;
    final examineeId = appState.scanExamineeId!;

    // Already persisted earlier in this same app run (e.g. the user left
    // this screen and came back) -- just re-display it, don't re-score or
    // re-increment actualCount.
    if (appState.scannedResults.isEmpty) {
      final existing = await _firestoreService.getResultById(
        ResultModel.buildId(examId: examId, batchId: batchId, examineeId: examineeId),
      );
      if (!mounted) return;
      if (existing != null) setState(() => _persistedResult = existing);
      return;
    }

    final answerKey = appState.answerKeys[appState.activeExamCode];
    if (answerKey == null) {
      setState(() => _persistError = 'No Final answer key was loaded for this session — results were not saved.');
      return;
    }

    setState(() => _isPersisting = true);
    try {
      var rawScore = 0;
      var totalGraded = 0;
      for (final r in appState.scannedResults) {
        final scored = scoreOmrResult(r, answerKey);
        rawScore += scored.rawScore;
        totalGraded += scored.totalGraded;
      }
      final totalItems = appState.scanTotalItems ?? totalGraded;
      final percentage = totalGraded == 0 ? 0.0 : rawScore / totalGraded * 100;
      final currentUser = FirebaseAuth.instance.currentUser;

      final result = ResultModel(
        resultId: ResultModel.buildId(examId: examId, batchId: batchId, examineeId: examineeId),
        examId: examId,
        examCode: appState.activeExamCode,
        batchId: batchId,
        examineeId: examineeId,
        rawScore: rawScore,
        totalGraded: totalGraded,
        totalItems: totalItems,
        percentage: percentage,
        status: 'Graded',
        scannedAt: DateTime.now(),
        processedByUid: currentUser?.uid ?? '',
        processedByName: currentUser?.displayName ?? 'Unknown',
      );

      final outcome = await _firestoreService.persistResult(result);
      if (!mounted) return;
      setState(() {
        _persistedResult = result;
        _persistOutcome = outcome;
        _isPersisting = false;
      });

      if (outcome == ResultPersistOutcome.created) {
        await _maybePromptBatchCompletion(batchId);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _persistError = 'Could not save the result: $e';
        _isPersisting = false;
      });
    }
  }

  /// After a brand-new result pushes a batch's actualCount up to its
  /// expectedCount, ask staff to confirm marking it Completed -- never
  /// flips the status automatically, since expectedCount is only ever a
  /// staff estimate.
  Future<void> _maybePromptBatchCompletion(String batchId) async {
    final batch = await _firestoreService.getBatchById(batchId);
    if (batch == null || !mounted) return;
    if (batch.status == 'Active' && batch.expectedCount > 0 && batch.actualCount >= batch.expectedCount) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Batch Complete?'),
          content: Text(
            'All expected examinees (${batch.expectedCount}) have been scanned for batch '
            '${batch.batchCode}. Mark this batch as Completed?',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not Yet')),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Mark Completed')),
          ],
        ),
      );
      if (confirm == true) {
        await _firestoreService.completeBatch(batchId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final results = appState.scannedResults;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Scan Results — ${appState.activeExamCode}', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildPersistenceBanner(appState),
            Expanded(
              child: results.isEmpty
                  ? (_persistedResult != null ? _buildPersistedSummary(_persistedResult!) : _buildEmptyState())
                  : _buildResultsList(results, appState),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: PrimaryButton(
                label: 'RETURN HOME',
                color: AppColors.darkNavy,
                onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(AppRoutes.staffHome, (r) => false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPersistenceBanner(AppState appState) {
    if (!appState.hasRealScanSession) return const SizedBox.shrink();

    String message;
    Color background;
    Color foreground;
    FaIconData icon;

    if (_isPersisting) {
      message = 'Saving result…';
      background = AppColors.lightBg;
      foreground = AppColors.textGray;
      icon = FontAwesomeIcons.cloudArrowUp;
    } else if (_persistError != null) {
      message = _persistError!;
      background = const Color(0xFFFEE2E2);
      foreground = const Color(0xFF991B1B);
      icon = FontAwesomeIcons.triangleExclamation;
    } else if (_persistedResult != null) {
      message = _persistOutcome == ResultPersistOutcome.updated
          ? 'Existing result updated for ${appState.scanExamineeName ?? "this examinee"}.'
          : 'Result saved for ${appState.scanExamineeName ?? "this examinee"}.';
      background = AppColors.emerald100;
      foreground = const Color(0xFF065F46);
      icon = FontAwesomeIcons.circleCheck;
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
          FaIcon(icon, size: 14, color: foreground),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: foreground))),
        ],
      ),
    );
  }

  Widget _buildPersistedSummary(ResultModel result) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FaIcon(FontAwesomeIcons.fileCircleCheck, color: AppColors.primaryGreen, size: 28),
            const SizedBox(height: 12),
            Text(
              '${result.rawScore}/${result.totalGraded} · ${result.percentage.toStringAsFixed(0)}%',
              style: AppTextStyles.heading(size: 16),
            ),
            const SizedBox(height: 6),
            Text(
              'Already graded and saved for this examinee.',
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
          ],
        ),
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
        final result = results[sheetIndex];
        final scored = scoreOmrResult(result, appState.answerKeys[result.examCode]);
        return _buildSheetCard(sheetIndex, scored);
      },
    );
  }

  Widget _buildSheetCard(int sheetIndex, ScoredResult scored) {
    final blankCount = scored.items.where((i) => i.isBlank).length;
    final ambiguousCount = scored.items.where((i) => i.isAmbiguous).length;
    final isGraded = scored.totalGraded > 0;

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
                child: Text('Sheet ${sheetIndex + 1}', style: AppTextStyles.heading(size: 13)),
              ),
              if (isGraded)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: AppColors.emerald100, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    '${scored.rawScore}/${scored.totalGraded} · ${scored.percentage.toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF065F46)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${scored.items.length} items · $blankCount blank · $ambiguousCount flagged',
            style: AppTextStyles.body(size: 9, color: AppColors.textGray),
          ),
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
