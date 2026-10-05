import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../shared/widgets/state_views.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/surface_card.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart';
import '../services/guidance_web_archive_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_result_detail_view.dart';

/// The Guidance Council Web Console's Results page — a READ-ONLY viewer
/// over the Supabase examination archive.
///
/// Data flow (see [GuidanceWebResultsService]'s doc comment for exactly
/// why this is safe on Web): batch metadata and a selected batch's scans
/// are fetched directly from Supabase via the existing
/// `SupabaseSyncClient.readCloudBatches`/`readCloudScans`, mapped through
/// the existing, unmodified `cloud_batch_mapper.dart` functions, and held
/// only in this widget's state for the lifetime of the page — nothing is
/// written to the mobile encrypted local store, `CloudRestoreService` is
/// never called, and no scanned-sheet image is ever downloaded here.
///
/// Search and the status filter both run over the already-loaded scan
/// list in memory — selecting a different batch is the only thing that
/// issues a new Supabase request.
///
/// Batch selection is presented as three exam tabs (AT/TAT/QTM), with one
/// batch dropdown below showing only the selected tab's batches. All tabs are
/// filtered in memory from the SAME single [GuidanceWebResultsService.loadBatches]
/// call (see [_batchesFor]); picking a batch never triggers a second
/// batch-list request. There is only ever ONE active batch at a time (see
/// [_activeBatch]); switching to a different exam tab clears it.
class GuidanceWebResultsView extends StatefulWidget {
  const GuidanceWebResultsView({
    super.key,
    GuidanceWebResultsService? service,
    GuidanceWebArchiveService? archiveService,
    this.archivedBatch,
    this.onBackToArchive,
    this.refreshInterval = const Duration(seconds: 30),
  }) : _service = service,
       _archiveService = archiveService;

  final GuidanceWebResultsService? _service;

  /// Injectable for tests; only touched when the Archive action is used.
  final GuidanceWebArchiveService? _archiveService;

  /// When set, this page shows exactly this ARCHIVED batch (opened from the
  /// Web Archive) using the same scan table, search, filter, sort and
  /// Detailed Result view as the normal Results page — no second
  /// implementation. The batch dropdowns and the Archive action are not
  /// shown in this mode; [onBackToArchive] returns to the Archive list.
  final LocalBatch? archivedBatch;
  final VoidCallback? onBackToArchive;

  /// How often the batch list is re-checked while the page is open, to flag
  /// newly arrived batches with a red dot. `null` disables the re-check.
  final Duration? refreshInterval;

  @override
  State<GuidanceWebResultsView> createState() => _GuidanceWebResultsViewState();
}

const List<String> _statusFilterOptions = ['All', 'Graded', 'Ungraded'];

/// The three exam types this page groups batches into, in display order,
/// with the label used on each exam tab and above the batch dropdown.
/// Matches the exam
/// codes the mobile app itself already produces
/// (`LocalBatch.examCode` — 'AT' | 'QTM' | 'TAT'); no other exam code is
/// given special handling. Labels read from the canonical
/// exam_catalog.dart via examTypeDisplayLabel, not a separately
/// hand-maintained copy -- only the display ORDER (AT, TAT, QTM) is
/// specific to this page.
final List<(String examCode, String label)> _examGroups = [
  for (final code in ['AT', 'TAT', 'QTM']) (code, examTypeDisplayLabel(code)),
];

/// Sorts scans by their already-computed official percentage
/// ([LocalScanResult.percentage] — never a recalculation, never the legacy
/// cloud `score_percentage` column, which isn't even modeled on this class).
/// Ungraded scans (`result == null`) have no score to sort by and are
/// always placed last, regardless of direction.
List<LocalScan> sortScansByScore(List<LocalScan> scans, bool ascending) {
  final sorted = List<LocalScan>.from(scans);
  sorted.sort((a, b) {
    final pa = a.result?.percentage;
    final pb = b.result?.percentage;
    if (pa == null && pb == null) return 0;
    if (pa == null) return 1;
    if (pb == null) return -1;
    return ascending ? pa.compareTo(pb) : pb.compareTo(pa);
  });
  return sorted;
}

class _GuidanceWebResultsViewState extends State<GuidanceWebResultsView> {
  late final GuidanceWebResultsService _service =
      widget._service ?? GuidanceWebResultsService();
  late final GuidanceWebArchiveService _archiveService =
      widget._archiveService ?? GuidanceWebArchiveService();
  final TextEditingController _searchController = TextEditingController();

  bool _loadingBatches = true;
  List<LocalBatch> _batches = [];
  String? _batchesError;

  /// The single selected/active batch — never more than one at a time. The
  /// one batch dropdown (for the selected exam tab, see [_selectedExam]) shows
  /// it selected only when its `examCode` matches `_activeBatch?.examCode`,
  /// otherwise it shows "Select batch" (see [_buildExamDropdown]'s `value:`).
  /// Switching exam tabs clears it (see [_selectExamTab]), so there is no
  /// separate per-exam memory to clear.
  LocalBatch? _activeBatch;

  /// The exam tab (AT/TAT/QTM) currently shown. Only the selected tab's
  /// batch dropdown is visible; switching tabs clears [_activeBatch] when it
  /// belongs to a different exam, so the table never shows results under the
  /// wrong tab.
  String _selectedExam = _examGroups.first.$1;

  /// Batch ids that were present when the page loaded or that have been
  /// opened since. A batch outside this set arrived while the page was open
  /// and puts a red dot on its exam tab until it is opened. `null` until the
  /// first successful load, so no dots show before then.
  Set<String>? _seenBatchIds;

  Timer? _refreshTimer;

  bool _loadingScans = false;
  List<LocalScan> _scans = [];
  String? _scansError;

  /// The canonical examinee for each scan in [_scans] that has one (keyed
  /// by scan id), read through `scans.examinee_id` -> `examinees.id`. NOT
  /// every scan in [_scans] has an entry here -- [_scans] now holds every
  /// scan in the batch, linked or not, while this map only ever has one for
  /// a scan whose `examinee_id` resolves to a real `examinees` row (see
  /// [GuidanceWebResultsService.loadResultsForBatch]'s own doc comment).
  Map<String, ExamineeRecord> _linkedExaminees = {};

  String _statusFilter = 'All';
  String _identityFilter = 'All';

  /// `null` = natural (as-loaded) order; `true`/`false` = Score column
  /// sorted ascending/descending. Cycles null → ascending → descending →
  /// null on each tap of the Score header. Purely a display-order concern —
  /// never mutates [_scans] or recomputes any result value.
  bool? _scoreSortAscending;
  final ScrollController _tableScroll = ScrollController();

  /// The scan currently open in the Detailed Result view (Phase 3), or null
  /// while the Results table itself is showing. Set only by a row's View
  /// button ([_buildResultRow]) and cleared only by the detail view's own
  /// "Back to Results" action — never touched by batch selection/search/
  /// filter changes, so returning from a detail view always lands back on
  /// the same batch and scan list, never a reload.
  LocalScan? _viewingScan;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    final archived = widget.archivedBatch;
    if (archived != null) {
      // Archive mode: show exactly this batch; no batch-list request.
      _loadingBatches = false;
      _batches = [archived];
      _activeBatch = archived;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _selectExamBatch(archived.examCode, archived);
      });
    } else {
      _loadBatches();
      final interval = widget.refreshInterval;
      if (interval != null) {
        _refreshTimer = Timer.periodic(interval, (_) => _refreshBatches());
      }
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchController.dispose();
    _tableScroll.dispose();
    super.dispose();
  }

  Future<void> _loadBatches() async {
    setState(() {
      _loadingBatches = true;
      _batchesError = null;
    });
    try {
      final all = await _service.loadBatches();
      // Batches archived in the Web Archive leave the NORMAL Results list
      // only. If the archive markers cannot be read (e.g. the table is not
      // deployed yet) Results still works and simply shows every batch.
      var archivedIds = <String>{};
      try {
        archivedIds = await _service.loadArchivedBatchIds();
      } catch (_) {}
      final batches = [
        for (final b in all)
          if (!archivedIds.contains(b.id)) b,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;
      setState(() {
        _batches = batches;
        _seenBatchIds = {for (final b in batches) b.id};
        _loadingBatches = false;
      });
    } on GuidanceWebResultsException catch (e) {
      if (!mounted) return;
      setState(() {
        _batchesError = e.message;
        _loadingBatches = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _batchesError = 'Could not load examination batches. Please try again.';
        _loadingBatches = false;
      });
    }
  }

  /// Quietly re-reads the batch list; failures are ignored and leave the
  /// current list untouched. Unopened new batches stay outside
  /// [_seenBatchIds], which is what lights the red dot.
  ///
  /// The selected batch is tracked by stable batch id, not object identity.
  /// Refreshes often recreate the underlying [LocalBatch] objects, so we must
  /// rebind [_activeBatch] to the current instance in the refreshed list when it
  /// still exists; otherwise Flutter sees two equal-by-id models as different
  /// objects and the dropdown assertion fires.
  Future<void> _refreshBatches() async {
    if (_loadingBatches || _batchesError != null) return;
    try {
      final all = await _service.loadBatches();
      var archivedIds = <String>{};
      try {
        archivedIds = await _service.loadArchivedBatchIds();
      } catch (_) {}
      final batches = [
        for (final b in all)
          if (!archivedIds.contains(b.id)) b,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;

      final activeBatchId = _activeBatch?.id;
      LocalBatch? refreshedActiveBatch;
      if (activeBatchId != null) {
        for (final batch in batches) {
          if (batch.id == activeBatchId) {
            refreshedActiveBatch = batch;
            break;
          }
        }
      }

      setState(() {
        _batches = batches;
        if (refreshedActiveBatch != null) {
          _activeBatch = refreshedActiveBatch;
        } else if (_activeBatch != null) {
          _activeBatch = null;
          _scans = [];
          _scansError = null;
          _loadingScans = false;
          _statusFilter = 'All';
          _searchController.clear();
          _viewingScan = null;
        }
      });
    } catch (_) {}
  }

  void _markBatchSeen(LocalBatch batch) {
    final seen = _seenBatchIds;
    if (seen == null || seen.contains(batch.id)) return;
    setState(() => _seenBatchIds = {...seen, batch.id});
  }

  bool _hasNewBatches(String examCode) {
    final seen = _seenBatchIds;
    if (seen == null) return false;
    return _batchesFor(examCode).any((b) => !seen.contains(b.id));
  }

  /// Batches for one exam code, filtered in memory from the single
  /// [_batches] list already loaded — never a new Supabase request. Order
  /// is preserved from [_loadBatches]'s own `updatedAt`-descending sort, so
  /// each group is already newest-first.
  List<LocalBatch> _batchesFor(String examCode) =>
      _batches.where((b) => b.examCode == examCode).toList(growable: false);

  void _selectExamTab(String examCode) {
    if (examCode == _selectedExam) return;
    setState(() {
      _selectedExam = examCode;
      if (_activeBatch?.examCode != examCode) {
        _activeBatch = null;
        _scans = [];
        _scansError = null;
        _loadingScans = false;
        _statusFilter = 'All';
        _searchController.clear();
        _viewingScan = null;
      }
    });
  }

  Future<void> _selectExamBatch(String examCode, LocalBatch? batch) async {
    if (batch == null) return;
    _markBatchSeen(batch);
    setState(() {
      _activeBatch = batch;
      _scans = [];
      _linkedExaminees = {};
      _scansError = null;
      _loadingScans = true;
      _statusFilter = 'All';
      _searchController.clear();
      _viewingScan = null;
    });
    try {
      final results = await _service.loadResultsForBatch(batch);
      if (!mounted) return;
      setState(() {
        _scans = results.scans;
        _linkedExaminees = results.linkedExamineeByScanId;
        _loadingScans = false;
      });
    } on GuidanceWebResultsException catch (e) {
      if (!mounted) return;
      setState(() {
        _scansError = e.message;
        _loadingScans = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scansError =
            'Could not load results for this batch. Please try again.';
        _loadingScans = false;
      });
    }
  }

  /// Effective status for filtering: an ungraded (no-result) scan is
  /// treated the same as `LocalScanResult.status == 'Ungraded'` — no new
  /// status value is introduced beyond the two the app already defines.
  String _effectiveStatus(LocalScan scan) => scan.result?.status ?? 'Ungraded';

  /// Search matches the official linked identity first; a scan with no
  /// resolved [ExamineeRecord] falls back to its own OCR/staff tag so it
  /// can still be found by the name/number staff typed in while reviewing
  /// the sheet -- that fallback is search-matching only, never a change to
  /// what identity the row displays as official (see [_displayName]).
  List<LocalScan> get _filteredScans {
    final term = _searchController.text.trim().toLowerCase();
    return _scans.where((scan) {
      final isLinked = _linkedExaminees.containsKey(scan.id);
      if (_identityFilter == 'Examinee' && !isLinked) {
        return false;
      }
      if (_identityFilter == 'Unlinked Examinee' && isLinked) return false;
      if (_statusFilter != 'All' && _effectiveStatus(scan) != _statusFilter)
        return false;
      if (term.isEmpty) return true;
      final linked = _linkedExaminees[scan.id];
      if (linked != null &&
          (linked.firstName.toLowerCase().contains(term) ||
              (linked.middleName ?? '').toLowerCase().contains(term) ||
              linked.lastName.toLowerCase().contains(term) ||
              linked.temporaryExamineeId.toLowerCase().contains(term))) {
        return true;
      }
      final examinee = scan.examinee;
      if (examinee == null) return false;
      return examinee.firstName.toLowerCase().contains(term) ||
          examinee.lastName.toLowerCase().contains(term) ||
          examinee.middleName.toLowerCase().contains(term) ||
          examinee.examineeNumber.toLowerCase().contains(term);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final viewing = _viewingScan;
    final batch = _activeBatch;
    return Padding(
      padding: EdgeInsets.all(
        AppSpace.gutterFor(MediaQuery.sizeOf(context).width),
      ),
      child: (viewing != null && batch != null)
          ? GuidanceWebResultDetailView(
              scan: viewing,
              batch: batch,
              linkedExaminee: _linkedExaminees[viewing.id],
              service: _service,
              onBack: () => setState(() => _viewingScan = null),
            )
          : LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .6,
                    ),
                    child: SingleChildScrollView(child: _buildControls()),
                  ),
                  const SizedBox(height: 16),
                  Expanded(child: _buildBody()),
                ],
              ),
            ),
    );
  }

  Widget _buildControls() {
    return SurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.archivedBatch != null)
            _buildArchivedHeader(widget.archivedBatch!)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildExamTabs(),
                const SizedBox(height: 14),
                _buildExamDropdown(
                  _selectedExam,
                  _examGroups.firstWhere((g) => g.$1 == _selectedExam).$2,
                ),
              ],
            ),
          if (_activeBatch != null) ...[
            if (!_loadingScans && _scansError == null) ...[
              const SizedBox(height: 14),
              _buildIdentityFilter(),
            ],
            if (_activeBatch!.description.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              _buildBatchDescription(_activeBatch!),
            ],
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final archive = OutlinedButton.icon(
                  key: const Key('archiveBatchButton'),
                  onPressed: _archiveActiveBatch,
                  icon: const Icon(Icons.inventory_2_outlined, size: 18),
                  label: const Text('Archive Batch'),
                );
                if (constraints.maxWidth < 600) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildSearchField(),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: [
                          SizedBox(width: 140, child: _buildStatusFilter()),
                          if (widget.archivedBatch == null) archive,
                        ],
                      ),
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(flex: 2, child: _buildSearchField()),
                    const SizedBox(width: 16),
                    Expanded(flex: 1, child: _buildStatusFilter()),
                    if (widget.archivedBatch == null) ...[
                      const SizedBox(width: 16),
                      archive,
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  /// Exam-type tabs (AT / TAT / QTM). Selecting one swaps the batch dropdown
  /// below it to that exam's batches.
  Widget _buildExamTabs() {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          for (var i = 0; i < _examGroups.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(
              child: _ExamTab(
                key: Key('examTab_${_examGroups[i].$1}'),
                label: constraints.maxWidth < 600
                    ? _examGroups[i].$1
                    : _examGroups[i].$2,
                tooltip: _examGroups[i].$2,
                count: _batchesFor(_examGroups[i].$1).length,
                hasNew: _hasNewBatches(_examGroups[i].$1),
                selected: _selectedExam == _examGroups[i].$1,
                onTap: () => _selectExamTab(_examGroups[i].$1),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Header shown instead of the exam tabs and batch dropdown when an ARCHIVED batch is
  /// opened from the Web Archive.
  Widget _buildArchivedHeader(LocalBatch batch) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      children: [
        TextButton.icon(
          onPressed: widget.onBackToArchive,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Back to Archive'),
        ),
        Text(
          '${batch.batchCode} — ${batch.examTitle.isNotEmpty ? batch.examTitle : batch.examCode} (Archived)',
          style: AppTextStyles.body(size: 13, weight: FontWeight.w700),
        ),
      ],
    );
  }

  /// "Archive Batch": confirms the action, then
  /// completes eligible Active batches, creates the archive marker, and
  /// removes the batch from this normal Results list.
  Future<void> _archiveActiveBatch() async {
    final batch = _activeBatch;
    if (batch == null) return;

    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          batch.isCompleted
              ? 'Archive this completed batch?'
              : 'Complete and archive this batch?',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'The batch will be removed from the normal Results list and '
                'moved to Completed Batch after verifying completion. Its results, scans, images, answers, and '
                'examinee records will remain available.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('archiveReasonField'),
                controller: reasonController,
                decoration: const InputDecoration(
                  labelText: 'Reason (optional)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    final reason = reasonController.text;
    if (confirmed != true || !mounted) return;

    try {
      await _archiveService.archiveBatch(batch, reason: reason);
      if (!mounted) return;
      setState(() {
        _batches = [
          for (final b in _batches)
            if (b.id != batch.id) b,
        ];
        _activeBatch = null;
        _scans = [];
        _viewingScan = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${batch.batchCode} was moved to Archive.')),
      );
    } on GuidanceWebArchiveException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not archive this batch. Please try again.'),
        ),
      );
    }
  }

  /// One batch's "name" line: code, exam title (or code) and created date.
  /// Shown smaller than the description wherever both appear.
  String _batchOptionLabel(LocalBatch b) =>
      '${b.batchCode} — ${b.examTitle.isNotEmpty ? b.examTitle : b.examCode}'
      ' (${_fmtDate(b.createdAt)})';

  // Batch identification hierarchy (Results batch selection/display area):
  // the DESCRIPTION is the main focus -- larger and bold -- while the batch
  // name/code line stays clearly readable but smaller.
  static const double _descriptionSize = 14;
  static const double _batchNameSize = 12;
  static const double _descriptionHeadingSize = 16;

  /// The selected batch's own description (the existing
  /// `batches.description` the Guidance Council typed when creating it),
  /// shown under the exam tabs and batch dropdown as the main visual focus so batches with
  /// similar names are easy to tell apart. Only built for a non-blank
  /// description, so a batch without one leaves the layout exactly as it was.
  /// Capped at three lines; the full text is in the tooltip.
  Widget _buildBatchDescription(LocalBatch batch) {
    final description = batch.description.trim();
    return Container(
      key: const Key('batchDescription'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.lightBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Batch Description',
            style: AppTextStyles.body(
              size: 12,
              weight: FontWeight.w600,
              color: AppColors.textGray,
            ),
          ),
          const SizedBox(height: 4),
          Tooltip(
            message: description,
            child: Text(
              description,
              style: AppTextStyles.heading(size: _descriptionHeadingSize),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// One exam-specific batch dropdown, populated ONLY with [_batchesFor]
  /// that [examCode] — never batches from another exam type. Shows a
  /// harmless disabled placeholder instead of an empty dropdown when this
  /// exam has no cloud batches at all (never fabricates one).
  Widget _buildExamDropdown(String examCode, String label) {
    final options = _batchesFor(examCode);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.body(size: 12, weight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        if (!_loadingBatches && options.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.lightBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Text(
              'No $examCode batches available',
              style: AppTextStyles.body(size: 11, color: AppColors.textGray),
            ),
          )
        else
          DropdownButtonFormField<LocalBatch>(
            value: _activeBatch?.examCode == examCode ? _activeBatch : null,
            isExpanded: true,
            decoration: _fieldDecoration(hint: 'Select batch'),
            // With a description, the description leads (larger, bold) and the
            // batch name follows smaller. A batch with no description keeps
            // the original single name line exactly as before. The closed
            // field stays a single line.
            selectedItemBuilder: (context) => [
              for (final b in options)
                Align(
                  alignment: Alignment.centerLeft,
                  child: b.description.trim().isEmpty
                      ? Text(
                          _batchOptionLabel(b),
                          style: AppTextStyles.body(size: 13),
                          overflow: TextOverflow.ellipsis,
                        )
                      : Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: b.description.trim(),
                                style: AppTextStyles.body(
                                  size: _descriptionSize,
                                  weight: FontWeight.w700,
                                ),
                              ),
                              TextSpan(
                                text: '   ·   ${_batchOptionLabel(b)}',
                                style: AppTextStyles.body(
                                  size: _batchNameSize,
                                  color: AppColors.textGray,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
            ],
            items: options.map((b) {
              final description = b.description.trim();
              return DropdownMenuItem(
                value: b,
                child: description.isEmpty
                    ? Text(
                        _batchOptionLabel(b),
                        style: AppTextStyles.body(size: 13),
                        overflow: TextOverflow.ellipsis,
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            description,
                            style: AppTextStyles.body(
                              size: _descriptionSize,
                              weight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            _batchOptionLabel(b),
                            style: AppTextStyles.body(
                              size: _batchNameSize,
                              color: AppColors.textGray,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
              );
            }).toList(),
            onChanged: _loadingBatches
                ? null
                : (batch) => _selectExamBatch(examCode, batch),
          ),
      ],
    );
  }

  Widget _buildIdentityFilter() {
    final linkedCount = _scans
        .where((scan) => _linkedExaminees.containsKey(scan.id))
        .length;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final group in ['All', 'Examinee', 'Unlinked Examinee'])
          ChoiceChip(
            key: Key('resultsIdentity$group'),
            label: Text(
              '$group (${group == 'All'
                  ? _scans.length
                  : group == 'Examinee'
                  ? linkedCount
                  : _scans.length - linkedCount})',
            ),
            selected: _identityFilter == group,
            onSelected: (_) => setState(() => _identityFilter = group),
          ),
      ],
    );
  }

  Widget _buildSearchField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Search',
          style: AppTextStyles.body(size: 12, weight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('resultsSearch'),
          controller: _searchController,
          decoration: _fieldDecoration(hint: 'Name or examinee ID').copyWith(
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: _searchController.clear,
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusFilter() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Status',
          style: AppTextStyles.body(size: 12, weight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: _statusFilter,
          isExpanded: true,
          decoration: _fieldDecoration(),
          items: _statusFilterOptions
              .map(
                (s) => DropdownMenuItem(
                  value: s,
                  child: Text(s, style: AppTextStyles.body(size: 13)),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() => _statusFilter = v ?? 'All'),
        ),
      ],
    );
  }

  InputDecoration _fieldDecoration({String? hint}) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.primaryGreen),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }

  Widget _buildBody() {
    if (_loadingBatches)
      return const LoadingState(message: 'Loading batches...');
    if (_batchesError != null)
      return _buildMessage(Icons.error_outline, _batchesError!, isError: true);
    if (_batches.isEmpty)
      return _buildMessage(
        Icons.inventory_2_outlined,
        'No examination batches found.',
      );
    if (_activeBatch == null)
      return _buildMessage(
        Icons.description_outlined,
        'Select a batch to view its results.',
      );
    if (_loadingScans) return const LoadingState(message: 'Loading results...');
    if (_scansError != null)
      return _buildMessage(Icons.error_outline, _scansError!, isError: true);
    if (_scans.isEmpty)
      return _buildMessage(
        Icons.description_outlined,
        'No results found for this batch.',
      );

    final filtered = _filteredScans;
    if (filtered.isEmpty) {
      return _buildMessage(
        Icons.search,
        'No results match your search or filter.',
      );
    }
    final sortAscending = _scoreSortAscending;
    final display = sortAscending == null
        ? filtered
        : sortScansByScore(filtered, sortAscending);
    return _buildTable(display);
  }

  void _cycleScoreSort() {
    setState(() {
      if (_scoreSortAscending == null) {
        _scoreSortAscending = true;
      } else if (_scoreSortAscending == true) {
        _scoreSortAscending = false;
      } else {
        _scoreSortAscending = null;
      }
    });
  }

  Widget _buildMessage(IconData icon, String message, {bool isError = false}) {
    if (isError) {
      return ErrorState(
        title: 'Could not load results',
        message: message,
        onRetry: _batchesError != null
            ? _loadBatches
            : () => _selectExamBatch(_activeBatch!.examCode, _activeBatch),
      );
    }
    return EmptyState(
      title: message,
      icon: icon,
      action: _scans.isNotEmpty && _filteredScans.isEmpty
          ? TextButton(
              onPressed: () {
                setState(() {
                  _statusFilter = 'All';
                  _identityFilter = 'All';
                });
                _searchController.clear();
              },
              child: const Text('Clear filters'),
            )
          : null,
    );
  }

  Widget _buildTable(List<LocalScan> scans) {
    final batch = _activeBatch!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
        final table = SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTableHeader(),
              const Divider(height: 1, color: AppColors.cardBorder),
              Expanded(
                child: ListView.separated(
                  itemCount: scans.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, color: AppColors.cardBorder),
                  itemBuilder: (context, index) =>
                      _buildResultRow(index + 1, scans[index], batch),
                ),
              ),
            ],
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${scans.length} of ${_scans.length} results',
                    style: AppTextStyles.body(size: 12),
                  ),
                  if (compact)
                    _buildScoreHeader(
                      AppTextStyles.body(size: 12, weight: FontWeight.w600),
                    ),
                ],
              ),
            ),
            Expanded(
              child: compact
                  ? ListView.separated(
                      key: const Key('resultsCards'),
                      itemCount: scans.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, index) =>
                          _buildResultCard(index + 1, scans[index], batch),
                    )
                  : Scrollbar(
                      controller: _tableScroll,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        key: const Key('resultsTable'),
                        controller: _tableScroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: math.max(
                            constraints.maxWidth,
                            740 * scale.clamp(1, 2),
                          ),
                          child: table,
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _viewButton(LocalScan scan) => Tooltip(
    message: 'View result for ${_displayName(scan, _linkedExaminees[scan.id])}',
    child: TextButton(
      onPressed: () => setState(() => _viewingScan = scan),
      style: TextButton.styleFrom(minimumSize: const Size(60, 44)),
      child: Text(
        'View',
        style: AppTextStyles.body(
          size: 13,
          weight: FontWeight.w700,
          color: AppColors.primaryGreen,
        ),
      ),
    ),
  );

  Widget _buildResultCard(int index, LocalScan scan, LocalBatch batch) {
    final linked = _linkedExaminees[scan.id];
    final result = scan.result;
    final status = _effectiveStatus(scan);
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$index', style: AppTextStyles.caption()),
          const SizedBox(height: 4),
          Text(
            _displayName(scan, linked),
            style: AppTextStyles.body(size: 14, weight: FontWeight.w600),
          ),
          if (linked != null)
            Text(linked.temporaryExamineeId, style: AppTextStyles.caption()),
          if (linked == null) _notLinkedBadge(),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              Text(
                result == null
                    ? 'Score: —'
                    : 'Score: ${result.rawScore} / ${_denominatorFor(batch, result)}',
                style: AppTextStyles.body(size: 13, weight: FontWeight.w600),
              ),
              Text(
                result == null
                    ? 'Percentage: —'
                    : '${result.percentage.toStringAsFixed(1)}%',
                style: AppTextStyles.body(size: 13),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _statusChip(status, status == 'Graded'),
              _viewButton(scan),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    TextStyle style = AppTextStyles.body(
      size: 11.5,
      weight: FontWeight.w800,
      color: AppColors.textGray,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(width: 28, child: Text('#', style: style)),
          Expanded(flex: 4, child: Text('EXAMINEE', style: style)),
          Expanded(flex: 2, child: _buildScoreHeader(style)),
          Expanded(flex: 1, child: Text('%', style: style)),
          Expanded(flex: 2, child: Text('STATUS', style: style)),
          const SizedBox(width: 72),
        ],
      ),
    );
  }

  /// The Score column header, tappable to cycle sort order (see
  /// [_cycleScoreSort]). Icon reflects the current state: unsorted shows a
  /// neutral up/down glyph, ascending an up arrow, descending a down arrow —
  /// the standard convention (↑ lowest→highest, ↓ highest→lowest).
  Widget _buildScoreHeader(TextStyle style) {
    final ascending = _scoreSortAscending;
    final IconData icon = ascending == null
        ? Icons.unfold_more
        : (ascending ? Icons.arrow_upward : Icons.arrow_downward);
    return Semantics(
      button: true,
      label: ascending == null
          ? 'Sort score: original order'
          : ascending
          ? 'Sort score: lowest first'
          : 'Sort score: highest first',
      child: Tooltip(
        message: 'Sort by score',
        child: InkWell(
          key: const Key('scoreSortHeader'),
          onTap: _cycleScoreSort,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('SCORE', style: style),
                const SizedBox(width: 4),
                Icon(icon, size: 13, color: style.color),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Display name for a row. Branches on [linked] itself, NOT on whether
  /// [resultExamineeName] returned something -- a linked scan whose official
  /// record has no usable name must show a plain placeholder, never fall
  /// back to the scan's own OCR/staff tag, since that would print OCR text
  /// on a row this view otherwise marks as having an official identity
  /// (bold/dark, no "not linked" badge -- see [_buildResultRow]'s
  /// [hasIdentity]), misrepresenting it as official. The OCR tag is only
  /// ever shown as plain scan information when the scan has NO link at all.
  String _displayName(LocalScan scan, ExamineeRecord? linked) {
    if (linked != null) return resultExamineeName(linked) ?? 'No name on file';
    final tag = scan.examinee;
    if (tag != null) return tag.displayName;
    return 'No name on file';
  }

  Widget _buildResultRow(int index, LocalScan scan, LocalBatch batch) {
    final linked = _linkedExaminees[scan.id];
    final hasIdentity = linked != null;
    final result = scan.result;
    final name = _displayName(scan, linked);
    final score = result == null
        ? '—'
        : '${result.rawScore} / ${_denominatorFor(batch, result)}';
    final percentage = result == null
        ? '—'
        : '${result.percentage.toStringAsFixed(1)}%';
    final status = _effectiveStatus(scan);
    final isGraded = status == 'Graded';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text('$index', style: AppTextStyles.body(size: 13)),
          ),
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: name,
                  child: Text(
                    name,
                    style: AppTextStyles.body(
                      size: 13,
                      weight: FontWeight.w600,
                      color: hasIdentity
                          ? AppColors.textDark
                          : AppColors.textGray,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                ),
                if (!hasIdentity) _notLinkedBadge(),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(score, style: AppTextStyles.body(size: 13)),
          ),
          Expanded(
            flex: 1,
            child: Text(percentage, style: AppTextStyles.body(size: 13)),
          ),
          Expanded(flex: 2, child: _statusChip(status, isGraded)),
          SizedBox(width: 72, child: _viewButton(scan)),
        ],
      ),
    );
  }

  /// "This scan is not linked to an official Examinee Record" -- shown under
  /// the name of every row with no resolved [ExamineeRecord], whether that's
  /// because `examinee_id` is null or because it no longer resolves (both
  /// look the same to the Guidance Council: the row needs processing in
  /// Examinee Records / Unlinked Scans either way). Status indication only --
  /// this view never offers a linking action of its own, to avoid a second,
  /// independent linking implementation alongside the existing one.
  Widget _notLinkedBadge() {
    return Container(
      key: const Key('notLinkedBadge'),
      margin: const EdgeInsets.only(top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Text(
        'Not linked to an Examinee Record',
        style: AppTextStyles.body(
          size: 10.5,
          weight: FontWeight.w700,
          color: AppColors.textGray,
        ),
      ),
    );
  }

  /// TAT's official denominator is its 160-point maximum score, never
  /// `LocalScanResult.totalItems` (130 -- the sheet's item count, a
  /// different number) — matches the exact `/ 160` convention already used
  /// by the mobile app's own TAT display (see `scan_result_summary.dart`
  /// and `tat_batch_analytics_screen.dart`). AT/QTM show their actual item
  /// count, which for a real batch already equals 72/60.
  int _denominatorFor(LocalBatch batch, LocalScanResult result) {
    return batch.examCode == 'TAT' ? 160 : result.totalItems;
  }

  Widget _statusChip(String status, bool isGraded) {
    return Align(
      alignment: Alignment.centerLeft,
      child: StatusBadge(
        label: status,
        tone: isGraded ? StatusTone.success : StatusTone.warning,
      ),
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

/// The OFFICIAL name the Results table shows for a row: the linked canonical
/// examinee's name (`scans.examinee_id` -> `examinees`) when it has a usable
/// name (first or last non-blank), otherwise null. [linked] is null for a
/// scan that was never linked, or one whose `examinee_id` is dangling --
/// [GuidanceWebResultsService.loadResultsForBatch] now returns every scan in
/// the batch, not only linked ones, so a null [linked] here is a normal,
/// expected case, not a defensive fallback. Deliberately does NOT fall back
/// to the scan's own OCR/staff-tagged [LocalScan.examinee] -- that is not an
/// official identity and must never be shown as though it were one; a
/// caller that wants to display the OCR tag as plain scan information
/// (never as the official name) reads [LocalScan.examinee] itself, as
/// [_buildResultRow] does.
String? resultExamineeName(ExamineeRecord? linked) {
  if (linked != null &&
      (linked.firstName.trim().isNotEmpty ||
          linked.lastName.trim().isNotEmpty)) {
    return linked.displayName;
  }
  return null;
}

class _ExamTab extends StatelessWidget {
  const _ExamTab({
    super.key,
    required this.label,
    required this.tooltip,
    required this.count,
    required this.hasNew,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String tooltip;
  final int count;
  final bool hasNew;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label:
          '$tooltip, $count batches${hasNew ? ', new batches available' : ''}',
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFD1FAE5) : Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? AppColors.primaryGreen : AppColors.cardBorder,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body(
                      size: 12,
                      weight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected
                          ? AppColors.primaryGreen
                          : AppColors.textDark,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Text(
                      '$count',
                      style: AppTextStyles.body(
                        size: 13,
                        weight: FontWeight.w800,
                        color: selected
                            ? AppColors.primaryGreen
                            : AppColors.textDark,
                      ),
                    ),
                    if (hasNew)
                      Positioned(
                        key: const Key('newBatchDot'),
                        top: -4,
                        right: -6,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
