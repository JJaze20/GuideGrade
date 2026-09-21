import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/primary_button.dart';

/// Select Compatible Batch — the batch-binding step of the scan workflow.
///
/// The exam type was chosen on the Exam Hub; this screen shows only the
/// batches whose exam type matches it, so a scan can never be started
/// against an incompatible batch. If none exist yet, it routes to Create
/// Batch with the exam type pre-locked. Once a batch is picked and the
/// scanner launches, [AppState.startScanSession] binds every captured sheet
/// and result to it.
class ExamSetupScreen extends StatefulWidget {
  /// A batch to have already selected when the screen opens: set when the
  /// user came here by pressing that batch in the registry on the home
  /// screen, so they do not have to find and pick it again. Ignored if the
  /// batch is not among the scannable batches for the active exam.
  final String? preselectBatchId;

  const ExamSetupScreen({super.key, this.preselectBatchId});

  @override
  State<ExamSetupScreen> createState() => _ExamSetupScreenState();
}

class _ExamSetupScreenState extends State<ExamSetupScreen> {
  bool _didInit = false;
  bool _appliedPreselect = false;
  bool _loading = true;
  List<LocalBatch> _batches = [];
  LocalBatch? _selected;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    _loadBatches();
  }

  Future<void> _loadBatches() async {
    setState(() => _loading = true);
    final appState = AppStateScope.of(context);
    final all = await appState.batchRepository.getBatchesByExamCode(appState.activeExamCode);
    final scannable = all.where((b) => b.canScan).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    // Keep the current selection only if it's still in the list. On the first
    // load, with nothing chosen yet, select the batch the user pressed on the
    // home screen (if any). After that the user's own choice always wins.
    final wantedId = _selected?.id ?? (_appliedPreselect ? null : widget.preselectBatchId);
    _appliedPreselect = true;
    LocalBatch? stillSelected;
    for (final b in scannable) {
      if (b.id == wantedId) stillSelected = b;
    }
    setState(() {
      _batches = scannable;
      _selected = stillSelected;
      _loading = false;
    });
  }

  String get _examTitle {
    final code = AppStateScope.of(context).activeExamCode;
    return examCatalog
        .firstWhere((e) => e.examCode == code, orElse: () => examCatalog.first)
        .title;
  }

  Future<void> _createCompatibleBatch() async {
    final code = AppStateScope.of(context).activeExamCode;
    final created = await Navigator.of(context).pushNamed(
      AppRoutes.createBatch,
      arguments: code,
    );
    if (created == true) _loadBatches();
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
        title: Text('Select Batch', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildExamTypeCard(appState.activeExamCode),
              const SizedBox(height: 14),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_batches.isEmpty)
                              _buildNoCompatibleBatch()
                            else
                              _buildBatchPicker(),
                            const SizedBox(height: 16),
                            _buildAnswerKeyCard(appState),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              PrimaryButton(
                label: 'START SCANNING',
                icon: FontAwesomeIcons.camera,
                onPressed: _selected == null ? null : () => _launchScanner(appState),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExamTypeCard(String code) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const FaIcon(FontAwesomeIcons.fileLines, size: 16, color: AppColors.primaryGreen),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EXAM TYPE', style: AppTextStyles.body(size: 8.5, weight: FontWeight.w800, color: AppColors.primaryGreen)),
                const SizedBox(height: 2),
                Text(_examTitle, style: AppTextStyles.heading(size: 13)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: AppColors.lightBg, borderRadius: BorderRadius.circular(20)),
            child: Text(code, style: AppTextStyles.body(size: 10, weight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _buildNoCompatibleBatch() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFCD34D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const FaIcon(FontAwesomeIcons.triangleExclamation, size: 14, color: Color(0xFF92400E)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'No compatible batch for $_examTitle',
                  style: AppTextStyles.body(size: 11, weight: FontWeight.w700, color: const Color(0xFF92400E)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Every scan must belong to a batch of the same exam type. Create one to start scanning.',
            style: AppTextStyles.body(size: 9.5, color: const Color(0xFF92400E)),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _createCompatibleBatch,
            icon: const FaIcon(FontAwesomeIcons.folderPlus, size: 13, color: Color(0xFF92400E)),
            label: const Text('CREATE COMPATIBLE BATCH'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF92400E),
              side: const BorderSide(color: Color(0xFFFCD34D)),
              padding: const EdgeInsets.symmetric(vertical: 10),
              textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchPicker() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Select Compatible Batch', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
              TextButton.icon(
                onPressed: _createCompatibleBatch,
                icon: const FaIcon(FontAwesomeIcons.plus, size: 10, color: AppColors.primaryGreen),
                label: const Text('New', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryGreen,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ..._batches.map(_buildBatchTile),
        ],
      ),
    );
  }

  Widget _buildBatchTile(LocalBatch batch) {
    final selected = _selected?.id == batch.id;
    final full = batch.isFull;
    return InkWell(
      // Still selectable when full -- launching then shows exactly why it
      // can't be scanned into, pointing at Batch Management, rather than
      // silently hiding the batch or its reason.
      onTap: () => setState(() => _selected = batch),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected ? AppColors.emerald100 : AppColors.lightBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primaryGreen : AppColors.cardBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? AppColors.primaryGreen : AppColors.textGray,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    batch.description.isNotEmpty ? batch.description : 'Batch ${batch.batchCode}',
                    style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${batch.batchCode}  ·  ${batch.scanCount}/${batch.expectedCount} sheets  ·  ${batch.status}',
                    style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                  ),
                ],
              ),
            ),
            if (full) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(20)),
                child: const Text('FULL',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: Color(0xFF991B1B))),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAnswerKeyCard(AppState appState) {
    final loaded = appState.answerKeyStatus == 'Loaded Success';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Exam Answer Key Setup', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Status:', style: AppTextStyles.body(size: 10, color: AppColors.textGray, weight: FontWeight.w600)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: loaded ? AppColors.emerald100 : const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  loaded ? '🔑 KEY LOADED' : '⚠️ PENDING KEY',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: loaded ? const Color(0xFF065F46) : const Color(0xFF92400E),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.answerKeyEntry),
            icon: const FaIcon(FontAwesomeIcons.penToSquare, size: 13, color: AppColors.primaryGreen),
            label: const Text('ADD EXAM ANSWER KEY'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textDark,
              side: const BorderSide(color: Color(0xFFCBD5E1)),
              padding: const EdgeInsets.symmetric(vertical: 10),
              textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _launchScanner(AppState appState) async {
    final selected = _selected;
    if (selected == null) return;

    if (selected.isFull) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Batch Full'),
          content: Text(
            'This batch has reached its scan limit of ${selected.expectedCount} examinees. '
            'Please modify the batch in Batch Management if you need to increase the limit.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;

    if (appState.answerKeyStatus != 'Loaded Success') {
      final addKeyFirst = await _showNoAnswerKeyDialog();
      if (addKeyFirst == null) return;
      if (addKeyFirst) {
        if (!mounted) return;
        Navigator.of(context).pushNamed(AppRoutes.answerKeyEntry);
        return;
      }
    }

    appState.resetScanProgress();
    appState.startScanSession(selected);
    if (!mounted) return;
    Navigator.of(context).pushNamed(AppRoutes.examScanning);
  }

  Future<bool?> _showNoAnswerKeyDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No Answer Key Set'),
        content: const Text(
          'This exam has no answer key yet. Sheets can still be scanned and saved to the batch, '
          'but nothing will be graded until a key is added.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Scan Without Key')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Add Key First')),
        ],
      ),
    );
  }
}
