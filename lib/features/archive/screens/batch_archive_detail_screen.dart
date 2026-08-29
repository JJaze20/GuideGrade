import 'dart:io';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/examinee_dialog.dart';
import '../../exam/screens/scanned_image_viewer_screen.dart';

/// Opens one archived batch: its info, exam type, every scanned image it
/// holds, and the corresponding result for each scan, plus the summary
/// statistics the app already computes over a batch.
class BatchArchiveDetailScreen extends StatefulWidget {
  final String batchId;

  const BatchArchiveDetailScreen({super.key, required this.batchId});

  @override
  State<BatchArchiveDetailScreen> createState() => _BatchArchiveDetailScreenState();
}

class _BatchArchiveDetailScreenState extends State<BatchArchiveDetailScreen> {
  bool _didInit = false;
  bool _loading = true;
  LocalBatch? _batch;
  final Map<String, File> _images = {};
  final Map<String, File> _rectifiedImages = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    _load();
  }

  Future<void> _load() async {
    final repo = AppStateScope.of(context).batchRepository;
    final batch = await repo.getBatchById(widget.batchId);
    if (batch != null) {
      for (final scan in batch.scans) {
        _images[scan.id] = await repo.resolveScanImage(batch.id, scan);
        final rectified = await repo.resolveScanRectifiedImage(batch.id, scan);
        if (rectified != null) _rectifiedImages[scan.id] = rectified;
      }
    }
    if (!mounted) return;
    setState(() {
      _batch = batch;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final batch = _batch;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Archived Batch', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : batch == null
                ? Center(
                    child: Text('This batch could not be found.',
                        style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildHeader(batch),
                      const SizedBox(height: 14),
                      _buildSummary(batch),
                      if (batch.scans.isNotEmpty && batch.untaggedScanCount > 0) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const FaIcon(FontAwesomeIcons.userClock, size: 10, color: Color(0xFF92400E)),
                            const SizedBox(width: 6),
                            Text(
                              '${batch.untaggedScanCount} of ${batch.scanCount} sheets have no student assigned',
                              style: AppTextStyles.body(size: 9.5, color: const Color(0xFF92400E), weight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ],
                      if (batch.duplicateExamineeNumbers.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            const FaIcon(FontAwesomeIcons.triangleExclamation, size: 10, color: Color(0xFF991B1B)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Examinee number reused: ${batch.duplicateExamineeNumbers.join(', ')}',
                                style: AppTextStyles.body(size: 9.5, color: const Color(0xFF991B1B), weight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      _buildCloudBackupButton(),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const FaIcon(FontAwesomeIcons.images, size: 12, color: AppColors.primaryGreen),
                          const SizedBox(width: 6),
                          Text('Scanned Sheets & Results', style: AppTextStyles.heading(size: 12)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (batch.scans.isEmpty)
                        Text('No scans were saved to this batch.',
                            style: AppTextStyles.body(size: 10, color: AppColors.textGray))
                      else
                        ...List.generate(
                          batch.scans.length,
                          (i) => _buildScanCard(batch, i, appState),
                        ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildHeader(LocalBatch batch) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            batch.description.isNotEmpty ? batch.description : 'Batch ${batch.batchCode}',
            style: AppTextStyles.heading(size: 15),
          ),
          const SizedBox(height: 4),
          _kv('Batch Code', batch.batchCode),
          _kv('Exam Type', '${batch.examTitle} (${batch.examCode})'),
          _kv('Status', batch.status),
          _kv(
            'Scanned',
            batch.hasScanLimit
                ? '${batch.scanCount} / ${batch.expectedCount}${batch.isFull ? '  ·  FULL' : ''}'
                : '${batch.scanCount}',
          ),
          if (batch.hasScanLimit) _kv('Remaining', '${batch.remainingCapacity}'),
          _kv('Saved', _fmtDateTime(batch.updatedAt)),
          _kv('Created', _fmtDateTime(batch.createdAt)),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(k, style: AppTextStyles.body(size: 9.5, color: AppColors.textGray, weight: FontWeight.w700)),
          ),
          Expanded(child: Text(v, style: AppTextStyles.body(size: 10))),
        ],
      ),
    );
  }

  Widget _buildSummary(LocalBatch batch) {
    final avg = batch.averagePercentage;
    return Row(
      children: [
        Expanded(
          child: _stat(
            'SCANS',
            batch.hasScanLimit ? '${batch.scanCount}/${batch.expectedCount}' : '${batch.scanCount}',
            full: batch.isFull,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: _stat('GRADED', '${batch.gradedCount}')),
        const SizedBox(width: 8),
        Expanded(child: _stat('AVG %', avg == null ? '—' : avg.toStringAsFixed(0))),
        const SizedBox(width: 8),
        Expanded(
          child: _stat(
            'REMAINING',
            batch.hasScanLimit ? '${batch.remainingCapacity}' : '—',
            full: batch.isFull,
          ),
        ),
      ],
    );
  }

  Widget _stat(String label, String value, {bool full = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: full ? const Color(0xFFFEE2E2) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: full ? const Color(0xFFFCA5A5) : AppColors.cardBorder),
      ),
      child: Column(
        children: [
          Text(label,
              style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w800,
                color: full ? const Color(0xFF991B1B) : AppColors.textGray,
              )),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                fontFamily: 'monospace',
                color: full ? const Color(0xFF991B1B) : AppColors.darkNavy,
              )),
        ],
      ),
    );
  }

  /// Placeholder entry point for cloud backup. Intentionally non-functional
  /// for now — the real implementation lands when a cloud `BatchRepository`
  /// is added (see project_batch_centric_storage memory / the SyncingBatch-
  /// Repository plan). This button just marks where that hooks in.
  // TODO(partner): wire to RemoteBatchDataSource.uploadBatch(batchId) once
  // the cloud BatchRepository exists. Should push batch.json + every
  // images/<scanId>.jpg for this batch to Firestore + Firebase Storage.
  Widget _buildCloudBackupButton() {
    return Opacity(
      opacity: 0.55,
      child: OutlinedButton.icon(
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cloud backup isn’t available yet — coming in a future update.'),
            ),
          );
        },
        icon: const FaIcon(FontAwesomeIcons.cloudArrowUp, size: 13, color: AppColors.darkNavy),
        label: const Text('BACK UP THIS BATCH TO CLOUD'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.darkNavy,
          side: const BorderSide(color: Color(0xFFCBD5E1)),
          padding: const EdgeInsets.symmetric(vertical: 11),
          minimumSize: const Size.fromHeight(0),
          textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
        ),
      ),
    );
  }

  Future<void> _tagExaminee(LocalBatch batch, LocalScan scan, int index) async {
    final others = <String>{
      for (final s in batch.scans)
        if (s.id != scan.id) (s.examinee?.examineeNumber.trim() ?? ''),
    }..removeWhere((e) => e.isEmpty);

    final res = await showExamineeDialog(
      context,
      initial: scan.examinee,
      sheetLabel: 'Sheet ${index + 1}',
      otherNumbers: others,
    );
    if (res == null || !mounted) return;
    await AppStateScope.of(context).batchRepository.setScanExaminee(
          batchId: batch.id,
          scanId: scan.id,
          examinee: res.cleared ? null : res.info,
        );
    if (!mounted) return;
    await _load();
  }

  /// Redoes one sheet's capture in place — its existing photo, decode, and
  /// result are replaced (its position in the batch and student tag are
  /// not); for a sheet whose original scan came out bad. Opens the normal
  /// scanner UI, bound to just this one scan via [AppState.startRescan].
  Future<void> _rescanSheet(LocalBatch batch, LocalScan scan, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rescan This Sheet?'),
        content: Text(
          'Sheet ${index + 1}\'s current photo and result will be replaced with a new capture. '
          'This can\'t be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Rescan')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final appState = AppStateScope.of(context);
    appState.startRescan(batch, scan);
    await Navigator.of(context).pushNamed(AppRoutes.examScanning);
    // Backed out of the scanner (its close button just pops) without
    // finishing — AppState.finishRescan already clears this on success, so
    // a value still set here means the rescan needs to be abandoned.
    if (appState.rescanScanId != null) appState.cancelRescan();
    if (!mounted) return;
    // Whether it was saved or the user backed out mid-capture, refresh from
    // disk so the card reflects whatever actually happened.
    await _load();
  }

  Widget _buildScanCard(LocalBatch batch, int index, AppState appState) {
    final scan = batch.scans[index];
    final scored = scoreOmrResult(scan.decoded, appState.answerKeys[batch.examCode]);
    final file = _images[scan.id];
    final result = scan.result;
    final examinee = scan.examinee;
    final tagged = examinee != null && !examinee.isEmpty;

    final blankCount = scored.items.where((i) => i.isBlank).length;
    final ambiguousCount = scored.items.where((i) => i.isAmbiguous).length;
    final graded = result != null && result.isGraded;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _thumbnail(file, scored, index),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        tagged ? examinee.displayName : 'Sheet ${index + 1}',
                        style: AppTextStyles.heading(size: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (graded)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: AppColors.emerald100, borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          '${result.rawScore}/${result.totalGraded} · ${result.percentage.toStringAsFixed(0)}%',
                          style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Color(0xFF065F46)),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
                        child: const Text('Ungraded',
                            style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Color(0xFF92400E))),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  tagged
                      ? 'Sheet ${index + 1} · Examinee ${examinee.examineeNumber}'
                      : '${scored.items.length} items · $blankCount blank · $ambiguousCount flagged',
                  style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _tagExaminee(batch, scan, index),
                      icon: FaIcon(tagged ? FontAwesomeIcons.userPen : FontAwesomeIcons.userPlus,
                          size: 10, color: AppColors.darkNavy),
                      label: Text(tagged ? 'Edit student' : 'Tag student',
                          style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.darkNavy,
                        side: const BorderSide(color: Color(0xFFCBD5E1)),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _rescanSheet(batch, scan, index),
                      icon: const FaIcon(FontAwesomeIcons.arrowRotateRight, size: 10, color: AppColors.darkNavy),
                      label: const Text('Rescan', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700)),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.darkNavy,
                        side: const BorderSide(color: Color(0xFFCBD5E1)),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    if (file != null)
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ScannedImageViewerScreen(
                              imagePath: file.path,
                              title: tagged
                                  ? 'Sheet ${index + 1} — ${examinee.displayName}'
                                  : 'Sheet ${index + 1}',
                              scoredItems: scored.items,
                              rectifiedImagePath: _rectifiedImages[scan.id]?.path,
                              template: omrTemplates[scored.examCode],
                            ),
                          ),
                        ),
                        icon: const FaIcon(FontAwesomeIcons.magnifyingGlassPlus, size: 11, color: AppColors.primaryGreen),
                        label: const Text('View Scan', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.primaryGreen,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _thumbnail(File? file, ScoredResult scored, int index) {
    Widget placeholder = Container(
      width: 64,
      height: 84,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.lightBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: const FaIcon(FontAwesomeIcons.image, size: 16, color: AppColors.textGray),
    );

    if (file == null || !file.existsSync()) return placeholder;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        file,
        width: 64,
        height: 84,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _fmtDateTime(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ap = d.hour < 12 ? 'AM' : 'PM';
    return '${_months[d.month - 1]} ${d.day}, ${d.year} · $h:$m $ap';
  }
}
