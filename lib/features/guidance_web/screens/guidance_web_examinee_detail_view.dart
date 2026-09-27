import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../models/exam_retake_request.dart';
import '../../../models/examinee_record.dart';
import '../../../models/local_batch.dart';
import '../services/guidance_web_examinee_records_service.dart';
import '../services/guidance_web_results_service.dart';
import 'guidance_web_result_detail_view.dart';

/// The checklist/history exam types, in the order the spec's own example
/// lists them — `('examCode', 'display label')`.
const List<(String, String)> _examTypes = [
  ('QTM', 'QTM'),
  ('TAT', 'TAT'),
  ('AT', 'Admission Test'),
];

/// The Guidance Council Web Console's Examinee Record detail page: the
/// canonical profile (name + Temporary Examinee ID only — no Official
/// Student ID, Birth Date, or Last Attended School, none of which have an
/// established source yet), which exams the applicant has taken, and their
/// full examination history.
///
/// Selecting a history entry reuses the EXACT existing
/// [GuidanceWebResultDetailView] widget (never a second, independent
/// result-detail implementation) — the score/percentage/status it shows
/// come straight from the same [LocalScan]/[LocalBatch] this page already
/// loaded, never recalculated here.
///
/// "Attach a Scan" (Workflow 4) reuses the exact same
/// [GuidanceWebExamineeRecordsService.linkScanToExaminee] call the
/// scan-first "Link to Existing Examinee" workflow uses — there is only
/// ever one linking mechanism in this feature, approached from either
/// direction.
class GuidanceWebExamineeDetailView extends StatefulWidget {
  const GuidanceWebExamineeDetailView({
    super.key,
    required this.examinee,
    required this.service,
    required this.onBack,
    required this.onExamineeUpdated,
    this.onLinksChanged,
    GuidanceWebResultsService? resultsService,
  }) : _resultsService = resultsService;

  final ExamineeRecord examinee;
  final GuidanceWebExamineeRecordsService service;
  final VoidCallback onBack;

  /// Called whenever this page saves an edit or an archive/restore, so the
  /// caller's own examinee list stays in sync without a full reload.
  final ValueChanged<ExamineeRecord> onExamineeUpdated;

  /// Called after a scan is attached to or removed from this examinee, so the
  /// caller can refresh its Unlinked Scans queue.
  final VoidCallback? onLinksChanged;

  /// Injectable for tests — see [_GuidanceWebExamineeDetailViewState._resultsService].
  final GuidanceWebResultsService? _resultsService;

  @override
  State<GuidanceWebExamineeDetailView> createState() => _GuidanceWebExamineeDetailViewState();
}

class _GuidanceWebExamineeDetailViewState extends State<GuidanceWebExamineeDetailView> {
  late ExamineeRecord _examinee = widget.examinee;
  bool _loadingHistory = true;
  List<ExamineeHistoryItem> _history = [];
  String? _historyError;

  /// The Results service instance handed to a reused
  /// [GuidanceWebResultDetailView]. `late` so the real (Supabase-backed)
  /// default is never constructed unless a history item is actually opened
  /// — exactly like [GuidanceWebResultsView] does for its own rows, and
  /// critically, never touched at all when [widget]._resultsService is
  /// injected (e.g. in tests, where no Supabase instance exists).
  late final GuidanceWebResultsService _resultsService =
      widget._resultsService ?? GuidanceWebResultsService();

  ExamineeHistoryItem? _viewingHistoryItem;

  /// Scan currently being unlinked — blocks a double-click.
  String? _removingScanId;

  /// Applicant Retake Management -- the latest retake requests for TAT and
  /// AT (QTM never has one), loaded alongside history so building a row
  /// never needs its own network read. Empty until [_loadHistory] finishes.
  Map<String, List<ExamRetakeRequest>> _retakeRequests = const {};

  /// A request id currently being reviewed -- blocks a double action.
  String? _reviewingRequestId;

  /// A request id whose attempt is currently being archived.
  String? _archivingRequestId;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _loadingHistory = true;
      _historyError = null;
    });
    try {
      final history = await widget.service.loadHistoryFor(_examinee);
      final tatRequests = await widget.service.retakeRequestsFor(
        examineeId: _examinee.id,
        examCode: 'TAT',
      );
      final atRequests = await widget.service.retakeRequestsFor(
        examineeId: _examinee.id,
        examCode: 'AT',
      );
      if (!mounted) return;
      setState(() {
        _history = history;
        _retakeRequests = {'TAT': tatRequests, 'AT': atRequests};
        _loadingHistory = false;
      });
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        _historyError = e.message;
        _loadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _historyError = 'Could not load examination history. Please try again.';
        _loadingHistory = false;
      });
    }
  }

  Future<void> _openEditDialog() async {
    final updated = await showDialog<ExamineeRecord>(
      context: context,
      builder: (_) => _ExamineeNameEditDialog(service: widget.service, examinee: _examinee),
    );
    if (updated == null || !mounted) return;
    setState(() => _examinee = updated);
    widget.onExamineeUpdated(updated);
  }

  Future<void> _toggleArchive() async {
    final archiving = _examinee.isActive;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(archiving ? 'Archive Examinee' : 'Restore Examinee'),
        content: Text(
          archiving
              ? 'Archive ${_examinee.displayName}? This does not delete any examination results — the record can be restored at any time.'
              : 'Restore ${_examinee.displayName} to active records?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(archiving ? 'Archive' : 'Restore')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final updated = archiving
          ? await widget.service.archiveExaminee(_examinee)
          : await widget.service.restoreExaminee(_examinee);
      if (!mounted) return;
      setState(() => _examinee = updated);
      widget.onExamineeUpdated(updated);
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _openAttachScanDialog() async {
    // Defensive: the button is disabled while archived, and the service
    // refuses too; this just keeps a stale tap from opening the dialog.
    if (_examinee.isArchived) return;
    final attached = await showDialog<bool>(
      context: context,
      builder: (_) => _AttachScanDialog(service: widget.service, examinee: _examinee),
    );
    if (attached == true) {
      _loadHistory();
      widget.onLinksChanged?.call();
    }
  }

  /// "Remove Link" — confirmation first, then ONLY detaches the scan from
  /// this examinee (`scans.examinee_id` -> NULL). Nothing is deleted; the
  /// scan returns to Unlinked Scans and is never relinked automatically.
  Future<void> _removeLink(ExamineeHistoryItem item) async {
    if (_removingScanId != null) return;
    if (item.isArchivedAttempt) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Archived historical attempts are protected and cannot be unlinked.'),
        ),
      );
      return;
    }
    final code = item.examCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove $code Link?'),
        content: Text(
          "This will remove the $code examination from this examinee's records.\n\n"
          'The examination and its data will not be deleted. It will become an '
          'unlinked examination and can be linked to the correct examinee later.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove Link')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _removingScanId = item.scan.id);
    try {
      await widget.service.removeExamLink(
        batchId: item.batch.id,
        scanId: item.scan.id,
        examineeId: _examinee.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$code link removed. The examination is now unlinked.')),
      );
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not remove this link. Please try again.')),
      );
    }
    if (!mounted) return;
    setState(() => _removingScanId = null);
    // Success or conflict alike, re-read the truth from the database.
    _loadHistory();
    widget.onLinksChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final viewing = _viewingHistoryItem;
    if (viewing != null) {
      return GuidanceWebResultDetailView(
        scan: viewing.scan,
        batch: viewing.batch,
        linkedExaminee: _examinee,
        service: _resultsService,
        onBack: () => setState(() => _viewingHistoryItem = null),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back, size: 16),
          label: const Text('Back to Examinee Records'),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildRecordCard(),
                const SizedBox(height: 16),
                _buildTestsTakenCard(),
                const SizedBox(height: 16),
                _buildHistoryCard(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _card({required String title, required Widget child, List<Widget>? actions}) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: AppTextStyles.heading(size: 13))),
              ...?actions,
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _buildRecordCard() {
    return _card(
      title: 'Examinee Record',
      actions: [
        TextButton(onPressed: _openEditDialog, child: const Text('Edit')),
        TextButton(
          key: const Key('attachScanButton'),
          // Archived examinees cannot receive new scans until restored.
          onPressed: _examinee.isActive ? _openAttachScanDialog : null,
          child: const Text('Attach a Scan'),
        ),
        TextButton(
          onPressed: _toggleArchive,
          child: Text(_examinee.isActive ? 'Archive' : 'Restore'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 32,
            runSpacing: 16,
            children: [
              _infoField('Name', _examinee.displayName),
              _infoField('Temporary Examinee ID', _examinee.temporaryExamineeId),
              _infoField('Status', _examinee.isActive ? 'Active' : 'Archived'),
            ],
          ),
          if (_examinee.isArchived) ...[
            const SizedBox(height: 12),
            Text(
              archivedExamineeLinkMessage,
              key: const Key('archivedAttachHint'),
              style: AppTextStyles.body(size: 11, color: AppColors.textGray),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoField(String label, String value) {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.body(size: 10, weight: FontWeight.w700, color: AppColors.textGray)),
          const SizedBox(height: 4),
          Text(value, style: AppTextStyles.body(size: 12.5)),
        ],
      ),
    );
  }

  Widget _buildTestsTakenCard() {
    final takenCodes = _history.map((h) => h.examCode).toSet();
    return _card(
      title: 'Tests Taken',
      child: _loadingHistory
          ? Text('Loading...', style: AppTextStyles.body(size: 11, color: AppColors.textGray))
          : Row(
              children: [
                for (final (code, label) in _examTypes) ...[
                  Icon(
                    takenCodes.contains(code) ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 16,
                    color: takenCodes.contains(code) ? AppColors.primaryGreen : AppColors.textGray,
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w600)),
                  const SizedBox(width: 20),
                ],
              ],
            ),
    );
  }

  Widget _buildHistoryCard() {
    return _card(
      title: 'Examination History',
      child: _loadingHistory
          ? Text('Loading...', style: AppTextStyles.body(size: 11, color: AppColors.textGray))
          : _historyError != null
              ? Text(_historyError!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange))
              : _history.isEmpty
                  ? Text('No examinations recorded yet.', style: AppTextStyles.body(size: 11, color: AppColors.textGray))
                  : Column(
                      children: [
                        for (var i = 0; i < _history.length; i++) ...[
                          if (i > 0) const Divider(height: 1, color: AppColors.cardBorder),
                          _buildHistoryRow(_history[i]),
                        ],
                      ],
                    ),
    );
  }

  Widget _buildHistoryRow(ExamineeHistoryItem item) {
    final result = item.result;
    final score = result == null ? '—' : '${result.rawScore} / ${_denominatorFor(item.batch, result)}';
    final percentage = result == null ? '—' : '${result.percentage.toStringAsFixed(1)}%';
    final status = result?.status ?? 'Ungraded';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: Row(
                  children: [
                    Text(item.examCode, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    _attemptBadge(item),
                  ],
                ),
              ),
              Expanded(flex: 2, child: Text(item.batch.batchCode, style: AppTextStyles.body(size: 11))),
              Expanded(flex: 2, child: Text('$score ($percentage)', style: AppTextStyles.body(size: 11))),
              Expanded(flex: 2, child: Text(_formatDate(item.scan.capturedAt), style: AppTextStyles.body(size: 11))),
              Expanded(flex: 1, child: Text(status, style: AppTextStyles.body(size: 11))),
              TextButton(
                onPressed: () => setState(() => _viewingHistoryItem = item),
                child: Text('View', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.primaryGreen)),
              ),
              if (!item.isArchivedAttempt)
                TextButton(
                  onPressed: _removingScanId != null ? null : () => _removeLink(item),
                  child: Text('Remove Link', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.warmRedOrange)),
                ),
            ],
          ),
          ..._retakeArea(item),
        ],
      ),
    );
  }

  /// "Attempt N" plus an Active/Archived chip. Shown only for TAT/AT --
  /// QTM can never have more than one attempt, so it needs no badge at all.
  Widget _attemptBadge(ExamineeHistoryItem item) {
    if (item.examCode == 'QTM') return const SizedBox.shrink();
    final archived = item.isArchivedAttempt;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: archived ? const Color(0xFFF3F4F6) : AppColors.emerald100,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        'Attempt ${item.attemptNo} • ${archived ? 'Archived' : 'Active'}',
        style: AppTextStyles.body(
          size: 9.5,
          weight: FontWeight.w700,
          color: archived ? AppColors.textGray : const Color(0xFF065F46),
        ),
      ),
    );
  }

  /// The retake workflow area under one Attempt 1 history row for TAT/AT --
  /// the archive reason (once archived), a pending review, the approved-
  /// but-not-yet-eligible date, "Archive Attempt", "Request Retake", or (on
  /// Attempt 2) the max-attempts notice. Empty for QTM -- it never has a
  /// retake at all -- and for any attempt beyond the first two.
  List<Widget> _retakeArea(ExamineeHistoryItem item) {
    if (item.examCode == 'QTM') return const [];
    if (item.attemptNo >= 2) {
      return [
        Padding(
          key: Key('maxAttemptsNotice_${item.scan.id}'),
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Maximum number of ${item.examCode} attempts has been reached.',
            style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
          ),
        ),
      ];
    }

    final widgets = <Widget>[];
    final archiveReason = item.archiveReason ?? '';
    if (item.isArchivedAttempt && archiveReason.isNotEmpty) {
      widgets.add(Padding(
        key: Key('archiveReason_${item.scan.id}'),
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          'Archived: $archiveReason',
          style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
        ),
      ));
    }

    final request = _openRequestFor(item.examCode);
    if (request == null) {
      if (!item.isArchivedAttempt && item.isGraded) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: TextButton(
            key: Key('requestRetake_${item.scan.id}'),
            onPressed: () => _openRequestRetakeDialog(item),
            child: Text('Request Retake', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.primaryGreen)),
          ),
        ));
      }
      return widgets;
    }

    if (request.isPending) {
      widgets.add(Padding(
        key: Key('pendingRetakeBanner_${item.scan.id}'),
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A retake request must be reviewed and approved.',
                style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: const Color(0xFF92400E)),
              ),
              const SizedBox(height: 4),
              Text(
                'Reason: ${request.reason}',
                style: AppTextStyles.body(size: 10.5, color: const Color(0xFF92400E)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    key: Key('approveRetake_${request.id}'),
                    onPressed: _reviewingRequestId != null
                        ? null
                        : () => _reviewRequest(request, approve: true),
                    child: const Text('Approve'),
                  ),
                  TextButton(
                    key: Key('rejectRetake_${request.id}'),
                    onPressed: _reviewingRequestId != null
                        ? null
                        : () => _reviewRequest(request, approve: false),
                    child: Text('Reject', style: TextStyle(color: AppColors.warmRedOrange)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ));
      return widgets;
    }

    if (request.isApproved) {
      final eligibleOn = request.eligibleOn;
      final eligibleNow = request.isEligibleOn(DateTime.now());
      final code = item.examCode;
      widgets.add(Padding(
        key: Key('approvedRetakeBanner_${item.scan.id}'),
        padding: const EdgeInsets.only(top: 8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.emerald100,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                eligibleOn == null
                    ? 'Retake approved.'
                    : (eligibleNow
                        ? '$code retake is eligible.'
                        : '$code retake is not yet eligible. Earliest eligible date: ${_formatDate(eligibleOn)}.'),
                style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: const Color(0xFF065F46)),
              ),
              if (!item.isArchivedAttempt) ...[
                const SizedBox(height: 8),
                TextButton(
                  key: Key('archiveAttempt_${request.id}'),
                  onPressed: _archivingRequestId != null
                      ? null
                      : () => _openArchiveAttemptDialog(item, request),
                  child: Text('Archive Attempt', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.primaryGreen)),
                ),
              ],
            ],
          ),
        ),
      ));
    }

    return widgets;
  }

  /// The latest OPEN (pending or approved-and-not-yet-consumed) retake
  /// request for [examCode], or null. Sorted newest first by the service,
  /// so the first match is the current one.
  ExamRetakeRequest? _openRequestFor(String examCode) {
    for (final r in _retakeRequests[examCode] ?? const <ExamRetakeRequest>[]) {
      if (r.isOpen) return r;
    }
    return null;
  }

  Future<void> _openRequestRetakeDialog(ExamineeHistoryItem item) async {
    final submitted = await showDialog<bool>(
      context: context,
      builder: (_) => _RequestRetakeDialog(
        service: widget.service,
        examineeId: _examinee.id,
        examCode: item.examCode,
      ),
    );
    if (submitted == true) _loadHistory();
  }

  Future<void> _reviewRequest(ExamRetakeRequest request, {required bool approve}) async {
    if (_reviewingRequestId != null) return;
    setState(() => _reviewingRequestId = request.id);
    final reviewed = await showDialog<bool>(
      context: context,
      builder: (_) => _ReviewRetakeDialog(
        service: widget.service,
        requestId: request.id,
        approve: approve,
      ),
    );
    if (!mounted) return;
    setState(() => _reviewingRequestId = null);
    if (reviewed == true) _loadHistory();
  }

  Future<void> _openArchiveAttemptDialog(
    ExamineeHistoryItem item,
    ExamRetakeRequest request,
  ) async {
    if (_archivingRequestId != null) return;
    setState(() => _archivingRequestId = request.id);
    final archived = await showDialog<bool>(
      context: context,
      builder: (_) => _ArchiveAttemptDialog(
        service: widget.service,
        requestId: request.id,
        examCode: item.examCode,
      ),
    );
    if (!mounted) return;
    setState(() => _archivingRequestId = null);
    if (archived == true) _loadHistory();
  }


  /// Same convention as `GuidanceWebResultsView._denominatorFor` /
  /// `GuidanceWebResultDetailView`'s own copy: TAT's official denominator is
  /// its 160-point maximum, never `totalItems`; AT/QTM show their actual
  /// item count.
  int _denominatorFor(LocalBatch batch, LocalScanResult result) {
    return batch.examCode == 'TAT' ? 160 : result.totalItems;
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// Name-only correction (OCR misread fix) — the only kind of edit Guidance
/// Council can make. The Temporary Examinee ID is shown but not editable;
/// there is no Birth Date, Last Attended School, or Official Student ID
/// field here at all (none has an established source yet).
class _ExamineeNameEditDialog extends StatefulWidget {
  const _ExamineeNameEditDialog({required this.service, required this.examinee});

  final GuidanceWebExamineeRecordsService service;
  final ExamineeRecord examinee;

  @override
  State<_ExamineeNameEditDialog> createState() => _ExamineeNameEditDialogState();
}

class _ExamineeNameEditDialogState extends State<_ExamineeNameEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstName = TextEditingController(text: widget.examinee.firstName);
  late final TextEditingController _middleName = TextEditingController(text: widget.examinee.middleName ?? '');
  late final TextEditingController _lastName = TextEditingController(text: widget.examinee.lastName);
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
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.service.updateExamineeProfile(
        widget.examinee,
        firstName: _firstName.text.trim(),
        middleName: _middleName.text.trim().isEmpty ? null : _middleName.text.trim(),
        lastName: _lastName.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, updated);
    } on GuidanceWebExamineeRecordsException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not save this examinee. Please try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Examinee Name'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Temporary Examinee ID: ${widget.examinee.temporaryExamineeId} (not editable)',
                style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _firstName,
                decoration: const InputDecoration(labelText: 'First name'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
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
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : 'Save')),
      ],
    );
  }
}

/// Workflow 4 — "Attach a Scan" (the examinee-first direction of the same
/// linking capability as records_view's scan-first "Link to Existing
/// Examinee"). Browses the Unlinked Scans queue and calls the exact same
/// [GuidanceWebExamineeRecordsService.linkScanToExaminee] — there is only
/// ever one linking mechanism in this feature.
class _AttachScanDialog extends StatefulWidget {
  const _AttachScanDialog({required this.service, required this.examinee});

  final GuidanceWebExamineeRecordsService service;
  final ExamineeRecord examinee;

  @override
  State<_AttachScanDialog> createState() => _AttachScanDialogState();
}

class _AttachScanDialogState extends State<_AttachScanDialog> {
  bool _loading = true;
  List<ExamineeHistoryItem> _unlinkedScans = [];
  String? _loadError;
  ExamineeHistoryItem? _linking;
  String? _linkError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final scans = await widget.service.loadUnlinkedScans();
      if (!mounted) return;
      setState(() {
        _unlinkedScans = scans;
        _loading = false;
      });
    } on GuidanceWebExamineeRecordsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load unlinked scans. Please try again.';
        _loading = false;
      });
    }
  }

  Future<void> _confirmAndAttach(ExamineeHistoryItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Attach Scan to Examinee Record'),
        content: Text(
          'Attach this ${item.examCode} scan from Batch ${item.batch.batchCode} '
          'to Examinee Record ${widget.examinee.temporaryExamineeId} (${widget.examinee.displayName})?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm Attach')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _linking = item;
      _linkError = null;
    });
    try {
      await widget.service.linkScanToExaminee(
        batchId: item.batch.id,
        scan: item.scan,
        examinee: widget.examinee,
        examCode: item.examCode,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on GuidanceWebExamineeRecordsException catch (e) {
      setState(() {
        _linkError = e.message;
        _linking = null;
      });
    } catch (_) {
      setState(() {
        _linkError = 'Could not attach this scan. Please try again.';
        _linking = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Attach a Scan to ${widget.examinee.displayName}'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _loadError != null
                ? Center(child: Text(_loadError!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)))
                : _unlinkedScans.isEmpty
                    ? Center(
                        child: Text('No unlinked scans available.', style: AppTextStyles.body(size: 11, color: AppColors.textGray)),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ListView.separated(
                              itemCount: _unlinkedScans.length,
                              separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.cardBorder),
                              itemBuilder: (context, index) {
                                final item = _unlinkedScans[index];
                                final name = item.scan.examinee?.displayName;
                                return ListTile(
                                  dense: true,
                                  title: Text(
                                    (name == null || name.isEmpty) ? 'Unnamed' : name,
                                    style: AppTextStyles.body(size: 12, weight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    '${item.examCode} — Batch ${item.batch.batchCode} — ${_formatDate(item.scan.capturedAt)}',
                                    style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
                                  ),
                                  trailing: _linking?.scan.id == item.scan.id
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                      : null,
                                  onTap: _linking != null ? null : () => _confirmAndAttach(item),
                                );
                              },
                            ),
                          ),
                          if (_linkError != null) ...[
                            const SizedBox(height: 8),
                            Text(_linkError!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
                          ],
                        ],
                      ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Close')),
      ],
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// "Request Retake" -- collects the required reason and submits it via
/// [GuidanceWebExamineeRecordsService.requestRetake]. Pops `true` on
/// success so the caller reloads history/requests.
class _RequestRetakeDialog extends StatefulWidget {
  const _RequestRetakeDialog({
    required this.service,
    required this.examineeId,
    required this.examCode,
  });

  final GuidanceWebExamineeRecordsService service;
  final String examineeId;
  final String examCode;

  @override
  State<_RequestRetakeDialog> createState() => _RequestRetakeDialogState();
}

class _RequestRetakeDialogState extends State<_RequestRetakeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.requestRetake(
        examineeId: widget.examineeId,
        examCode: widget.examCode,
        reason: _reasonController.text,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on GuidanceWebExamineeRecordsException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not submit this request. Please try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Request ${widget.examCode} Retake'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'A retake requires a valid reason and Guidance Council approval '
                'before the applicant may retake this examination.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('retakeReasonField'),
                controller: _reasonController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Reason'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'A reason is required' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(_saving ? 'Submitting...' : 'Submit Request')),
      ],
    );
  }
}

/// Approve/Reject a pending retake request, with an optional review note.
/// Pops `true` on success.
class _ReviewRetakeDialog extends StatefulWidget {
  const _ReviewRetakeDialog({
    required this.service,
    required this.requestId,
    required this.approve,
  });

  final GuidanceWebExamineeRecordsService service;
  final String requestId;
  final bool approve;

  @override
  State<_ReviewRetakeDialog> createState() => _ReviewRetakeDialogState();
}

class _ReviewRetakeDialogState extends State<_ReviewRetakeDialog> {
  final _noteController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.reviewRetakeRequest(
        requestId: widget.requestId,
        approve: widget.approve,
        reviewNote: _noteController.text,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on GuidanceWebExamineeRecordsException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not complete this review. Please try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.approve ? 'Approve' : 'Reject';
    return AlertDialog(
      title: Text('$label Retake Request'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.approve
                  ? 'Approving does not immediately make the applicant eligible -- '
                      'the previous attempt must still be archived, and the waiting '
                      'period still applies.'
                  : "Rejecting does not consume the applicant's retake -- a new "
                      'request can be submitted later.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reviewNoteField'),
              controller: _noteController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Review note (optional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(_saving ? 'Saving...' : label)),
      ],
    );
  }
}

/// "Archive Attempt" -- requires a reason and explicit confirmation before
/// calling [GuidanceWebExamineeRecordsService.archiveRetakeAttempt]. Pops
/// `true` on success.
class _ArchiveAttemptDialog extends StatefulWidget {
  const _ArchiveAttemptDialog({
    required this.service,
    required this.requestId,
    required this.examCode,
  });

  final GuidanceWebExamineeRecordsService service;
  final String requestId;
  final String examCode;

  @override
  State<_ArchiveAttemptDialog> createState() => _ArchiveAttemptDialogState();
}

class _ArchiveAttemptDialogState extends State<_ArchiveAttemptDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.archiveRetakeAttempt(
        requestId: widget.requestId,
        archiveReason: _reasonController.text,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on GuidanceWebExamineeRecordsException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not archive this attempt. Please try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Archive Previous Attempt'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This moves the previous ${widget.examCode} attempt into the '
                "examinee's archived examination history. The scan, its batch, "
                'and its results are preserved -- nothing is deleted.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('archiveAttemptReasonField'),
                controller: _reasonController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Reason for archiving'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'A reason is required' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: AppTextStyles.body(size: 11, color: AppColors.warmRedOrange)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _saving ? null : _submit, child: Text(_saving ? 'Archiving...' : 'Archive Attempt')),
      ],
    );
  }
}
