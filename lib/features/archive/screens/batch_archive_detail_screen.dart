import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_scorer.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/batch_repository.dart';
import '../../../core/state/app_state.dart';
import '../../../core/sync/cloud_restore_service.dart';
import '../../../core/sync/sync_job.dart';
import '../../../core/sync/sync_manager.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/examinee_dialog.dart';
import '../../../shared/widgets/name_crop_strip.dart';
import '../../exam/screens/scanned_image_viewer_screen.dart';
import '../../exam/widgets/scan_editing_factory.dart';
import '../../exam/widgets/scan_result_summary.dart';

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
  bool _syncing = false;
  LocalBatch? _batch;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    _load();
  }

  /// Only fetches the batch's manifest — decoded from `batch.enc` in one
  /// shot regardless of scan count (see [LocalBatchRepository]), so this
  /// stays fast even for a batch with hundreds of scans. Deliberately does
  /// **not** resolve any scan's image here: each is decrypted lazily, only
  /// when its own card is actually built (see [_ScanThumbnail] and
  /// [_viewScan]) — resolving every image up front is exactly what would
  /// turn a large batch into a multi-second stall before this screen could
  /// show anything.
  Future<void> _load() async {
    final repo = AppStateScope.of(context).batchRepository;
    final batch = await repo.getBatchById(widget.batchId);
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
                // A real ListView.builder, not an eagerly-built list of
                // every scan card up front -- for a batch with hundreds of
                // scans, only the cards actually visible (plus a small
                // buffer) are ever built, and each card's own thumbnail
                // decrypt only happens when *that card* is built (see
                // _ScanThumbnail). Index 0 is the header block; indices
                // 1..scanCount map to _buildScanCard(i - 1).
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: 1 + batch.scans.length,
                    itemBuilder: (context, i) {
                      if (i == 0) return _buildHeaderSection(batch, appState);
                      return _buildScanCard(batch, i - 1, appState);
                    },
                  ),
      ),
    );
  }

  /// Everything above the per-scan cards: batch info, summary stats,
  /// warning banners, cloud-sync button, per-exam analytics links, and the
  /// "Scanned Sheets & Results" section header. Built once, as item 0 of
  /// the archive's [ListView.builder] (see [build]).
  Widget _buildHeaderSection(LocalBatch batch, AppState appState) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
        if (batch.likelyDuplicateScans.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const FaIcon(FontAwesomeIcons.clone, size: 10, color: Color(0xFF991B1B)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Possible duplicate sheet${batch.likelyDuplicateScans.length == 1 ? '' : 's'} '
                  '(same answers scanned twice): '
                  '${batch.likelyDuplicateScans.map((p) => '${_scanLabel(batch, p.a)} & ${_scanLabel(batch, p.b)}').join(', ')}',
                  style: AppTextStyles.body(size: 9.5, color: const Color(0xFF991B1B), weight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _buildSyncToCloudButton(batch, appState),
        if (batch.examCode == 'QTM') ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pushNamed(
              AppRoutes.qtmBatchAnalytics,
              arguments: batch.id,
            ),
            icon: const FaIcon(FontAwesomeIcons.chartSimple, size: 13, color: AppColors.darkNavy),
            label: const Text('View QTM Analytics'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.darkNavy,
              side: const BorderSide(color: Color(0xFFCBD5E1)),
              padding: const EdgeInsets.symmetric(vertical: 11),
              minimumSize: const Size.fromHeight(0),
              textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
            ),
          ),
        ],
        if (batch.examCode == 'TAT') ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pushNamed(
              AppRoutes.tatBatchAnalytics,
              arguments: batch.id,
            ),
            icon: const FaIcon(FontAwesomeIcons.chartSimple, size: 13, color: AppColors.darkNavy),
            label: const Text('View TAT Analytics'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.darkNavy,
              side: const BorderSide(color: Color(0xFFCBD5E1)),
              padding: const EdgeInsets.symmetric(vertical: 11),
              minimumSize: const Size.fromHeight(0),
              textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
            ),
          ),
        ],
        if (batch.examCode == 'AT') ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pushNamed(
              AppRoutes.atBatchAnalytics,
              arguments: batch.id,
            ),
            icon: const FaIcon(FontAwesomeIcons.chartSimple, size: 13, color: AppColors.darkNavy),
            label: const Text('View Admission Test Analytics'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.darkNavy,
              side: const BorderSide(color: Color(0xFFCBD5E1)),
              padding: const EdgeInsets.symmetric(vertical: 11),
              minimumSize: const Size.fromHeight(0),
              textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
            ),
          ),
        ],
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
              style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
      ],
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

  /// Same "tagged name, else Sheet N" convention used throughout this
  /// screen's per-scan labels (see `_buildScanCard`) — used for the
  /// possible-duplicate banner, which references two scans by position.
  String _scanLabel(LocalBatch batch, LocalScan scan) {
    final examinee = scan.examinee;
    if (examinee != null && !examinee.isEmpty) return examinee.displayName;
    return 'Sheet ${batch.scans.indexOf(scan) + 1}';
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

  /// Forces a manual sync pass and reports this batch's own outcome.
  ///
  /// [SyncManager.syncNow] drains the whole shared job queue (per-batch
  /// scoping isn't something the queue offers), so the button's job is
  /// really "nudge everything now" — the status line below it is what
  /// actually tells the user whether *this* batch made it, since a global
  /// drain can still leave some of a batch's own jobs `failedPermanent` /
  /// `blockedConflict` (e.g. a bad payload, or an answer-key conflict) even
  /// after it runs.
  Widget _buildSyncToCloudButton(LocalBatch batch, AppState appState) {
    final syncManager = appState.syncManager;
    if (syncManager == null) {
      // No cloud data plane configured for this run (Supabase not
      // initialized) -- nothing to sync, so nothing to show here.
      return const SizedBox.shrink();
    }

    return ListenableBuilder(
      listenable: syncManager,
      builder: (context, _) {
        final jobs = syncManager.queue.jobs.where((j) => j.batchId == batch.id).toList();
        final pending = jobs.where((j) => j.isPending || j.isInProgress).length;
        final failed = jobs.where((j) => j.status == SyncJobStatus.failedPermanent).length;
        final blocked = jobs.where((j) => j.status == SyncJobStatus.blockedConflict).length;
        final busy = _syncing || syncManager.isRunning;

        String statusText;
        Color statusColor;
        if (jobs.isEmpty) {
          statusText = 'Fully synced to cloud';
          statusColor = AppColors.primaryGreen;
        } else if (failed > 0 || blocked > 0) {
          final parts = [
            if (failed > 0) '$failed failed',
            if (blocked > 0) '$blocked blocked',
            if (pending > 0) '$pending pending',
          ];
          statusText = parts.join(' · ');
          statusColor = const Color(0xFF991B1B);
        } else {
          statusText = '$pending item${pending == 1 ? '' : 's'} pending sync';
          statusColor = const Color(0xFF92400E);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton.icon(
              onPressed: busy ? null : () => _syncToCloud(batch, syncManager),
              icon: busy
                  ? const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const FaIcon(FontAwesomeIcons.cloudArrowUp, size: 13, color: AppColors.darkNavy),
              label: Text(busy ? 'SYNCING…' : 'SYNC TO CLOUD'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.darkNavy,
                side: const BorderSide(color: Color(0xFFCBD5E1)),
                padding: const EdgeInsets.symmetric(vertical: 11),
                minimumSize: const Size.fromHeight(0),
                textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.3),
              ),
            ),
            const SizedBox(height: 6),
            Text(statusText, style: AppTextStyles.body(size: 9.5, color: statusColor, weight: FontWeight.w600)),
          ],
        );
      },
    );
  }

  Future<void> _syncToCloud(LocalBatch batch, SyncManager syncManager) async {
    setState(() => _syncing = true);
    try {
      // syncNow() only pulls forward jobs still `pending` -- a
      // `failedPermanent` content push (e.g. one that hit a since-fixed
      // validation bug) is left exactly as it is, by design (see
      // SyncManager.syncNow's doc comment), so it never gets swept up by a
      // plain "sync now". Reviving it here -- but only the batch's own
      // content-push jobs, and only failedPermanent, never
      // blockedConflict -- is what "tap Sync to Cloud" should mean to a
      // user looking at a stuck batch; a conflict (e.g. an answer key
      // changed elsewhere) still needs an actual resolution, not a blind
      // retry that could clobber someone else's change.
      final queue = syncManager.queue;
      for (final job in queue.jobs) {
        if (job.batchId != batch.id) continue;
        if (job.status != SyncJobStatus.failedPermanent) continue;
        if (!job.isBatchContentPush) continue;
        await queue.update(job.copyWith(
          status: SyncJobStatus.pending,
          attempts: 0,
          nextAttemptAt: DateTime.now().toUtc(),
          clearLastErrorCode: true,
        ));
      }
      await syncManager.syncNow();
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
    if (!mounted) return;

    final jobs = syncManager.queue.jobs.where((j) => j.batchId == batch.id);
    final stuck = jobs.where((j) =>
        j.status == SyncJobStatus.failedPermanent || j.status == SyncJobStatus.blockedConflict);
    final message = jobs.isEmpty
        ? 'This batch is fully synced to the cloud.'
        : stuck.isNotEmpty
            ? '${stuck.length} item(s) for this batch could not sync — see status below.'
            : 'Sync started — some items are still uploading.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
      batchId: batch.id,
      scan: scan,
      repository: AppStateScope.of(context).batchRepository,
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
    final scored = scoreOmrResult(scan.effectiveDecoded, appState.answerKeys[batch.examCode]);
    final result = scan.result;
    final examinee = scan.examinee;
    final tagged = examinee != null && !examinee.isEmpty;

    final blankCount = scored.items.where((i) => i.isBlank).length;
    final ambiguousCount = scored.items.where((i) => i.isAmbiguous).length;
    final hasName = tagged && (examinee.firstName.trim().isNotEmpty || examinee.lastName.trim().isNotEmpty);
    final hasNumber = tagged && examinee.examineeNumber.trim().isNotEmpty;
    final cardTitle = hasName ? examinee.displayName : 'Unnamed examinee';

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
          _ScanThumbnail(
            key: ValueKey(scan.id),
            batchId: batch.id,
            scan: scan,
            repository: appState.batchRepository,
            cloudRestoreService: appState.cloudRestoreService,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cardTitle,
                  style: AppTextStyles.heading(size: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  tagged
                      // A tag can be partial in either direction now that
                      // name entry is manual-only and the name fields
                      // aren't required — name it whichever piece is
                      // actually still missing rather than assuming it's
                      // always the number.
                      ? (hasNumber
                          ? 'Sheet ${index + 1} · Examinee ${examinee.examineeNumber}'
                          : 'Sheet ${index + 1} · needs examinee #')
                      : 'Sheet ${index + 1} · ${scored.items.length} items · $blankCount blank · $ambiguousCount flagged',
                  style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                ),
                const SizedBox(height: 8),
                NameCropStrip(
                  batchId: batch.id,
                  scan: scan,
                  repository: appState.batchRepository,
                ),
                const SizedBox(height: 8),
                ScanResultSummary(
                  examCode: batch.examCode,
                  result: result,
                ),
                const SizedBox(height: 8),
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
                    TextButton.icon(
                      onPressed: () => _viewScan(batch, scan, scored, index, tagged, examinee),
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

  /// Opens the full scan viewer for one sheet, decrypting its image(s) on
  /// demand right here rather than reusing anything [_ScanThumbnail] may
  /// have already decrypted — a single extra decrypt on a deliberate tap
  /// is cheap (see [BatchCryptoService]'s doc comment) and keeps this
  /// screen from having to thread decrypted bytes back out of that widget.
  Future<void> _viewScan(
    LocalBatch batch,
    LocalScan scan,
    ScoredResult scored,
    int index,
    bool tagged,
    ExamineeInfo? examinee,
  ) async {
    final appState = AppStateScope.of(context);
    final repo = appState.batchRepository;
    var bytes = await repo.resolveScanImage(batch.id, scan);
    if (bytes == null) {
      // Not on disk yet -- if this scan came from a cloud restore (Supabase
      // → GuideGrade retrieval), its image may simply not have been
      // downloaded yet. Try once, lazily, right here; resolveScanImage
      // itself is never modified -- this is purely a caller-side fallback.
      await appState.cloudRestoreService?.restoreImageIfMissing(
        batchId: batch.id,
        scan: scan,
        rectified: false,
      );
      if (!mounted) return;
      bytes = await repo.resolveScanImage(batch.id, scan);
    }
    if (!mounted) return;
    if (bytes == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("This sheet's photo could not be found.")),
      );
      return;
    }
    var rectifiedBytes = await repo.resolveScanRectifiedImage(batch.id, scan);
    if (rectifiedBytes == null && scan.rectifiedImageFileName != null) {
      await appState.cloudRestoreService?.restoreImageIfMissing(
        batchId: batch.id,
        scan: scan,
        rectified: true,
      );
      if (!mounted) return;
      rectifiedBytes = await repo.resolveScanRectifiedImage(batch.id, scan);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ScannedImageViewerScreen(
          imageBytes: bytes,
          title: tagged && examinee != null ? 'Sheet ${index + 1} — ${examinee.displayName}' : 'Sheet ${index + 1}',
          scoredItems: scored.items,
          rectifiedImageBytes: rectifiedBytes,
          template: omrTemplates[scored.examCode],
          scanTemplateVersion: scored.templateVersion,
          editing: scanEditingFor(appState, batch.id, scan),
          meshInteriorMeasuredFrac: scored.meshInteriorMeasuredFrac,
        ),
      ),
    );
    if (mounted) await _load(); // pick up any corrections made in the viewer
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

/// A scan's thumbnail, decrypted lazily — only once *this* card is actually
/// built (see [BatchArchiveDetailScreen]'s [ListView.builder]), not for
/// every scan in the batch up front. [_future] is created once in
/// initializer position (not inline in [build]), so scrolling/rebuilding
/// this widget while it stays mounted doesn't re-trigger a fresh decrypt —
/// only actually leaving and re-entering the viewport (a fresh State) does,
/// which is the same lazy-loading trade-off any large image list makes.
class _ScanThumbnail extends StatefulWidget {
  final String batchId;
  final LocalScan scan;
  final BatchRepository repository;

  /// Null when the cloud data plane isn't configured for this run. When
  /// present, used as a caller-side fallback (see [_ScanThumbnailState.
  /// _resolveImage]) to lazily restore a cloud-sourced scan's image the
  /// first time its thumbnail is actually built — [repository.
  /// resolveScanImage] itself is never modified.
  final CloudRestoreService? cloudRestoreService;

  const _ScanThumbnail({
    super.key,
    required this.batchId,
    required this.scan,
    required this.repository,
    this.cloudRestoreService,
  });

  @override
  State<_ScanThumbnail> createState() => _ScanThumbnailState();
}

class _ScanThumbnailState extends State<_ScanThumbnail> {
  late final Future<Uint8List?> _future = _resolveImage();

  /// Resolves the original image, falling back to a single lazy
  /// [CloudRestoreService.restoreImageIfMissing] attempt (then re-resolving)
  /// when it's absent locally — the scan may have arrived via cloud
  /// restoration with its image not yet downloaded.
  Future<Uint8List?> _resolveImage() async {
    final bytes = await widget.repository.resolveScanImage(widget.batchId, widget.scan);
    if (bytes != null) return bytes;
    final restored = await widget.cloudRestoreService?.restoreImageIfMissing(
      batchId: widget.batchId,
      scan: widget.scan,
      rectified: false,
    );
    if (restored != true) return null;
    return widget.repository.resolveScanImage(widget.batchId, widget.scan);
  }

  static Widget _placeholder() => Container(
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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return _placeholder();
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 64,
            height: 84,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => _placeholder(),
          ),
        );
      },
    );
  }
}
