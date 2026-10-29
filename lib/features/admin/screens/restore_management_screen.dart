import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/app_tokens.dart';
import '../../../core/sync/admin_scan_restore_client.dart';
import '../../../shared/widgets/segmented_tabs.dart';
import '../../../shared/widgets/state_views.dart';
import '../../../shared/widgets/status_badge.dart';
import '../../../shared/widgets/surface_card.dart';
import '../services/admin_scan_restore_service.dart';

enum _RestoreTab { deletedScans, restoreRequests }

/// System Admin "Restore Management" screen -- METADATA ONLY for this
/// phase. Lists soft-deleted unlinked scans and their restore requests, and
/// lets a System Admin APPROVE/REJECT a PENDING request and separately
/// restore the scan behind an APPROVED one. Deliberately shows no decoded
/// answers, scores, result fields, image paths, or any image preview --
/// none of that is ever queried by [AdminScanRestoreService] in the first
/// place, so there is nothing here to withhold; image/Storage access is
/// explicitly out of scope for this step (see
/// 0009_create_unlinked_scan_soft_delete.sql's RPCs, which never return any
/// such field).
///
/// Reached only through [AppRoutes.restoreManagement], itself in
/// `_adminOnlyRoutes` -- a `guidance_council` account can never navigate
/// here, and this screen never navigates to, or imports, anything from the
/// Guidance Council Web Console.
class RestoreManagementScreen extends StatefulWidget {
  /// [service] is only for tests; the app uses the real
  /// [AdminScanRestoreService].
  const RestoreManagementScreen({super.key, AdminScanRestoreService? service})
    : _service = service;

  final AdminScanRestoreService? _service;

  @override
  State<RestoreManagementScreen> createState() =>
      _RestoreManagementScreenState();
}

class _RestoreManagementScreenState extends State<RestoreManagementScreen> {
  late final AdminScanRestoreService _service =
      widget._service ?? AdminScanRestoreService();

  _RestoreTab _tab = _RestoreTab.deletedScans;

  bool _loadingDeleted = true;
  List<CloudAdminSoftDeletedScanRow> _deletedScans = [];
  String? _deletedError;

  bool _loadingRequests = true;
  List<CloudAdminRestoreRequestRow> _requests = [];
  String? _requestsError;

  /// The request id currently showing a review (Approve/Reject) dialog, or
  /// null -- guards against a double-tap opening two dialogs for the same
  /// request while one is already open.
  String? _reviewingRequestId;

  /// The request id currently showing a Restore Scan dialog, or null --
  /// same guard reasoning as [_reviewingRequestId].
  String? _restoringRequestId;

  @override
  void initState() {
    super.initState();
    _loadDeletedScans();
    _loadRestoreRequests();
  }

  Future<void> _loadDeletedScans() async {
    setState(() {
      _loadingDeleted = true;
      _deletedError = null;
    });
    try {
      final scans = await _service.loadDeletedScans();
      if (!mounted) return;
      setState(() {
        _deletedScans = scans;
        _loadingDeleted = false;
      });
    } on AdminScanRestoreException catch (e) {
      if (!mounted) return;
      setState(() {
        _deletedError = e.message;
        _loadingDeleted = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _deletedError = 'Could not load deleted scans. Please try again.';
        _loadingDeleted = false;
      });
    }
  }

  Future<void> _loadRestoreRequests() async {
    setState(() {
      _loadingRequests = true;
      _requestsError = null;
    });
    try {
      final requests = await _service.loadRestoreRequests();
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _loadingRequests = false;
      });
    } on AdminScanRestoreException catch (e) {
      if (!mounted) return;
      setState(() {
        _requestsError = e.message;
        _loadingRequests = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _requestsError = 'Could not load restore requests. Please try again.';
        _loadingRequests = false;
      });
    }
  }

  /// Re-loads both sections -- used after any write (review or restore)
  /// succeeds, since each can change what the OTHER section shows (e.g. a
  /// successful restore removes a row from Deleted Scans AND flips its
  /// request to RESTORED).
  Future<void> _refreshAll() async {
    await Future.wait([_loadDeletedScans(), _loadRestoreRequests()]);
  }

  Future<void> _openReview(
    CloudAdminRestoreRequestRow request, {
    required bool approve,
  }) async {
    if (_reviewingRequestId != null) return;
    setState(() => _reviewingRequestId = request.requestId);
    final reviewed = await showDialog<bool>(
      context: context,
      builder: (_) => _ReviewRequestDialog(
        service: _service,
        request: request,
        approve: approve,
      ),
    );
    if (!mounted) return;
    setState(() => _reviewingRequestId = null);
    if (reviewed != true) return;

    await _refreshAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(approve ? 'Request approved.' : 'Request rejected.'),
      ),
    );
  }

  Future<void> _openRestore(CloudAdminRestoreRequestRow request) async {
    if (_restoringRequestId != null) return;
    setState(() => _restoringRequestId = request.requestId);
    final restored = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _RestoreScanDialog(service: _service, requestId: request.requestId),
    );
    if (!mounted) return;
    setState(() => _restoringRequestId = null);
    if (restored != true) return;

    await _refreshAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Scan restored successfully.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEAF0F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFF14243D),
        foregroundColor: Colors.white,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.border)),
        title: Text(
          'Restore Management',
          style: AppTextStyles.heading(size: 17, color: Colors.white),
        ),
        actions: [
          IconButton(
            key: const Key('restoreManagementRefreshButton'),
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, size: 22),
            onPressed: _refreshAll,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildTabSwitcher(),
            Expanded(
              child: _tab == _RestoreTab.deletedScans
                  ? _buildDeletedScansTab()
                  : _buildRestoreRequestsTab(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabSwitcher() {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: const Color(0xFFDDE7F3),
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      child: SegmentedTabs<_RestoreTab>(
        selected: _tab,
        onChanged: (tab) => setState(() => _tab = tab),
        items: const [
          SegmentedTabItem(
            value: _RestoreTab.deletedScans,
            label: 'Deleted Scans',
          ),
          SegmentedTabItem(
            value: _RestoreTab.restoreRequests,
            label: 'Restore Requests',
          ),
        ],
      ),
    );
  }

  /// Keeps card lists readable on wide desktop windows instead of stretching
  /// each card across the whole viewport.
  Widget _centered(Widget child) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: child,
    ),
  );

  // -------------------------------------------------------------------
  // Deleted Scans tab -- metadata only, via
  // list_soft_deleted_unlinked_scans_for_admin.
  // -------------------------------------------------------------------

  Widget _buildDeletedScansTab() {
    if (_loadingDeleted)
      return const LoadingState(message: 'Loading deleted scans...');
    if (_deletedError != null) {
      return ErrorState(
        title: 'Could not load deleted scans',
        message: _deletedError!,
        onRetry: _loadDeletedScans,
      );
    }
    if (_deletedScans.isEmpty) {
      return const EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'No soft-deleted scans.',
        message:
            'Deleted unlinked scans stay here for 30 days before they expire.',
      );
    }
    return _centered(
      ListView.separated(
        padding: const EdgeInsets.all(AppSpace.lg),
        itemCount: _deletedScans.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
        itemBuilder: (context, index) =>
            _DeletedScanCard(scan: _deletedScans[index]),
      ),
    );
  }

  // -------------------------------------------------------------------
  // Restore Requests tab -- metadata only, via
  // list_scan_restore_requests_for_admin.
  // -------------------------------------------------------------------

  Widget _buildRestoreRequestsTab() {
    if (_loadingRequests)
      return const LoadingState(message: 'Loading restore requests...');
    if (_requestsError != null) {
      return ErrorState(
        title: 'Could not load restore requests',
        message: _requestsError!,
        onRetry: _loadRestoreRequests,
      );
    }
    if (_requests.isEmpty) {
      return const EmptyState(
        title: 'No restore requests.',
        message:
            'Requests from Guidance Council to bring back a deleted scan appear here.',
      );
    }
    return _centered(
      ListView.separated(
        padding: const EdgeInsets.all(AppSpace.lg),
        itemCount: _requests.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpace.md),
        itemBuilder: (context, index) {
          final request = _requests[index];
          return _RestoreRequestCard(
            request: request,
            onApprove: _reviewingRequestId != null
                ? null
                : () => _openReview(request, approve: true),
            onReject: _reviewingRequestId != null
                ? null
                : () => _openReview(request, approve: false),
            onRestore: _restoringRequestId != null
                ? null
                : () => _openRestore(request),
          );
        },
      ),
    );
  }
}

String _formatDateTime(DateTime d) {
  final local = d.toLocal();
  const months = [
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
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${months[local.month - 1]} ${local.day}, ${local.year}, $hh:$mm';
}

/// One soft-deleted scan -- lifecycle metadata only (batch/exam/scan id/
/// deleted/expires/reason/deleted-by). No action button exists here: the
/// action lives on the Restore Requests tab, scoped to an actual request.
class _DeletedScanCard extends StatelessWidget {
  const _DeletedScanCard({required this.scan});

  final CloudAdminSoftDeletedScanRow scan;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      color: const Color(0xFFFFF6E4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitleRow(
            scanId: scan.scanId,
            batchId: scan.batchId,
            badges: [_examBadge(scan.examCode)],
          ),
          const SizedBox(height: AppSpace.md),
          const Divider(),
          const SizedBox(height: AppSpace.md),
          _detailRow('Deleted', _formatDateTime(scan.deletedAt)),
          _detailRow('Expires', _formatDateTime(scan.retentionUntil)),
          _detailRow('Reason', scan.deletionReason ?? '—'),
          _detailRow('Deleted by', scan.deletedByName ?? '—'),
        ],
      ),
    );
  }
}

/// One restore request -- request/review metadata only, plus the two
/// gated actions (Approve/Reject while PENDING, Restore Scan while
/// APPROVED). A null action callback disables that button (duplicate-tap
/// guard owned by the parent screen).
class _RestoreRequestCard extends StatelessWidget {
  const _RestoreRequestCard({
    required this.request,
    required this.onApprove,
    required this.onReject,
    required this.onRestore,
  });

  final CloudAdminRestoreRequestRow request;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    return SurfaceCard(
      color: const Color(0xFFFFF6E4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardTitleRow(
            scanId: request.scanId,
            batchId: request.batchId,
            badges: [
              _examBadge(request.examCode),
              _statusBadge(request.status),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          const Divider(),
          const SizedBox(height: AppSpace.md),
          _detailRow('Request reason', request.reason),
          _detailRow('Requested by', request.requestedByName ?? '—'),
          _detailRow('Requested at', _formatDateTime(request.requestedAt)),
          if (request.reviewedByName != null)
            _detailRow('Reviewed by', request.reviewedByName!),
          if (request.reviewedAt != null)
            _detailRow('Reviewed at', _formatDateTime(request.reviewedAt!)),
          if (request.reviewNote != null)
            _detailRow('Review note', request.reviewNote!),
          if (request.isPending || request.isApproved) ...[
            const SizedBox(height: AppSpace.sm),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpace.sm,
              runSpacing: AppSpace.sm,
              children: [
                if (request.isPending) ...[
                  TextButton(
                    onPressed: onReject,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, AppHit.minTarget),
                      foregroundColor: AppColors.dangerFg,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: const Text('Reject'),
                  ),
                  TextButton(
                    onPressed: onApprove,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, AppHit.minTarget),
                      foregroundColor: AppColors.primaryGreen,
                      backgroundColor: AppColors.successBg,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: const Text('Approve'),
                  ),
                ],
                if (request.isApproved)
                  TextButton(
                    onPressed: onRestore,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, AppHit.minTarget),
                      foregroundColor: AppColors.primaryGreen,
                      backgroundColor: AppColors.successBg,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    child: const Text('Restore Scan'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// "Scan [id]" with its batch underneath and status/exam badges on the right
/// (wrapping below the title on narrow screens instead of overflowing).
class _CardTitleRow extends StatelessWidget {
  const _CardTitleRow({
    required this.scanId,
    required this.batchId,
    required this.badges,
  });

  final String scanId;
  final String batchId;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpace.md,
      runSpacing: AppSpace.sm,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Scan $scanId', style: AppTextStyles.subtitle()),
            const SizedBox(height: 2),
            Text('Batch $batchId', style: AppTextStyles.caption()),
          ],
        ),
        Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.xs, children: badges),
      ],
    );
  }
}

Widget _examBadge(String examCode) =>
    StatusBadge(label: examCode, tone: StatusTone.neutral);

Widget _statusBadge(String status) {
  final upper = status.toUpperCase();
  final tone = switch (upper) {
    'PENDING' => StatusTone.warning,
    'APPROVED' || 'RESTORED' => StatusTone.success,
    'REJECTED' || 'PURGED' => StatusTone.danger,
    _ => StatusTone.neutral,
  };
  return StatusBadge(label: upper, tone: tone);
}

Widget _detailRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: AppTextStyles.caption(weight: FontWeight.w700),
          ),
        ),
        Expanded(child: Text(value, style: AppTextStyles.text())),
      ],
    ),
  );
}

/// APPROVE/REJECT a PENDING request. Shows the request's own metadata
/// (read-only) plus a mandatory review note -- this app's own policy (the
/// RPC's own `p_review_note` is nullable), matching
/// [AdminScanRestoreService.reviewRestoreRequest]'s own validation. Pops
/// `true` only once the RPC call has actually succeeded.
class _ReviewRequestDialog extends StatefulWidget {
  const _ReviewRequestDialog({
    required this.service,
    required this.request,
    required this.approve,
  });

  final AdminScanRestoreService service;
  final CloudAdminRestoreRequestRow request;
  final bool approve;

  @override
  State<_ReviewRequestDialog> createState() => _ReviewRequestDialogState();
}

class _ReviewRequestDialogState extends State<_ReviewRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _noteController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.reviewRestoreRequest(
        requestId: widget.request.requestId,
        approve: widget.approve,
        reviewNote: _noteController.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on AdminScanRestoreException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not submit this review. Please try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return AlertDialog(
      title: Text(
        widget.approve ? 'Approve Restore Request' : 'Reject Restore Request',
      ),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Scan ${r.scanId} — Batch ${r.batchId} — ${r.examCode}',
                style: AppTextStyles.body(
                  size: 10.5,
                  color: AppColors.textGray,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Requested reason: ${r.reason}',
                style: AppTextStyles.body(
                  size: 10.5,
                  color: AppColors.textGray,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.approve
                    ? 'This will approve the restoration request. The scan itself is '
                          'not restored yet -- a separate "Restore Scan" action will become '
                          'available afterward.'
                    : 'This will reject the restoration request. The scan remains '
                          'soft-deleted, and a new request may be submitted later.',
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('reviewNoteField'),
                controller: _noteController,
                enabled: !_saving,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Review note'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'A review note is required'
                    : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: AppTextStyles.body(
                    size: 11,
                    color: AppColors.warmRedOrange,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: widget.approve
                ? AppColors.primaryGreen
                : AppColors.warmRedOrange,
          ),
          child: Text(
            _saving ? 'Submitting...' : (widget.approve ? 'Approve' : 'Reject'),
          ),
        ),
      ],
    );
  }
}

/// Restores the scan behind an APPROVED request. No reason field -- the
/// approval's own review note already covers that; see this file's PART 7
/// instruction this mirrors. Pops `true` only once the RPC call has
/// actually succeeded.
class _RestoreScanDialog extends StatefulWidget {
  const _RestoreScanDialog({required this.service, required this.requestId});

  final AdminScanRestoreService service;
  final String requestId;

  @override
  State<_RestoreScanDialog> createState() => _RestoreScanDialogState();
}

class _RestoreScanDialogState extends State<_RestoreScanDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.service.restoreApprovedScan(requestId: widget.requestId);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on AdminScanRestoreException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not restore this scan. Please try again.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore Scan?'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This will restore the scan to the active Unlinked Scans list if it is '
              'still within the 30-day retention window.',
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: AppTextStyles.body(
                  size: 11,
                  color: AppColors.warmRedOrange,
                ),
              ),
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
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? 'Restoring...' : 'Restore Scan'),
        ),
      ],
    );
  }
}
