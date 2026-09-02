import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/app_bottom_nav.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: const AppHeaderBar(title: 'ARCHIVE'),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _batches.isEmpty
                  ? _buildEmptyState()
                  : _buildList(),
        ),
      ),
      bottomNavigationBar: const AppBottomNav(activeTab: 'cloud'),
    );
  }

  Widget _buildList() {
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
            Text('Locally Saved Batches', style: AppTextStyles.heading(size: 11.5)),
          ],
        ),
        const SizedBox(height: 8),
        ..._batches.map(_buildBatchCard),
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
                          style: AppTextStyles.body(size: 12.5, weight: FontWeight.w700),
                          maxLines: 1,
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
