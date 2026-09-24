import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../core/sync/cloud_restore_service.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/app_bottom_nav.dart';
import '../../../shared/widgets/needs_review_badge.dart';
import '../../../shared/widgets/app_header_bar.dart';

/// Archive — every locally saved batch, organized around the batch rather
/// than around individual scans. Each card is a batch container (exam type,
/// scan count, whether results exist, date saved); opening one shows all of
/// its scanned images and their results.
class CloudArchiveScreen extends StatefulWidget {
  const CloudArchiveScreen({super.key});

  @override
  State<CloudArchiveScreen> createState() => _CloudArchiveScreenState();
}

class _CloudArchiveScreenState extends State<CloudArchiveScreen> {
  bool _didInit = false;
  bool _loading = true;
  bool _restoring = false;
  List<LocalBatch> _batches = [];

  /// The exam type whose archived batches are showing, or null while the
  /// three-button picker is. Purely a view filter over [_batches] -- nothing
  /// is reloaded, copied or written when it changes.
  String? _selectedExam;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final batches = await AppStateScope.of(context).batchRepository.getBatches();
    if (!mounted) return;
    setState(() {
      _batches = batches;
      _loading = false;
    });
  }

  /// Manual "Restore from Cloud" (v1: manual only — see
  /// [CloudRestoreService]'s doc comment for why this isn't automatic yet).
  /// Confirms first, runs the restore, then re-runs [_load] so anything
  /// restored appears immediately — the same pattern [_buildBatchCard]'s
  /// pull-to-refresh already uses.
  Future<void> _restoreFromCloud() async {
    final service = AppStateScope.of(context).cloudRestoreService;
    if (service == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restore from Cloud?'),
        content: const Text(
          'This checks Supabase for batches created by any authorized '
          'Guidance Council account and adds anything missing to this '
          'device. Existing local data is never changed or removed.\n\n'
          'TAT scores are recalculated using the current answer key and '
          'may differ if it has since changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _restoring = true);
    final summary = await service.restoreAll();
    if (!mounted) return;
    setState(() => _restoring = false);

    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_summaryMessage(summary))),
    );
  }

  String _summaryMessage(RestoreSummary summary) {
    if (!summary.isSuccess) {
      return 'Could not reach Supabase. Check your connection and try again.';
    }
    if (summary.cloudBatchesFound == 0) {
      return 'No cloud batches found for this account.';
    }
    return '${summary.cloudBatchesFound} cloud batch'
        '${summary.cloudBatchesFound == 1 ? '' : 'es'} found — '
        '${summary.batchesRestored} new, ${summary.batchesUpdated} updated, '
        '${summary.scansRestored} scan${summary.scansRestored == 1 ? '' : 's'} restored. '
        'Images download automatically when you open a scan.';
  }

  @override
  Widget build(BuildContext context) {
    final cloudRestoreService = AppStateScope.of(context).cloudRestoreService;
    return PopScope(
      // Back from a type's list returns to the picker instead of leaving.
      canPop: _selectedExam == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _selectedExam = null);
      },
      child: Scaffold(
        backgroundColor: AppColors.lightBg,
        appBar: AppHeaderBar(
          title: 'ARCHIVE',
          trailing: cloudRestoreService == null
              ? null
              : IconButton(
                  tooltip: 'Restore from Cloud',
                  onPressed: _restoring ? null : _restoreFromCloud,
                  icon: _restoring
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const FaIcon(FontAwesomeIcons.cloudArrowDown, size: 16, color: Colors.white),
                ),
        ),
        body: SafeArea(
          top: false,
          child: RefreshIndicator(
            onRefresh: _load,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _batches.isEmpty
                    ? _buildEmptyState()
                    : _selectedExam == null
                        ? _buildTypePicker()
                        : _buildTypeList(_selectedExam!),
          ),
        ),
        bottomNavigationBar: const AppBottomNav(activeTab: 'cloud'),
      ),
    );
  }

  /// The exam types the Archive offers, in button order.
  static const List<String> _examTypes = ['QTM', 'TAT', 'AT'];

  static const String _otherKey = 'OTHER';

  /// Batches of one exam type, by each batch's own stored
  /// [LocalBatch.examCode]; keeps [_batches]' existing order.
  List<LocalBatch> _batchesFor(String examCode) =>
      _batches.where((b) => b.examCode == examCode).toList(growable: false);

  /// Batches whose exam code none of the three buttons covers. They get one
  /// extra "Other" button (only when such a batch exists) so a batch is never
  /// unreachable.
  List<LocalBatch> get _otherBatches =>
      _batches.where((b) => !_examTypes.contains(b.examCode)).toList(growable: false);

  List<LocalBatch> _batchesForSelection(String selection) =>
      selection == _otherKey ? _otherBatches : _batchesFor(selection);

  /// Landing view: one button per exam type, like the Web Results exam
  /// selector. No batch is listed until a type is chosen.
  Widget _buildTypePicker() {
    final gradedTotal = _batches.where((b) => b.resultsAvailable).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(child: _StatBox(label: 'SAVED BATCHES', value: '${_batches.length}', color: AppColors.darkNavy)),
            const SizedBox(width: 10),
            Expanded(child: _StatBox(label: 'WITH RESULTS', value: '$gradedTotal', color: AppColors.primaryGreen)),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const FaIcon(FontAwesomeIcons.boxArchive, size: 11, color: AppColors.primaryGreen),
            const SizedBox(width: 6),
            Text('Choose an exam type', style: AppTextStyles.heading(size: 11.5)),
          ],
        ),
        const SizedBox(height: 10),
        for (final code in _examTypes) _buildTypeButton(code),
        if (_otherBatches.isNotEmpty) _buildTypeButton(_otherKey),
      ],
    );
  }

  String _typeTitle(String code) {
    if (code == _otherKey) return 'Other exam types';
    // Titles come from the existing exam catalog, never re-typed here.
    final entry = examCatalog.where((e) => e.examCode == code).firstOrNull;
    return entry?.title ?? code;
  }

  Widget _buildTypeButton(String code) {
    final count = _batchesForSelection(code).length;
    final label = code == _otherKey ? 'Other' : code;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        key: Key('archiveType.$code'),
        onTap: () => setState(() => _selectedExam = code),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                padding: const EdgeInsets.symmetric(vertical: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.emerald100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  label,
                  style: AppTextStyles.heading(size: 14).copyWith(color: AppColors.primaryGreen),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_typeTitle(code), style: AppTextStyles.body(size: 12.5, weight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      '$count ${count == 1 ? 'batch' : 'batches'}',
                      style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppColors.textGray),
            ],
          ),
        ),
      ),
    );
  }

  /// The archived batches of the chosen exam type only.
  Widget _buildTypeList(String selection) {
    final batches = _batchesForSelection(selection);
    final title = selection == _otherKey ? 'Archived Batches (Other)' : 'Archived $selection Batches';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          key: const Key('archiveTypeHeader'),
          children: [
            TextButton.icon(
              key: const Key('archiveBackToTypes'),
              onPressed: () => setState(() => _selectedExam = null),
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('Back'),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(title, style: AppTextStyles.heading(size: 13))),
          ],
        ),
        const SizedBox(height: 8),
        if (batches.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Center(
              child: Text(
                selection == _otherKey ? 'No batches here.' : 'No archived $selection batches yet.',
                style: AppTextStyles.body(size: 11, color: AppColors.textGray),
              ),
            ),
          )
        else
          ...batches.map(_buildBatchCard),
      ],
    );
  }

  Widget _buildBatchCard(LocalBatch batch) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => Navigator.of(context)
            .pushNamed(AppRoutes.batchArchiveDetail, arguments: batch.id)
            .then((_) => _load()),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          batch.description.isNotEmpty ? batch.description : 'Batch ${batch.batchCode}',
                          style: AppTextStyles.body(size: 14, weight: FontWeight.w800),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(batch.batchCode, style: AppTextStyles.body(size: 9.5, color: AppColors.textGray)),
                      ],
                    ),
                  ),
                  _statusChip(batch.status),
                ],
              ),
              if (batch.needsReview) ...[
                const SizedBox(height: 8),
                NeedsReviewChip(count: batch.needsReviewCount),
              ],
              const SizedBox(height: 10),
              _line(FontAwesomeIcons.fileLines, 'Exam Type: ${batch.examTitle} (${batch.examCode})'),
              const SizedBox(height: 4),
              _line(FontAwesomeIcons.images, 'Scans: ${batch.scanCount}'),
              const SizedBox(height: 4),
              _line(
                batch.resultsAvailable ? FontAwesomeIcons.circleCheck : FontAwesomeIcons.circleMinus,
                batch.resultsAvailable
                    ? 'Results available (${batch.gradedCount}/${batch.scanCount} graded)'
                    : 'No results yet',
                color: batch.resultsAvailable ? AppColors.primaryGreen : AppColors.textGray,
              ),
              const SizedBox(height: 4),
              _line(FontAwesomeIcons.solidCalendar, 'Saved ${_fmtDate(batch.updatedAt)}'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(FaIconData icon, String text, {Color? color}) {
    return Row(
      children: [
        FaIcon(icon, size: 10, color: color ?? AppColors.textGray),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: AppTextStyles.body(size: 9.5, color: color ?? AppColors.textGray),
          ),
        ),
      ],
    );
  }

  Widget _statusChip(String status) {
    Color bg;
    Color fg;
    switch (status) {
      case 'Draft':
        bg = const Color(0xFFFEF3C7);
        fg = const Color(0xFF92400E);
        break;
      case 'Active':
        bg = const Color(0xFFDBEAFE);
        fg = const Color(0xFF1E40AF);
        break;
      case 'Completed':
        bg = const Color(0xFFD1FAE5);
        fg = const Color(0xFF065F46);
        break;
      default:
        bg = const Color(0xFFF3F4F6);
        fg = const Color(0xFF374151);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status, style: AppTextStyles.body(size: 9.5, weight: FontWeight.w600, color: fg)),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      children: [
        const SizedBox(height: 120),
        const Center(child: FaIcon(FontAwesomeIcons.boxOpen, size: 44, color: AppColors.textGray)),
        const SizedBox(height: 14),
        Center(
          child: Text('No saved batches yet', style: AppTextStyles.body(size: 12, weight: FontWeight.w700)),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            'Scan a batch to see it archived here.',
            style: AppTextStyles.body(size: 10, color: AppColors.textGray),
          ),
        ),
      ],
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmtDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatBox({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 8.5, fontWeight: FontWeight.w800, color: AppColors.textGray)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
