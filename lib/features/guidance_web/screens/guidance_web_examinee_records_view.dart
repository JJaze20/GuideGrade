import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart';
import '../services/guidance_web_examinee_records_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_examinee_detail_view.dart';

const List<String> _statusFilterOptions = ['All', 'Active', 'Archived'];

/// Exam-type filter of the Unlinked Scans tab (`All` or a batch's exam code).
const List<String> _examTypeFilterOptions = ['All', 'QTM', 'TAT', 'AT'];

enum _RecordsTab { examinees, unlinkedScans }

/// The Guidance Council Web Console's Examinee Records page.
///
/// There is deliberately NO "Add Examinee" button and no blank-record
/// creation path anywhere in this file: every [ExamineeRecord] originates
/// from a specific scan, via one of two explicit, human-confirmed actions
/// surfaced in the "Unlinked Scans" tab —
/// "Create Examinee Record from this Scan" (a brand-new applicant) or
/// "Link to Existing Examinee" (a later exam for someone already on file).
/// Neither action ever guesses: OCR-detected names are shown as a starting
/// point only, and nothing is linked or created without an explicit click
/// and a final confirmation naming both sides of the action.
///
/// Search and the status filter both run over the already-loaded examinee
/// list in memory, mirroring [GuidanceWebResultsView]'s own convention —
/// only loading, creating, linking, or archiving/restoring issues a new
/// Supabase request.
///
/// System Admin never reaches this widget at all: it is only ever built
/// from inside `GuidanceWebHomeScreen`'s sidebar body, which itself is only
/// reachable via a route gated to `role == 'guidance_council'` (see
/// `AppRoutes._guidanceWebRoutes`) — no separate access check is needed
/// here.
class GuidanceWebExamineeRecordsView extends StatefulWidget {
  const GuidanceWebExamineeRecordsView({
    super.key,
    GuidanceWebExamineeRecordsService? service,
    GuidanceWebResultsService? resultsService,
  })  : _service = service,
        _resultsService = resultsService;

  final GuidanceWebExamineeRecordsService? _service;

  /// Used only to preview a scan's image from the Unlinked Scans queue —
  /// injectable for tests, same reasoning as
  /// `GuidanceWebExamineeDetailView._resultsService`.
  final GuidanceWebResultsService? _resultsService;

  @override
  State<GuidanceWebExamineeRecordsView> createState() =>
      _GuidanceWebExamineeRecordsViewState();
}

class _GuidanceWebExamineeRecordsViewState
    extends State<GuidanceWebExamineeRecordsView> {
  late final GuidanceWebExamineeRecordsService _service =
      widget._service ?? GuidanceWebExamineeRecordsService();
  late final GuidanceWebResultsService _resultsService =
      widget._resultsService ?? GuidanceWebResultsService();
  /// Name-crop downloads for the Unlinked Scans rows, kept so a row scrolled
  /// out and back in is not downloaded again.
  late final _NameCropCache _nameCropCache = _NameCropCache(_resultsService);
  final TextEditingController _searchController = TextEditingController();

  _RecordsTab _tab = _RecordsTab.examinees;

  bool _loadingExaminees = true;
  List<ExamineeRecord> _examinees = [];
  String? _examineesError;
  String _statusFilter = 'Active';

  bool _loadingUnlinked = true;
  List<ExamineeHistoryItem> _unlinkedScans = [];

  /// View-only filter over [_unlinkedScans] (never reloads or changes them).
  String _unlinkedExamFilter = 'All';

  /// Optional captured-date bounds (inclusive, whole days) for the Unlinked
  /// Scans tab; null = open-ended. Either may be set alone. Also view-only.
  DateTime? _unlinkedDateFrom;
  DateTime? _unlinkedDateTo;
  String? _unlinkedError;

  /// The scan id currently being deleted, or null -- guards against a
  /// double-tap firing two deletes for the same row while one is in flight.
  String? _deletingScanId;

  /// The examinee currently open in the Detail view, or null while a tab's
  /// own list is showing.
  ExamineeRecord? _viewingExaminee;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadExaminees();
    _loadUnlinkedScans();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadExaminees() async {
    setState(() {
      _loadingExaminees = true;
      _examineesError = null;
    });
    try {
      final examinees = await _service.loadExaminees();
      examinees.sort((a, b) => a.displayName.compareTo(b.displayName));
      if (!mounted) return;
      setState(() {
        _examinees = examinees;
        _loadingExaminees = false;
      });
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        _examineesError = e.message;
        _loadingExaminees = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _examineesError = 'Could not load examinee records. Please try again.';
        _loadingExaminees = false;
      });
    }
  }

  Future<void> _loadUnlinkedScans() async {
    _nameCropCache.clear();
    setState(() {
      _loadingUnlinked = true;
      _unlinkedError = null;
    });
    try {
      final scans = await _service.loadUnlinkedScans();
      if (!mounted) return;
      setState(() {
        _unlinkedScans = scans;
        _loadingUnlinked = false;
      });
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        _unlinkedError = e.message;
        _loadingUnlinked = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _unlinkedError = 'Could not load unlinked scans. Please try again.';
        _loadingUnlinked = false;
      });
    }
  }

  List<ExamineeRecord> get _filteredExaminees {
    final term = _searchController.text.trim().toLowerCase();
    return _examinees.where((e) {
      if (_statusFilter == 'Active' && !e.isActive) return false;
      if (_statusFilter == 'Archived' && !e.isArchived) return false;
      if (term.isEmpty) return true;
      return e.displayName.toLowerCase().contains(term) ||
          e.temporaryExamineeId.toLowerCase().contains(term);
    }).toList();
  }

  Future<void> _toggleArchive(ExamineeRecord examinee) async {
    final archiving = examinee.isActive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(archiving ? 'Archive Examinee' : 'Restore Examinee'),
        content: Text(
          archiving
              ? 'Archive ${examinee.displayName}? This does not delete any examination results — the record can be restored at any time.'
              : 'Restore ${examinee.displayName} to active records?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(archiving ? 'Archive' : 'Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = archiving
          ? await _service.archiveExaminee(examinee)
          : await _service.restoreExaminee(examinee);
      if (!mounted) return;
      setState(() {
        _examinees = [
          for (final e in _examinees) e.id == updated.id ? updated : e,
        ];
      });
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _createFromScan(ExamineeHistoryItem item) async {
    final created = await showDialog<ExamineeRecord>(
      context: context,
      builder: (_) => _CreateExamineeFromScanDialog(service: _service, item: item),
    );
    if (created == null || !mounted) return;
    setState(() {
      _examinees = [..._examinees, created]
        ..sort((a, b) => a.displayName.compareTo(b.displayName));
      _unlinkedScans = [
        for (final s in _unlinkedScans) if (s.scan.id != item.scan.id) s,
      ];
      // "show the new Examinee Record" -- go straight to its detail page.
      _viewingExaminee = created;
    });
  }

  Future<void> _linkToExisting(ExamineeHistoryItem item) async {
    final linked = await showDialog<bool>(
      context: context,
      builder: (_) => _LinkExistingExamineeDialog(
        service: _service,
        item: item,
        examinees: _examinees,
      ),
    );
    if (linked != true || !mounted) return;
    setState(() {
      _unlinkedScans = [
        for (final s in _unlinkedScans) if (s.scan.id != item.scan.id) s,
      ];
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Scan attached to the selected Examinee Record.')),
    );
  }

  /// "Delete" -- permanently removes [item]'s scan (and its images) from
  /// the Unlinked Scans queue. Refuses an archived historical attempt up
  /// front (mirrors [GuidanceWebExamineeDetailView]'s "Remove Link" guard,
  /// same reasoning: deleting one would permanently destroy a retake's
  /// audit trail), before even opening the confirmation dialog.
  Future<void> _deleteUnlinkedScan(ExamineeHistoryItem item) async {
    if (_deletingScanId != null) return;
    if (item.isArchivedAttempt) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Archived historical attempts are protected and cannot be deleted.'),
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete This Scan?'),
        content: const Text(
          'This scan and its associated images (original photo, rectified '
          'photo, and any handwritten name crops) will be permanently '
          'deleted. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.warmRedOrange),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingScanId = item.scan.id);
    try {
      await _service.deleteUnlinkedScan(batchId: item.batch.id, scanId: item.scan.id);
      if (!mounted) return;
      setState(() {
        _unlinkedScans = [
          for (final s in _unlinkedScans) if (s.scan.id != item.scan.id) s,
        ];
        _deletingScanId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Scan deleted.')),
      );
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        // scanWasDeleted: the database row is already permanently gone
        // (only Storage cleanup failed) -- the row must leave this list
        // even though this is the exception branch, not the success one.
        if (e.scanWasDeleted) {
          _unlinkedScans = [
            for (final s in _unlinkedScans) if (s.scan.id != item.scan.id) s,
          ];
        }
        _deletingScanId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _deletingScanId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete this scan. Please try again.')),
      );
    }
  }

  Future<void> _previewImage(ExamineeHistoryItem item) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ScanImagePreviewDialog(
        service: _resultsService,
        batch: item.batch,
        scan: item.scan,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final viewing = _viewingExaminee;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: viewing != null
          ? GuidanceWebExamineeDetailView(
              examinee: viewing,
              service: _service,
              resultsService: _resultsService,
              onBack: () => setState(() => _viewingExaminee = null),
              // A scan attached/removed from the detail page changes the
              // Unlinked Scans queue, so re-read it.
              onLinksChanged: _loadUnlinkedScans,
              onExamineeUpdated: (updated) => setState(() {
                _viewingExaminee = updated;
                _examinees = [
                  for (final e in _examinees) e.id == updated.id ? updated : e,
                ];
              }),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildTabSwitcher(),
                const SizedBox(height: 16),
                Expanded(
                  child: _tab == _RecordsTab.examinees
                      ? _buildExamineesTab()
                      : _buildUnlinkedScansTab(),
                ),
              ],
            ),
    );
  }

  Widget _buildTabSwitcher() {
    return Row(
      children: [
        _tabButton(_RecordsTab.examinees, 'Examinees'),
        const SizedBox(width: 8),
        _tabButton(
          _RecordsTab.unlinkedScans,
          'Unlinked Scans${_unlinkedScans.isEmpty ? '' : ' (${_unlinkedScans.length})'}',
        ),
      ],
    );
  }

  Widget _tabButton(_RecordsTab tab, String label) {
    final selected = _tab == tab;
    return TextButton(
      onPressed: () => setState(() => _tab = tab),
      style: TextButton.styleFrom(
        backgroundColor: selected ? AppColors.emerald100 : Colors.transparent,
        foregroundColor: selected ? AppColors.primaryGreen : AppColors.textGray,
      ),
      child: Text(label, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700)),
    );
  }

  // -------------------------------------------------------------------
  // Examinees tab
  // -------------------------------------------------------------------

  Widget _buildExamineesTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildExamineesControls(),
        const SizedBox(height: 16),
        Expanded(child: _buildExamineesBody()),
      ],
    );
  }

  Widget _buildExamineesControls() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: _buildSearchField()),
          const SizedBox(width: 16),
          Expanded(child: _buildStatusFilter()),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Search', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: _searchController,
          decoration: _fieldDecoration(
            hint: 'Search name or Temporary Examinee ID...',
          ).copyWith(prefixIcon: const Icon(Icons.search, size: 18)),
        ),
      ],
    );
  }

  Widget _buildStatusFilter() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Status', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: _statusFilter,
          decoration: _fieldDecoration(),
          items: _statusFilterOptions
              .map((s) => DropdownMenuItem(value: s, child: Text(s, style: AppTextStyles.body(size: 11))))
              .toList(),
          onChanged: (v) => setState(() => _statusFilter = v ?? 'Active'),
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

  Widget _buildExamineesBody() {
    if (_loadingExaminees) return _buildMessage(FontAwesomeIcons.spinner, 'Loading examinee records...');
    if (_examineesError != null) {
      return _buildMessage(FontAwesomeIcons.triangleExclamation, _examineesError!, isError: true);
    }
    if (_examinees.isEmpty) {
      return _buildMessage(FontAwesomeIcons.userGraduate, 'No examinee records found.');
    }
    final filtered = _filteredExaminees;
    if (filtered.isEmpty) {
      return _buildMessage(FontAwesomeIcons.magnifyingGlass, 'No examinees match your search or filter.');
    }
    return _buildExamineeTable(filtered);
  }

  Widget _buildMessage(FaIconData icon, String message, {bool isError = false}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FaIcon(icon, size: 36, color: isError ? AppColors.warmRedOrange : AppColors.textGray),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: AppTextStyles.body(size: 11.5, color: isError ? AppColors.warmRedOrange : AppColors.textGray),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExamineeTable(List<ExamineeRecord> examinees) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildExamineeTableHeader(),
          const Divider(height: 1, color: AppColors.cardBorder),
          Expanded(
            child: ListView.separated(
              itemCount: examinees.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.cardBorder),
              itemBuilder: (context, index) => _buildExamineeRow(examinees[index]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExamineeTableHeader() {
    final style = AppTextStyles.body(size: 9.5, weight: FontWeight.w800, color: AppColors.textGray);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('NAME', style: style)),
          Expanded(flex: 2, child: Text('TEMPORARY ID', style: style)),
          Expanded(flex: 1, child: Text('STATUS', style: style)),
          const SizedBox(width: 175),
        ],
      ),
    );
  }

  Widget _buildExamineeRow(ExamineeRecord examinee) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              examinee.displayName,
              style: AppTextStyles.body(size: 11, weight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(flex: 2, child: Text(examinee.temporaryExamineeId, style: AppTextStyles.body(size: 11))),
          Expanded(flex: 1, child: _statusChip(examinee)),
          SizedBox(
            width: 175,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () => _toggleArchive(examinee),
                  child: Text(
                    examinee.isActive ? 'Archive' : 'Restore',
                    style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.textGray),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                  onPressed: () => setState(() => _viewingExaminee = examinee),
                  child: Text(
                    'View',
                    style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.primaryGreen),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(ExamineeRecord examinee) {
    final isActive = examinee.isActive;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? AppColors.emerald100 : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          isActive ? 'Active' : 'Archived',
          style: AppTextStyles.body(
            size: 9.5,
            weight: FontWeight.w700,
            color: isActive ? const Color(0xFF065F46) : AppColors.textGray,
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------
  // Unlinked Scans tab
  // -------------------------------------------------------------------

  Widget _buildUnlinkedScansTab() {
    if (_loadingUnlinked) return _buildMessage(FontAwesomeIcons.spinner, 'Loading unlinked scans...');
    if (_unlinkedError != null) {
      return _buildMessage(FontAwesomeIcons.triangleExclamation, _unlinkedError!, isError: true);
    }
    if (_unlinkedScans.isEmpty) {
      return _buildMessage(FontAwesomeIcons.circleCheck, 'No unlinked scans — every scan has an Examinee Record.');
    }
    final visible = _visibleUnlinkedScans;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildUnlinkedControls(visible.length),
        const SizedBox(height: 16),
        Expanded(
          child: visible.isEmpty
              ? _buildMessage(
                  FontAwesomeIcons.magnifyingGlass,
                  (_unlinkedDateFrom == null && _unlinkedDateTo == null)
                      ? 'No unlinked $_unlinkedExamFilter scans.'
                      : 'No unlinked scans match the selected filters.',
                )
              : Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildUnlinkedTableHeader(),
                      const Divider(height: 1, color: AppColors.cardBorder),
                      Expanded(
                        child: ListView.separated(
                          itemCount: visible.length,
                          separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.cardBorder),
                          itemBuilder: (context, index) => _buildUnlinkedRow(visible[index]),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// The unlinked scans matching the Exam Type filter, in their loaded order.
  List<ExamineeHistoryItem> get _visibleUnlinkedScans {
    return [
      for (final s in _unlinkedScans)
        if ((_unlinkedExamFilter == 'All' ||
                s.examCode.trim().toUpperCase() == _unlinkedExamFilter) &&
            _capturedWithinBounds(s.scan.capturedAt))
          s,
    ];
  }

  /// Whole-day, inclusive comparison against the From / To bounds (either may
  /// be unset), on the same calendar date the table's CAPTURED column shows.
  bool _capturedWithinBounds(DateTime capturedAt) {
    final day = DateTime(capturedAt.year, capturedAt.month, capturedAt.day);
    final from = _unlinkedDateFrom;
    final to = _unlinkedDateTo;
    if (from != null && day.isBefore(from)) return false;
    if (to != null && day.isAfter(to)) return false;
    return true;
  }

  /// A picked day for one bound; if that would leave From after To, the other
  /// bound follows so the range is never inverted.
  void _setUnlinkedDate({required bool isFrom, required DateTime picked}) {
    final day = DateUtils.dateOnly(picked);
    setState(() {
      if (isFrom) {
        _unlinkedDateFrom = day;
        final to = _unlinkedDateTo;
        if (to != null && day.isAfter(to)) _unlinkedDateTo = day;
      } else {
        _unlinkedDateTo = day;
        final from = _unlinkedDateFrom;
        if (from != null && day.isBefore(from)) _unlinkedDateFrom = day;
      }
    });
  }

  /// "Captured Date (MM/DD/YYYY)": a From and a To field, each with a calendar
  /// icon that opens a month calendar right under the field.
  Widget _buildUnlinkedDateFilter() {
    final hasDate = _unlinkedDateFrom != null || _unlinkedDateTo != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Captured Date (MM/DD/YYYY)',
          style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _dateBoundField(
              fieldKey: const Key('unlinkedDateFrom'),
              hint: 'From',
              value: _unlinkedDateFrom,
              onPicked: (d) => _setUnlinkedDate(isFrom: true, picked: d),
            ),
            const SizedBox(width: 12),
            _dateBoundField(
              fieldKey: const Key('unlinkedDateTo'),
              hint: 'to',
              value: _unlinkedDateTo,
              onPicked: (d) => _setUnlinkedDate(isFrom: false, picked: d),
            ),
            if (hasDate)
              IconButton(
                key: const Key('unlinkedDateClear'),
                tooltip: 'Clear date filter',
                onPressed: () => setState(() {
                  _unlinkedDateFrom = null;
                  _unlinkedDateTo = null;
                }),
                icon: const Icon(Icons.close, size: 16),
              ),
          ],
        ),
      ],
    );
  }

  Widget _dateBoundField({
    required Key fieldKey,
    required String hint,
    required DateTime? value,
    required ValueChanged<DateTime> onPicked,
  }) {
    return _DatePopoverField(
      fieldKey: fieldKey,
      width: 170,
      text: value == null ? hint : _formatNumericDate(value),
      isPlaceholder: value == null,
      decoration: _fieldDecoration().copyWith(
        suffixIcon: const Icon(Icons.calendar_today, size: 16),
      ),
      selected: value,
      onPicked: onPicked,
    );
  }

  String _formatNumericDate(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}/${d.year}';

  Widget _buildUnlinkedControls(int shown) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 240,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Exam Type', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  key: const Key('unlinkedExamTypeFilter'),
                  initialValue: _unlinkedExamFilter,
                  decoration: _fieldDecoration(),
                  items: _examTypeFilterOptions
                      .map((t) => DropdownMenuItem(value: t, child: Text(t, style: AppTextStyles.body(size: 11))))
                      .toList(),
                  onChanged: (v) => setState(() => _unlinkedExamFilter = v ?? 'All'),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _buildUnlinkedDateFilter(),
          const Spacer(),
          Text(
            'Showing $shown of ${_unlinkedScans.length}',
            key: const Key('unlinkedShowingCount'),
            style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
          ),
        ],
      ),
    );
  }

  /// Width of the trailing action buttons in BOTH the header and every row, so
  /// the flexible EXAM / BATCH / CAPTURED columns get identical widths (and
  /// therefore line up) in the two. Just wide enough for the three buttons;
  /// the rest of the row goes to the name crops. The buttons are wrapped in a
  /// scale-down FittedBox, so a narrower window shrinks them slightly instead
  /// of overflowing.
  static const double _unlinkedActionsWidth = 460;

  /// The NAME CROP column (between OCR NAME and EXAM): its share of the row's
  /// flexible width, and the gap that separates it from the OCR name. Header
  /// and rows use the same two values so the column lines up.
  static const int _nameCropFlex = 9;
  static const double _nameCropGap = 8;

  Widget _buildUnlinkedTableHeader() {
    final style = AppTextStyles.body(size: 9.5, weight: FontWeight.w800, color: AppColors.textGray);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('OCR NAME', style: style)),
          Expanded(
            flex: _nameCropFlex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _nameCropGap),
              child: Text('NAME CROP', style: style),
            ),
          ),
          Expanded(flex: 1, child: Text('EXAM', style: style)),
          Expanded(flex: 2, child: Text('BATCH', style: style)),
          Expanded(flex: 2, child: Text('CAPTURED', style: style)),
          const SizedBox(width: _unlinkedActionsWidth),
        ],
      ),
    );
  }

  Widget _buildUnlinkedRow(ExamineeHistoryItem item) {
    final name = item.scan.examinee?.displayName;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              (name == null || name.isEmpty) ? 'Unnamed' : name,
              style: AppTextStyles.body(
                size: 11,
                weight: FontWeight.w600,
                color: (name == null || name.isEmpty) ? AppColors.textGray : AppColors.textDark,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: _nameCropFlex,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: _nameCropGap),
              child: _NameCropStrip(
                // One strip per scan, so its three downloads start only when
                // this row is built (ListView builds rows lazily) and never
                // restart for a different scan reusing the element.
                key: ValueKey('nameCrop_${item.batch.id}_${item.scan.id}'),
                cache: _nameCropCache,
                batchId: item.batch.id,
                scanId: item.scan.id,
              ),
            ),
          ),
          Expanded(flex: 1, child: Text(item.examCode, style: AppTextStyles.body(size: 11))),
          Expanded(flex: 2, child: Text(item.batch.batchCode, style: AppTextStyles.body(size: 11))),
          Expanded(flex: 2, child: Text(_formatDate(item.scan.capturedAt), style: AppTextStyles.body(size: 11))),
          SizedBox(
            width: _unlinkedActionsWidth,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
                  onPressed: () => _previewImage(item),
                  child: Text('View Image', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.textGray)),
                ),
                TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
                  onPressed: () => _linkToExisting(item),
                  child: Text('Link to Existing', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.textGray)),
                ),
                TextButton(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
                  onPressed: () => _createFromScan(item),
                  child: Text('Confirm and Create Examinee', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.primaryGreen)),
                ),
                if (!item.isArchivedAttempt)
                  TextButton(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
                    onPressed: _deletingScanId != null ? null : () => _deleteUnlinkedScan(item),
                    child: Text('Delete', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.warmRedOrange)),
                  ),
              ],
            ),
            ),
          ),
        ],
      ),
    );
  }
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// Workflow 1 — "Create Examinee Record from this Scan." Pre-filled from
/// [item].scan's own confirmed tag (never a blank form); the name fields
/// are freely editable and NOT required, since OCR failure must never
/// block creating the record — the Temporary Examinee ID exists
/// independently of whether a name was ever captured.
class _CreateExamineeFromScanDialog extends StatefulWidget {
  const _CreateExamineeFromScanDialog({required this.service, required this.item});

  final GuidanceWebExamineeRecordsService service;
  final ExamineeHistoryItem item;

  @override
  State<_CreateExamineeFromScanDialog> createState() => _CreateExamineeFromScanDialogState();
}

class _CreateExamineeFromScanDialogState extends State<_CreateExamineeFromScanDialog> {
  late final TextEditingController _firstName =
      TextEditingController(text: widget.item.scan.examinee?.firstName ?? '');
  late final TextEditingController _middleName =
      TextEditingController(text: widget.item.scan.examinee?.middleName ?? '');
  late final TextEditingController _lastName =
      TextEditingController(text: widget.item.scan.examinee?.lastName ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _firstName.dispose();
    _middleName.dispose();
    _lastName.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await widget.service.createExamineeFromScan(
        batchId: widget.item.batch.id,
        scan: widget.item.scan,
        firstName: _firstName.text.trim(),
        middleName: _middleName.text.trim().isEmpty ? null : _middleName.text.trim(),
        lastName: _lastName.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, created);
    } on GuidanceWebExamineeRecordsException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not create this Examinee Record. Please try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Examinee Record from this Scan'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.item.examCode} — Batch ${widget.item.batch.batchCode} — ${_formatDate(widget.item.scan.capturedAt)}',
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
            const SizedBox(height: 12),
            Text(
              'A new, permanent Temporary Examinee ID will be generated by the database. '
              'Correct the name below if OCR read it wrong or left it blank.',
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _firstName,
              decoration: const InputDecoration(labelText: 'First name'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _middleName,
              decoration: const InputDecoration(labelText: 'Middle name (optional)'),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _lastName,
              decoration: const InputDecoration(labelText: 'Last name'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Creating...' : 'Create Examinee Record'),
        ),
      ],
    );
  }
}

/// Workflow 3 — "Link to Existing Examinee." Searches the ALREADY-LOADED
/// examinee list in memory (no new request per keystroke); the OCR name on
/// [item], if any, only pre-fills the search box as a starting point — it
/// never pre-selects or auto-confirms a candidate. Guidance Council must
/// explicitly click a row, then explicitly confirm, before
/// `scans.examinee_id` is ever touched.
class _LinkExistingExamineeDialog extends StatefulWidget {
  const _LinkExistingExamineeDialog({
    required this.service,
    required this.item,
    required this.examinees,
  });

  final GuidanceWebExamineeRecordsService service;
  final ExamineeHistoryItem item;
  final List<ExamineeRecord> examinees;

  @override
  State<_LinkExistingExamineeDialog> createState() => _LinkExistingExamineeDialogState();
}

class _LinkExistingExamineeDialogState extends State<_LinkExistingExamineeDialog> {
  late final TextEditingController _search =
      TextEditingController(text: widget.item.scan.examinee?.displayName ?? '');
  ExamineeRecord? _selected;
  bool _linking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Only ACTIVE examinees can receive a scan; an archived one must be
  /// restored first, so it is never offered here. (The page's own
  /// All/Active/Archived filter is separate and unaffected.)
  List<ExamineeRecord> get _candidates {
    final term = _search.text.trim().toLowerCase();
    final active = widget.examinees.where((e) => e.isActive);
    if (term.isEmpty) return active.toList();
    return active
        .where((e) =>
            e.displayName.toLowerCase().contains(term) ||
            e.temporaryExamineeId.toLowerCase().contains(term))
        .toList();
  }

  Future<void> _confirmAndLink(ExamineeRecord examinee) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Attach Scan to Examinee Record'),
        content: Text(
          'Attach this ${widget.item.examCode} scan from Batch ${widget.item.batch.batchCode} '
          'to Examinee Record ${examinee.temporaryExamineeId} (${examinee.displayName})?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm Attach')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _linking = true;
      _error = null;
      _selected = examinee;
    });
    try {
      await widget.service.linkScanToExaminee(
        batchId: widget.item.batch.id,
        scan: widget.item.scan,
        examinee: examinee,
        examCode: widget.item.examCode,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on GuidanceWebExamineeRecordsException catch (e) {
      setState(() {
        _error = e.message;
        _linking = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not attach this scan. Please try again.';
        _linking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final candidates = _candidates;
    return AlertDialog(
      title: const Text('Link to Existing Examinee'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.item.examCode} — Batch ${widget.item.batch.batchCode} — ${_formatDate(widget.item.scan.capturedAt)}',
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _search,
              decoration: const InputDecoration(
                labelText: 'Search name or Temporary Examinee ID',
                prefixIcon: Icon(Icons.search, size: 18),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Only active examinees can be linked to a scan. Restore an archived examinee first.',
              key: const Key('linkPickerActiveOnlyHint'),
              style: AppTextStyles.body(size: 10, color: AppColors.textGray),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: candidates.isEmpty
                  ? Center(
                      child: Text('No matching Examinee Records.', style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
                    )
                  : ListView.separated(
                      itemCount: candidates.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.cardBorder),
                      itemBuilder: (context, index) {
                        final e = candidates[index];
                        return ListTile(
                          dense: true,
                          title: Text(e.displayName, style: AppTextStyles.body(size: 12, weight: FontWeight.w600)),
                          subtitle: Text(e.temporaryExamineeId, style: AppTextStyles.body(size: 10.5, color: AppColors.textGray)),
                          trailing: (_linking && _selected?.id == e.id)
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : null,
                          onTap: _linking ? null : () => _confirmAndLink(e),
                        );
                      },
                    ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _linking ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// A plain photo preview for a scan in the Unlinked Scans queue — never the
/// graded overlay [GuidanceWebResultDetailView] draws (that requires a
/// scored/answer-keyed context an unlinked, possibly-ungraded scan may not
/// have). Rectified image preferred, original as a fallback, matching
/// [GuidanceWebResultDetailView]'s own convention.
class _ScanImagePreviewDialog extends StatefulWidget {
  const _ScanImagePreviewDialog({required this.service, required this.batch, required this.scan});

  final GuidanceWebResultsService service;
  final LocalBatch batch;
  final LocalScan scan;

  @override
  State<_ScanImagePreviewDialog> createState() => _ScanImagePreviewDialogState();
}

class _ScanImagePreviewDialogState extends State<_ScanImagePreviewDialog> {
  bool _loading = true;
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      Uint8List? bytes;
      if (widget.scan.rectifiedImageFileName != null) {
        bytes = await widget.service.loadScanImage(widget.batch.id, widget.scan.id, rectified: true);
      }
      bytes ??= await widget.service.loadScanImage(widget.batch.id, widget.scan.id, rectified: false);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _loading = false;
      });
    } on GuidanceWebResultsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the scan image.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 500,
        height: 500,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ),
              Expanded(
                child: Center(
                  child: _loading
                      ? const CircularProgressIndicator()
                      : _error != null
                          ? Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange))
                          : _bytes == null
                              ? Text('No image available.', style: AppTextStyles.body(size: 11, color: AppColors.textGray))
                              : Column(
                                  // Stretch so the click target is the whole
                                  // preview box, even before the image decodes.
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.zoomIn,
                                        child: GestureDetector(
                                          key: const Key('scanPreviewImage'),
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => showDialog<void>(
                                            context: context,
                                            builder: (_) => _ZoomableImageViewer(bytes: _bytes!),
                                          ),
                                          child: Image.memory(_bytes!, fit: BoxFit.contain),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Click the image to zoom',
                                      textAlign: TextAlign.center,
                                      style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                                    ),
                                  ],
                                ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen, zoomable view of a scan photo (opened by clicking the
/// preview image). Pinch / scroll-wheel / drag to zoom and pan via
/// [InteractiveViewer]; the close button or Escape dismisses it. Read-only —
/// it never changes the scan.
class _ZoomableImageViewer extends StatelessWidget {
  const _ZoomableImageViewer({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              key: const Key('zoomableScanImage'),
              minScale: 1,
              maxScale: 8,
              child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

/// A read-only date field with a calendar icon. Tapping it opens a month
/// calendar in a popover right under the field (like a date-range filter on a
/// search form); picking a day fills the field and closes the popover, and
/// tapping anywhere outside closes it without changing anything.
class _DatePopoverField extends StatefulWidget {
  const _DatePopoverField({
    required this.fieldKey,
    required this.width,
    required this.text,
    required this.isPlaceholder,
    required this.decoration,
    required this.selected,
    required this.onPicked,
  });

  final Key fieldKey;
  final double width;
  final String text;
  final bool isPlaceholder;
  final InputDecoration decoration;
  final DateTime? selected;
  final ValueChanged<DateTime> onPicked;

  @override
  State<_DatePopoverField> createState() => _DatePopoverFieldState();
}

class _DatePopoverFieldState extends State<_DatePopoverField> {
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  Widget build(BuildContext context) {
    // overlayChildLayoutBuilder (not a CompositedTransformFollower): the
    // calendar's own Tooltips (Previous/Next month) compute paint transforms
    // and assert if a follower layer is among their ancestors.
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: _buildPopover,
      child: SizedBox(
        width: widget.width,
        child: InkWell(
          key: widget.fieldKey,
          borderRadius: BorderRadius.circular(10),
          onTap: _portal.toggle,
          child: InputDecorator(
            decoration: widget.decoration,
            child: Text(
              widget.text,
              style: AppTextStyles.body(
                size: 11,
                color: widget.isPlaceholder ? AppColors.textGray : AppColors.textDark,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPopover(BuildContext context, OverlayChildLayoutInfo info) {
    final firstDate = DateTime(2020);
    final lastDate = DateTime(DateTime.now().year + 1, 12, 31);
    var initial = widget.selected ?? DateTime.now();
    if (initial.isAfter(lastDate)) initial = lastDate;
    if (initial.isBefore(firstDate)) initial = firstDate;
    const popoverWidth = 320.0;
    const popoverHeight = 340.0;
    // The field's box in overlay coordinates; the calendar goes right below
    // it (or above it when there is no room), kept inside the overlay.
    final field = MatrixUtils.transformRect(
      info.childPaintTransform,
      Offset.zero & info.childSize,
    );
    final maxLeft = (info.overlaySize.width - popoverWidth).clamp(0.0, double.infinity);
    final left = field.left.clamp(0.0, maxLeft);
    var top = field.bottom + 6;
    if (top + popoverHeight > info.overlaySize.height) {
      top = (field.top - popoverHeight - 6).clamp(0.0, double.infinity);
    }
    return Stack(
      children: [
        // Tap outside the calendar to dismiss it.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _portal.hide,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          width: popoverWidth,
          height: popoverHeight,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: Colors.white,
            child: CalendarDatePicker(
              initialDate: initial,
              firstDate: firstDate,
              lastDate: lastDate,
              onDateChanged: (d) {
                widget.onPicked(d);
                _portal.hide();
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// De-duplicates the name-crop downloads of the Unlinked Scans table.
///
/// One download per scan and crop variant, started the first time a row asks
/// for it and answered from memory afterwards. A failed download is NOT
/// remembered, so the row's retry (or a reload of the list) asks again.
/// Reads only through [GuidanceWebResultsService.loadNameCropImage] -- the
/// existing authenticated Storage read; nothing is written anywhere.
class _NameCropCache {
  _NameCropCache(this._service);

  final GuidanceWebResultsService _service;
  final Map<String, Future<Uint8List?>> _downloads = {};

  Future<Uint8List?> load(String batchId, String scanId, String variant) {
    final key = '$batchId/$scanId/$variant';
    return _downloads.putIfAbsent(key, () {
      final download = _service.loadNameCropImage(
        batchId,
        scanId,
        variant: variant,
      );
      unawaited(
        download.then(
          (_) {},
          onError: (Object _) {
            _downloads.remove(key);
          },
        ),
      );
      return download;
    });
  }

  void clear() => _downloads.clear();
}

/// The three handwritten-name crops (Last / First / MI) of one unlinked scan,
/// shown side by side and large enough to read in the table, so the OCR name
/// can be compared with the handwriting at a glance. Clicking a loaded crop
/// opens just that crop enlarged ([_NameCropZoomDialog]).
///
/// Each crop loads on its own: a slow, missing or failed crop only affects its
/// own box, never the row's other cells or the page.
class _NameCropStrip extends StatefulWidget {
  const _NameCropStrip({
    super.key,
    required this.cache,
    required this.batchId,
    required this.scanId,
  });

  final _NameCropCache cache;
  final String batchId;
  final String scanId;

  @override
  State<_NameCropStrip> createState() => _NameCropStripState();
}

class _NameCropStripState extends State<_NameCropStrip> {
  /// Variant, short label under the box, title in the enlarged view, and the
  /// share of the strip's width. Last / First names are long, wide
  /// handwriting strips; the middle initial needs far less room.
  static const List<(String variant, String label, String title, int flex)>
  _crops = [
    ('name_last', 'Last', 'Last Name', 5),
    ('name_first', 'First', 'First Name', 5),
    ('name_mi', 'MI', 'Middle Initial', 3),
  ];

  static const double _gap = 6;

  late final Map<String, Future<Uint8List?>> _futures = {
    for (final crop in _crops) crop.$1: _start(crop.$1),
  };

  Future<Uint8List?> _start(String variant) =>
      widget.cache.load(widget.batchId, widget.scanId, variant);

  void _retry(String variant) {
    setState(() {
      _futures[variant] = _start(variant);
    });
  }

  void _zoom(String title, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (_) => _NameCropZoomDialog(title: title, bytes: bytes),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Box height follows the width the strip actually gets, so the crops
        // grow with the window but stay within a sensible range.
        final totalFlex = _crops.fold<int>(0, (sum, c) => sum + c.$4);
        final unit =
            (constraints.maxWidth - _gap * (_crops.length - 1)) / totalFlex;
        final boxHeight = (unit * _crops.first.$4 * 0.3).clamp(40.0, 72.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < _crops.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(
                flex: _crops[i].$4,
                child: _buildCrop(
                  _crops[i].$1,
                  _crops[i].$2,
                  _crops[i].$3,
                  boxHeight,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildCrop(
    String variant,
    String label,
    String title,
    double boxHeight,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: boxHeight,
          child: FutureBuilder<Uint8List?>(
            future: _futures[variant],
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return _box(
                  key: Key('nameCropLoading_$variant'),
                  child: const SizedBox.shrink(),
                );
              }
              if (snapshot.hasError) {
                return Tooltip(
                  message: 'Could not load this crop. Click to retry.',
                  child: InkWell(
                    onTap: () => _retry(variant),
                    child: _box(
                      key: Key('nameCropError_$variant'),
                      child: const Icon(
                        Icons.refresh,
                        size: 14,
                        color: AppColors.textGray,
                      ),
                    ),
                  ),
                );
              }
              final bytes = snapshot.data;
              if (bytes == null) return _placeholder(variant);
              return _ClickableCrop(
                variant: variant,
                tooltip: 'Click to enlarge the $title crop',
                onTap: () => _zoom(title, bytes),
                child: _box(
                  key: Key('nameCropImage_$variant'),
                  white: true,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (_, _, _) => _placeholder(variant),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          textAlign: TextAlign.center,
          style: AppTextStyles.body(size: 9.5, color: AppColors.textGray),
        ),
      ],
    );
  }

  /// "N/A": the crop was never uploaded (older scan, cropping failed, or the
  /// scan came from a phone that has not synced it) -- a normal state.
  Widget _placeholder(String variant) => _box(
    key: Key('nameCropMissing_$variant'),
    child: Text(
      'N/A',
      style: AppTextStyles.body(size: 10, color: AppColors.textGray),
    ),
  );

  Widget _box({Key? key, required Widget child, bool white = false}) {
    return Container(
      key: key,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: white ? Colors.white : AppColors.lightBg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: child,
    );
  }
}

/// Makes a loaded crop obviously clickable: a pointer cursor, a highlighted
/// border while the mouse is over it, and a tooltip.
class _ClickableCrop extends StatefulWidget {
  const _ClickableCrop({
    required this.variant,
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String variant;
  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  @override
  State<_ClickableCrop> createState() => _ClickableCropState();
}

class _ClickableCropState extends State<_ClickableCrop> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: Key('nameCropTap_${widget.variant}'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_hover)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      key: Key('nameCropHover_${widget.variant}'),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: AppColors.primaryGreen,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One name crop enlarged in a modal: a clear title, a close button (Escape or
/// a click outside also close it), and the crop shown as large as the dialog
/// allows with scroll / pinch zoom for a closer look at the handwriting.
class _NameCropZoomDialog extends StatelessWidget {
  const _NameCropZoomDialog({required this.title, required this.bytes});

  final String title;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '$title — handwritten crop',
                      key: const Key('nameCropZoomTitle'),
                      style: AppTextStyles.body(
                        size: 14,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('nameCropZoomClose'),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                height: 320,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                // InteractiveViewer hands its child unbounded space, so the
                // image is sized to the viewport explicitly: it fills the width
                // (or the height, for a squarer crop) instead of showing at
                // its tiny natural size.
                child: LayoutBuilder(
                  builder: (context, box) => InteractiveViewer(
                    minScale: 1,
                    maxScale: 6,
                    child: SizedBox(
                      width: box.maxWidth,
                      height: box.maxHeight,
                      child: Image.memory(
                        bytes,
                        key: const Key('nameCropZoomImage'),
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Scroll or pinch to zoom in further.',
                style: AppTextStyles.body(size: 10, color: AppColors.textGray),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
