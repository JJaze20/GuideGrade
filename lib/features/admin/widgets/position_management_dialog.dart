import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/guidance_position.dart';
import 'add_guidance_position_dialog.dart';

/// Opens the Position Management dialog -- what the Guidance Position "+"
/// action (Create User, Edit User) now opens instead of going straight to
/// [showAddGuidancePositionDialog]. Lists every current position with a
/// Delete action, and an "Add Position" action that reuses the existing
/// add dialog unchanged, so the add flow/validation/keys are identical to
/// before this feature.
///
/// [initialPositions] is shown immediately (no loading flicker on open);
/// the dialog re-reads the live list after every add/delete so it never
/// drifts from Firestore while open. Returns when the admin closes the
/// dialog -- the caller is responsible for refreshing its own position
/// list afterward (see `CreateUserScreen`/`EditUserScreen`'s own
/// `_managePositions`), exactly as it already did after the old add
/// dialog closed.
Future<void> showPositionManagementDialog(
  BuildContext context, {
  required List<GuidancePosition> initialPositions,
  FirestoreService? firestoreService,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _PositionManagementDialog(
      firestoreService: firestoreService ?? FirestoreService(),
      initialPositions: initialPositions,
    ),
  );
}

class _PositionManagementDialog extends StatefulWidget {
  const _PositionManagementDialog({
    required this.firestoreService,
    required this.initialPositions,
  });

  final FirestoreService firestoreService;
  final List<GuidancePosition> initialPositions;

  @override
  State<_PositionManagementDialog> createState() => _PositionManagementDialogState();
}

class _PositionManagementDialogState extends State<_PositionManagementDialog> {
  late List<GuidancePosition> _positions = List.of(widget.initialPositions);
  bool _busy = false;
  String? _error;

  Future<void> _refresh() async {
    final positions = await widget.firestoreService.loadGuidancePositions();
    if (!mounted) return;
    setState(() => _positions = positions);
  }

  Future<void> _add() async {
    final label = await showAddGuidancePositionDialog(context);
    if (label == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.firestoreService.addGuidancePosition(label, _positions);
      await _refresh();
    } on ArgumentError catch (e) {
      if (mounted) setState(() => _error = e.message.toString());
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not add the position. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Blocks deletion when [position] is currently assigned to any user --
  /// checked once up front (so a plainly-in-use position never even reaches
  /// the confirmation dialog), then re-checked immediately before the
  /// actual delete call once confirmed, mirroring `EditUserScreen.
  /// _deactivate`'s own "never trust the first check alone" guard shape for
  /// a destructive action.
  Future<void> _delete(GuidancePosition position) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final assigned = await widget.firestoreService.isGuidancePositionAssigned(position.value);
      if (!mounted) return;
      if (assigned) {
        await _showBlockedDialog(position);
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete this position?'),
          content: Text(
            '"${position.label}" will be removed from the Guidance Position list. '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              key: const Key('positionManagement.deleteConfirm.cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('positionManagement.deleteConfirm.delete'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      // Defensive re-check -- never trust that the check above still holds
      // by the time the admin has finished reading and confirming the
      // dialog; a user could have been assigned this position in between.
      final stillAssigned = await widget.firestoreService.isGuidancePositionAssigned(position.value);
      if (!mounted) return;
      if (stillAssigned) {
        await _showBlockedDialog(position);
        return;
      }

      await widget.firestoreService.removeGuidancePosition(position.value);
      await _refresh();
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not delete the position. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showBlockedDialog(GuidancePosition position) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('positionManagement.blockedDialog'),
        title: const Text('Cannot Delete This Position'),
        content: Text(
          '"${position.label}" is currently assigned to one or more user accounts. '
          'Reassign those accounts to a different position before deleting it.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Position Management'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: AppTextStyles.body(size: 10.5, color: const Color(0xFF991B1B)),
                ),
              ),
              const SizedBox(height: 12),
            ],
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: _positions.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'No positions yet.',
                        style: AppTextStyles.body(size: 11, color: AppColors.textGray),
                      ),
                    )
                  : ListView.separated(
                      key: const Key('positionManagement.list'),
                      shrinkWrap: true,
                      itemCount: _positions.length,
                      separatorBuilder: (_, _) => const Divider(height: 1, color: AppColors.cardBorder),
                      itemBuilder: (_, i) {
                        final position = _positions[i];
                        return Padding(
                          key: Key('positionManagement.row.${position.value}'),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(position.label, style: AppTextStyles.body(size: 11.5)),
                              ),
                              IconButton(
                                key: Key('positionManagement.delete.${position.value}'),
                                tooltip: 'Delete',
                                icon: const Icon(Icons.delete_outline, color: AppColors.warmRedOrange, size: 18),
                                onPressed: _busy ? null : () => _delete(position),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('positionManagement.add'),
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add_circle_outline, size: 16),
              label: const Text('Add Position'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('positionManagement.close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
