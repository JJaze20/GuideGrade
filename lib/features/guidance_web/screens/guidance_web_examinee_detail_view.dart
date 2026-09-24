import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
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
      if (!mounted) return;
      setState(() {
        _history = history;
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
        TextButton(onPressed: _openAttachScanDialog, child: const Text('Attach a Scan')),
        TextButton(
          onPressed: _toggleArchive,
          child: Text(_examinee.isActive ? 'Archive' : 'Restore'),
        ),
      ],
      child: Wrap(
        spacing: 32,
        runSpacing: 16,
        children: [
          _infoField('Name', _examinee.displayName),
          _infoField('Temporary Examinee ID', _examinee.temporaryExamineeId),
          _infoField('Status', _examinee.isActive ? 'Active' : 'Archived'),
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
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(item.examCode, style: AppTextStyles.body(size: 11.5, weight: FontWeight.w700)),
          ),
          Expanded(flex: 2, child: Text(item.batch.batchCode, style: AppTextStyles.body(size: 11))),
          Expanded(flex: 2, child: Text('$score ($percentage)', style: AppTextStyles.body(size: 11))),
          Expanded(flex: 2, child: Text(_formatDate(item.scan.capturedAt), style: AppTextStyles.body(size: 11))),
          Expanded(flex: 1, child: Text(status, style: AppTextStyles.body(size: 11))),
          TextButton(
            onPressed: () => setState(() => _viewingHistoryItem = item),
            child: Text('View', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.primaryGreen)),
          ),
          TextButton(
            onPressed: _removingScanId != null ? null : () => _removeLink(item),
            child: Text('Remove Link', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: AppColors.warmRedOrange)),
          ),
        ],
      ),
    );
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
