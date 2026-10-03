import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../core/sync/cloud_restore_service.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/app_bottom_nav.dart';
import '../../../shared/widgets/needs_review_badge.dart';
import '../../../shared/widgets/app_header_bar.dart';
import '../../../shared/widgets/status_badge.dart';

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

  // Null shows all batches; filtering never changes stored data.
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
    final batches = await AppStateScope.of(
      context,
    ).batchRepository.getBatches();
    if (!mounted) return;
    setState(() {
      _batches = List.of(batches)
        ..sort((a, b) {
          final dateOrder = b.updatedAt.compareTo(a.updatedAt);
          return dateOrder != 0 ? dateOrder : a.id.compareTo(b.id);
        });
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

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          summary.isSuccess ? 'Restore complete' : 'Restore unsuccessful',
        ),
        content: Text(_summaryMessage(summary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
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
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppHeaderBar(
        title: 'ARCHIVE',
        trailing: cloudRestoreService == null
            ? null
            : IconButton(
                tooltip: 'Restore from Cloud',
                padding: EdgeInsets.zero,
                onPressed: _restoring ? null : _restoreFromCloud,
                icon: _restoring
                    ? const Center(
                        widthFactor: 1,
                        heightFactor: 1,
                        child: SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : const FaIcon(
                        FontAwesomeIcons.cloudArrowDown,
                        size: 16,
                        color: Colors.white,
                      ),
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
              : _buildBatchList(),
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'cloud'),
    );
  }

  static const List<String> _examTypes = ['AT', 'QTM', 'TAT'];

  Widget _buildBatchList() {
    final batches = _selectedExam == null
        ? _batches
        : _batches.where((batch) => batch.examCode == _selectedExam).toList();
    final gradedTotal = _batches
        .where((batch) => batch.resultsAvailable)
        .length;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      itemCount: batches.length + 1,
      itemBuilder: (context, index) {
        if (index > 0) return _buildBatchCard(batches[index - 1]);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: _StatBox(
                    label: 'SAVED BATCHES',
                    value: '${_batches.length}',
                    color: AppColors.darkNavy,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _StatBox(
                    label: 'WITH RESULTS',
                    value: '$gradedTotal',
                    color: AppColors.primaryGreen,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text('Browse batches', style: AppTextStyles.heading(size: 18)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilter(null),
                for (final code in _examTypes) _buildFilter(code),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${batches.length} ${batches.length == 1 ? 'batch' : 'batches'} · Tap a batch to view scans and results',
              style: AppTextStyles.body(size: 13, color: AppColors.textGray),
            ),
            const SizedBox(height: 16),
            if (batches.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Text(
                  'No archived $_selectedExam batches yet.',
                  style: AppTextStyles.body(
                    size: 14,
                    color: AppColors.textGray,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildFilter(String? code) {
    return ChoiceChip(
      key: Key('archiveType.${code ?? 'ALL'}'),
      label: Text(code ?? 'All'),
      selected: _selectedExam == code,
      onSelected: (_) => setState(() => _selectedExam = code),
      selectedColor: AppColors.emerald100,
      labelStyle: AppTextStyles.body(
        size: 14,
        weight: FontWeight.w700,
        color: _selectedExam == code
            ? AppColors.primaryGreen
            : AppColors.textGray,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
          padding: const EdgeInsets.all(18),
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
                          batch.description.isNotEmpty
                              ? batch.description
                              : 'Batch ${batch.batchCode}',
                          style: AppTextStyles.body(
                            size: 17,
                            weight: FontWeight.w800,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          batch.batchCode,
                          style: AppTextStyles.body(
                            size: 12,
                            color: AppColors.textGray,
                          ),
                        ),
                      ],
                    ),
                  ),
                  BatchStatusBadge(status: batch.status),
                ],
              ),
              if (batch.needsReview) ...[
                const SizedBox(height: 8),
                NeedsReviewChip(count: batch.needsReviewCount),
              ],
              const SizedBox(height: 10),
              _line(
                FontAwesomeIcons.fileLines,
                'Exam Type: ${batch.examTitle} (${batch.examCode})',
              ),
              const SizedBox(height: 4),
              _line(FontAwesomeIcons.images, 'Scans: ${batch.scanCount}'),
              const SizedBox(height: 4),
              _line(
                batch.resultsAvailable
                    ? FontAwesomeIcons.circleCheck
                    : FontAwesomeIcons.circleMinus,
                batch.resultsAvailable
                    ? 'Results available (${batch.gradedCount}/${batch.scanCount} graded)'
                    : 'No results yet',
                color: batch.resultsAvailable
                    ? AppColors.primaryGreen
                    : AppColors.textGray,
              ),
              const SizedBox(height: 4),
              _line(
                FontAwesomeIcons.solidCalendar,
                'Saved ${_fmtDate(batch.updatedAt)}',
              ),
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
            style: AppTextStyles.body(
              size: 12,
              color: color ?? AppColors.textGray,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        const Center(
          child: FaIcon(
            FontAwesomeIcons.boxOpen,
            size: 44,
            color: AppColors.textGray,
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            'No saved batches yet',
            style: AppTextStyles.body(size: 12, weight: FontWeight.w700),
          ),
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
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String _fmtDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

class _StatBox extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatBox({
    required this.label,
    required this.value,
    required this.color,
  });

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
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: AppColors.textGray,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
