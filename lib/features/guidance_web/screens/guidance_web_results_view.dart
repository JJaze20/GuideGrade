import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/local_batch.dart';
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
/// Batch selection is presented as three exam-specific dropdowns (AT/TAT/
/// QTM) rather than one combined list — all three are filtered in memory
/// from the SAME single [GuidanceWebResultsService.loadBatches] call (see
/// [_batchesFor]); picking a batch never triggers a second batch-list
/// request. There is only ever ONE selected/active batch across all three
/// dropdowns at a time (see [_activeBatch]) — picking a batch in one
/// dropdown implicitly clears whatever was showing in the other two,
/// since each dropdown's displayed value is derived from [_activeBatch]
/// itself (`_activeBatch?.examCode == examCode`), not from any per-exam
/// memory.
class GuidanceWebResultsView extends StatefulWidget {
  const GuidanceWebResultsView({super.key, GuidanceWebResultsService? service})
    : _service = service;

  final GuidanceWebResultsService? _service;

  @override
  State<GuidanceWebResultsView> createState() => _GuidanceWebResultsViewState();
}

const List<String> _statusFilterOptions = ['All', 'Graded', 'Ungraded'];

/// The three exam types this page groups batches into, in display order,
/// with the section label used above each dropdown. Matches the exam
/// codes the mobile app itself already produces
/// (`LocalBatch.examCode` — 'AT' | 'QTM' | 'TAT'); no other exam code is
/// given special handling.
const List<(String examCode, String label)> _examGroups = [
  ('AT', 'Admission Test (AT)'),
  ('TAT', 'Teaching Aptitude Test (TAT)'),
  ('QTM', 'Quantitative Math Test (QTM)'),
];

class _GuidanceWebResultsViewState extends State<GuidanceWebResultsView> {
  late final GuidanceWebResultsService _service =
      widget._service ?? GuidanceWebResultsService();
  final TextEditingController _searchController = TextEditingController();

  bool _loadingBatches = true;
  List<LocalBatch> _batches = [];
  String? _batchesError;

  /// The single selected/active batch across ALL THREE exam dropdowns —
  /// never more than one at a time. Whichever dropdown's `examCode`
  /// matches `_activeBatch?.examCode` shows it selected; the other two
  /// show "Select batch" (see [_buildExamDropdown]'s `value:`). Selecting
  /// a batch in one dropdown therefore implicitly clears the other two —
  /// there is no separate per-exam memory to clear.
  LocalBatch? _activeBatch;

  bool _loadingScans = false;
  List<LocalScan> _scans = [];
  String? _scansError;

  String _statusFilter = 'All';

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
    _loadBatches();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadBatches() async {
    setState(() {
      _loadingBatches = true;
      _batchesError = null;
    });
    try {
      final batches = await _service.loadBatches();
      batches.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      if (!mounted) return;
      setState(() {
        _batches = batches;
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

  /// Batches for one exam code, filtered in memory from the single
  /// [_batches] list already loaded — never a new Supabase request. Order
  /// is preserved from [_loadBatches]'s own `updatedAt`-descending sort, so
  /// each group is already newest-first.
  List<LocalBatch> _batchesFor(String examCode) =>
      _batches.where((b) => b.examCode == examCode).toList(growable: false);

  Future<void> _selectExamBatch(String examCode, LocalBatch? batch) async {
    if (batch == null) return;
    setState(() {
      _activeBatch = batch;
      _scans = [];
      _scansError = null;
      _loadingScans = true;
      _statusFilter = 'All';
      _searchController.clear();
      _viewingScan = null;
    });
    try {
      final scans = await _service.loadScansForBatch(batch);
      if (!mounted) return;
      setState(() {
        _scans = scans;
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

  List<LocalScan> get _filteredScans {
    final term = _searchController.text.trim().toLowerCase();
    return _scans.where((scan) {
      if (_statusFilter != 'All' && _effectiveStatus(scan) != _statusFilter)
        return false;
      if (term.isEmpty) return true;
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
      padding: const EdgeInsets.all(24),
      child: (viewing != null && batch != null)
          ? GuidanceWebResultDetailView(
              scan: viewing,
              batch: batch,
              service: _service,
              onBack: () => setState(() => _viewingScan = null),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildControls(),
                const SizedBox(height: 16),
                Expanded(child: _buildBody()),
              ],
            ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < _examGroups.length; i++) ...[
                if (i > 0) const SizedBox(width: 16),
                Expanded(
                  child: _buildExamDropdown(
                    _examGroups[i].$1,
                    _examGroups[i].$2,
                  ),
                ),
              ],
            ],
          ),
          if (_activeBatch != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(flex: 2, child: _buildSearchField()),
                const SizedBox(width: 16),
                Expanded(flex: 1, child: _buildStatusFilter()),
              ],
            ),
          ],
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
          style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600),
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
            decoration: _fieldDecoration(hint: 'Select a $examCode batch'),
            items: options
                .map(
                  (b) => DropdownMenuItem(
                    value: b,
                    child: Text(
                      '${b.batchCode} — ${b.examTitle.isNotEmpty ? b.examTitle : b.examCode}'
                      ' (${_fmtDate(b.createdAt)})',
                      style: AppTextStyles.body(size: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: _loadingBatches
                ? null
                : (batch) => _selectExamBatch(examCode, batch),
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
          style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _searchController,
          decoration:
              _fieldDecoration(
                hint: 'Search examinee name or number...',
              ).copyWith(
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
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
          style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: _statusFilter,
          decoration: _fieldDecoration(),
          items: _statusFilterOptions
              .map(
                (s) => DropdownMenuItem(
                  value: s,
                  child: Text(s, style: AppTextStyles.body(size: 11)),
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
      return _buildMessage(FontAwesomeIcons.spinner, 'Loading batches...');
    if (_batchesError != null)
      return _buildMessage(
        FontAwesomeIcons.triangleExclamation,
        _batchesError!,
        isError: true,
      );
    if (_batches.isEmpty)
      return _buildMessage(
        FontAwesomeIcons.boxOpen,
        'No examination batches found.',
      );
    if (_activeBatch == null)
      return _buildMessage(
        FontAwesomeIcons.fileLines,
        'Select a batch to view its results.',
      );
    if (_loadingScans)
      return _buildMessage(FontAwesomeIcons.spinner, 'Loading results...');
    if (_scansError != null)
      return _buildMessage(
        FontAwesomeIcons.triangleExclamation,
        _scansError!,
        isError: true,
      );
    if (_scans.isEmpty)
      return _buildMessage(
        FontAwesomeIcons.fileLines,
        'No results found for this batch.',
      );

    final filtered = _filteredScans;
    if (filtered.isEmpty) {
      return _buildMessage(
        FontAwesomeIcons.magnifyingGlass,
        'No results match your search or filter.',
      );
    }
    return _buildTable(filtered);
  }

  Widget _buildMessage(
    FaIconData icon,
    String message, {
    bool isError = false,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FaIcon(
            icon,
            size: 36,
            color: isError ? AppColors.warmRedOrange : AppColors.textGray,
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.body(
                size: 11.5,
                color: isError ? AppColors.warmRedOrange : AppColors.textGray,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTable(List<LocalScan> scans) {
    final batch = _activeBatch!;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
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
  }

  Widget _buildTableHeader() {
    TextStyle style = AppTextStyles.body(
      size: 9.5,
      weight: FontWeight.w800,
      color: AppColors.textGray,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          SizedBox(width: 28, child: Text('#', style: style)),
          Expanded(flex: 3, child: Text('EXAMINEE', style: style)),
          Expanded(flex: 2, child: Text('NUMBER', style: style)),
          Expanded(flex: 2, child: Text('SCORE', style: style)),
          Expanded(flex: 1, child: Text('%', style: style)),
          Expanded(flex: 2, child: Text('STATUS', style: style)),
          const SizedBox(width: 72),
        ],
      ),
    );
  }

  Widget _buildResultRow(int index, LocalScan scan, LocalBatch batch) {
    final examinee = scan.examinee;
    final result = scan.result;
    final name = examinee?.displayName ?? 'Untagged';
    final number = examinee?.examineeNumber.isNotEmpty == true
        ? examinee!.examineeNumber
        : '—';
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
            child: Text('$index', style: AppTextStyles.body(size: 11)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              name,
              style: AppTextStyles.body(
                size: 11,
                weight: FontWeight.w600,
                color: examinee == null
                    ? AppColors.textGray
                    : AppColors.textDark,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(number, style: AppTextStyles.body(size: 11)),
          ),
          Expanded(
            flex: 2,
            child: Text(score, style: AppTextStyles.body(size: 11)),
          ),
          Expanded(
            flex: 1,
            child: Text(percentage, style: AppTextStyles.body(size: 11)),
          ),
          Expanded(flex: 2, child: _statusChip(status, isGraded)),
          SizedBox(
            width: 72,
            child: TextButton(
              onPressed: () => setState(() => _viewingScan = scan),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(60, 30),
              ),
              child: Text(
                'View',
                style: AppTextStyles.body(
                  size: 10.5,
                  weight: FontWeight.w700,
                  color: AppColors.primaryGreen,
                ),
              ),
            ),
          ),
        ],
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
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isGraded ? AppColors.emerald100 : const Color(0xFFFFF3E0),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          status,
          style: AppTextStyles.body(
            size: 9.5,
            weight: FontWeight.w700,
            color: isGraded ? const Color(0xFF065F46) : const Color(0xFF92400E),
          ),
        ),
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
