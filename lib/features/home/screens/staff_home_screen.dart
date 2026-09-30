import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/app_bottom_nav.dart';
import '../../../shared/widgets/needs_review_badge.dart';

/// Staff Home / Dashboard. Shows the welcome card, the Exam/Batch
/// management entry points, and the batch registry — every local batch,
/// which is the container all scans and results now live in. Tapping a
/// still-scannable batch resumes the scan workflow; tapping a finished one
/// opens it in the Archive.
class StaffHomeScreen extends StatefulWidget {
  const StaffHomeScreen({super.key});

  @override
  State<StaffHomeScreen> createState() => _StaffHomeScreenState();
}

class _StaffHomeScreenState extends State<StaffHomeScreen> {
  bool _didInit = false;
  bool _loading = true;
  List<LocalBatch> _batches = [];

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

  void _openBatch(LocalBatch batch) {
    final appState = AppStateScope.of(context);
    if (batch.canScan && !batch.isArchived) {
      appState.setActiveExamCode(batch.examCode);
      // Pass the pressed batch so Select Batch opens with it already chosen.
      Navigator.of(context)
          .pushNamed(AppRoutes.examSetup, arguments: batch.id)
          .then((_) => _load());
    } else {
      Navigator.of(context)
          .pushNamed(AppRoutes.batchArchiveDetail, arguments: batch.id)
          .then((_) => _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F5),
      appBar: AppBar(
        title: const Text('GuideGrade'),
        backgroundColor: Colors.white,
        foregroundColor: AppColors.primaryGreen,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Your profile',
            onPressed: () => Navigator.of(context).pushNamed(AppRoutes.profile),
            icon: const Icon(Icons.account_circle_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: [
                  Text('Your workspace', style: AppTextStyles.heading(size: 28)),
                  const SizedBox(height: 8),
                  Text(
                    'Prepare exams, manage batches, and review your results.',
                    style: AppTextStyles.body(size: 15, color: AppColors.textGray),
                  ),
                  const SizedBox(height: 24),
                  _workspaceAction(
                    title: 'Exam Management',
                    description: 'Preview questionnaires and print answer sheets',
                    icon: Icons.description_outlined,
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.examManagement),
                  ),
                  const SizedBox(height: 12),
                  _workspaceAction(
                    title: 'Batch Management',
                    description: 'Organize examinees and prepare batches for scanning',
                    icon: Icons.folder_outlined,
                    onTap: () => Navigator.of(context)
                        .pushNamed(AppRoutes.batchManagement).then((_) => _load()),
                  ),
                  const SizedBox(height: 32),
                  Text('Batches & results', style: AppTextStyles.heading(size: 21)),
                  const SizedBox(height: 6),
                  Text(
                    'Open a batch to continue scanning or view its saved results.',
                    style: AppTextStyles.body(size: 14, color: AppColors.textGray),
                  ),
                  const SizedBox(height: 16),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_batches.isEmpty)
                    _buildEmpty()
                  else
                    ..._batches.map(_buildBatchRow),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'home'),
    );
  }

  Widget _workspaceAction({
    required String title,
    required String description,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFFDCE5DF)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF4EC),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: AppColors.primaryGreen),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTextStyles.heading(size: 18)),
                    const SizedBox(height: 4),
                    Text(description,
                        style: AppTextStyles.body(size: 14, color: AppColors.textGray)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, color: AppColors.primaryGreen),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          const FaIcon(FontAwesomeIcons.folderOpen, size: 28, color: AppColors.textGray),
          const SizedBox(height: 8),
          Text('No batches yet', style: AppTextStyles.body(size: 17, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Create a batch in Batch Management, then scan it.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body(size: 14, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }

  Widget _buildBatchRow(LocalBatch batch) {
    final done = batch.isCompleted || batch.isArchived;
    return InkWell(
      onTap: () => _openBatch(batch),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: done ? Colors.white : const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: done ? AppColors.cardBorder : const Color(0xFFFCD34D)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${batch.examTitle.toUpperCase()} · ${batch.examCode}',
                    style: AppTextStyles.body(size: 12, weight: FontWeight.w700, color: AppColors.primaryGreen)
                        .copyWith(letterSpacing: 0.6),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          batch.description.isNotEmpty ? batch.description : batch.batchCode,
                          style: AppTextStyles.body(size: 16, weight: FontWeight.w700),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (done)
                        const FaIcon(FontAwesomeIcons.circleCheck, size: 12, color: AppColors.primaryGreen)
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            batch.status.toUpperCase(),
                            style: const TextStyle(fontSize: 11, color: Color(0xFF92400E), fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${batch.scanCount}/${batch.expectedCount} sheets'
                    '${batch.resultsAvailable ? ' · results ready' : ''}',
                    style: AppTextStyles.body(size: 13, color: AppColors.textGray),
                  ),
                  if (batch.needsReview) ...[
                    const SizedBox(height: 6),
                    NeedsReviewChip(count: batch.needsReviewCount),
                  ],
                ],
              ),
            ),
            const FaIcon(FontAwesomeIcons.chevronRight, size: 12, color: Color(0xFFCBD5E1)),
          ],
        ),
      ),
    );
  }
}
