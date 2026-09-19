import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/app_bottom_nav.dart';

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
      Navigator.of(context).pushNamed(AppRoutes.examSetup).then((_) => _load());
    } else {
      Navigator.of(context)
          .pushNamed(AppRoutes.batchArchiveDetail, arguments: batch.id)
          .then((_) => _load());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: AppColors.primaryGreen,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Text('G', style: AppTextStyles.logo(size: 20, color: Colors.amber.shade300)),
                      const SizedBox(width: 6),
                      Text(
                        'GUIDE GRADE',
                        style: AppTextStyles.heading(size: 12, color: Colors.white, weight: FontWeight.w800)
                            .copyWith(letterSpacing: 1.1),
                      ),
                    ],
                  ),
                  InkWell(
                    onTap: () => Navigator.of(context).pushNamed(AppRoutes.profile),
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(color: Color(0xFF1B5E20), shape: BoxShape.circle),
                      child: const FaIcon(FontAwesomeIcons.userTie, size: 12, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: AppColors.cardBorder),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'WELCOME BACK',
                                style: AppTextStyles.body(size: 9.5, weight: FontWeight.w800, color: AppColors.primaryGreen)
                                    .copyWith(letterSpacing: 0.6),
                              ),
                              Text('NDMU Staff Officer', style: AppTextStyles.heading(size: 13)),
                            ],
                          ),
                          Text('Marbel, PH', style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () => Navigator.of(context).pushNamed(AppRoutes.examManagement),
                        icon: const FaIcon(FontAwesomeIcons.fileLines, size: 14, color: Colors.amber),
                        label: const Text('EXAM MANAGEMENT'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primaryGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () =>
                            Navigator.of(context).pushNamed(AppRoutes.batchManagement).then((_) => _load()),
                        icon: const FaIcon(FontAwesomeIcons.folderPlus, size: 14, color: Colors.amber),
                        label: const Text('BATCH MANAGEMENT'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.darkNavy,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const FaIcon(FontAwesomeIcons.layerGroup, size: 12, color: AppColors.primaryGreen),
                        const SizedBox(width: 6),
                        Text('Batches & Results Registry', style: AppTextStyles.heading(size: 12)),
                      ],
                    ),
                    const SizedBox(height: 10),
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
          ],
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'home'),
    );
  }

  Widget _buildEmpty() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        children: [
          const FaIcon(FontAwesomeIcons.folderOpen, size: 28, color: AppColors.textGray),
          const SizedBox(height: 8),
          Text('No batches yet', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            'Create a batch in Batch Management, then scan it.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body(size: 9.5, color: AppColors.textGray),
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
                    style: AppTextStyles.body(size: 8.5, weight: FontWeight.w800, color: AppColors.primaryGreen)
                        .copyWith(letterSpacing: 0.6),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          batch.description.isNotEmpty ? batch.description : batch.batchCode,
                          style: AppTextStyles.body(size: 12.5, weight: FontWeight.w700),
                          maxLines: 1,
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
                            style: const TextStyle(fontSize: 8, color: Color(0xFF92400E), fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${batch.scanCount}/${batch.expectedCount} sheets'
                    '${batch.resultsAvailable ? ' · results ready' : ''}',
                    style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                  ),
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
