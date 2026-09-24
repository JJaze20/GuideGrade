import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/state/app_state.dart';
import '../../../core/sync/sync_client.dart';
import '../../../models/answer_key.dart';
import '../../../shared/widgets/primary_button.dart';

/// Which resolution the read-only Review dialog forwards the user to.
enum _ConflictChoice { keepCloud, replaceCloud }

/// Manual answer-key entry: tap the correct choice per question (like
/// ZipGrade's key-entry flow) instead of uploading a file. Reuses the same
/// OmrExamTemplate question/choice data that drives the scanner, so the
/// key always matches whatever's actually printed on the sheet.
///
/// When the cloud copy of this key was changed elsewhere and the local
/// push is parked ([AnswerKeySyncStatus.conflict]), a persistent banner
/// offers Review / Keep cloud / Replace cloud. Every one of those paths
/// reads the cloud key through [AppState] (never Supabase directly), keeps
/// the cloud data in memory only, and never discards the local answer key
/// unless the user explicitly chooses "Keep cloud".
class AnswerKeyEntryScreen extends StatefulWidget {
  const AnswerKeyEntryScreen({super.key});

  @override
  State<AnswerKeyEntryScreen> createState() => _AnswerKeyEntryScreenState();
}

class _AnswerKeyEntryScreenState extends State<AnswerKeyEntryScreen> {
  final Map<String, String> _selections = {};
  bool _loadedExisting = false;

  /// True while a cloud read is in flight — disables the banner actions and
  /// shows a thin progress line. No cloud data is ever persisted.
  bool _cloudBusy = false;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final template = omrTemplates[appState.activeExamCode];

    if (!_loadedExisting) {
      final existing = appState.answerKeys[appState.activeExamCode];
      if (existing != null) _selections.addAll(existing.correctChoices);
      _loadedExisting = true;
    }

    if (template == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Answer Key')),
        body: Center(
          child: Text('No sheet layout is defined for exam code "${appState.activeExamCode}".'),
        ),
      );
    }

    final totalItems = template.sections.fold<int>(0, (sum, s) => sum + s.itemCount);
    final syncStatus = appState.answerKeySyncStatusFor(appState.activeExamCode);
    final syncLabel = appState.answerKeySyncLabelFor(appState.activeExamCode);

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Answer Key — ${appState.activeExamCode}', style: AppTextStyles.heading(size: 13)),
        actions: [
          if (appState.syncManager != null) _buildLoadFromCloudButton(appState),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (syncStatus == AnswerKeySyncStatus.conflict)
              _buildConflictBanner(appState),
            if (_cloudBusy) const LinearProgressIndicator(minHeight: 2),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const FaIcon(FontAwesomeIcons.key, color: AppColors.primaryGreen, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tap the correct choice for each question.',
                      style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
                    ),
                  ),
                  _buildSyncChip(syncLabel, syncStatus),
                  const SizedBox(width: 8),
                  Text(
                    '${_selections.length}/$totalItems answered',
                    style: AppTextStyles.body(size: 10, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: template.sections.length,
                itemBuilder: (context, sectionIndex) => _buildSectionCard(template.sections[sectionIndex]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: PrimaryButton(
                label: 'SAVE ANSWER KEY',
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  final messenger = ScaffoldMessenger.of(context);

                  try {
                    await appState.setAnswerKey(
                      AnswerKey(
                        examCode: appState.activeExamCode,
                        correctChoices: Map.of(_selections),
                      ),
                    );
                  } catch (_) {
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Could not save the answer key. Please try again.',
                        ),
                      ),
                    );
                    return;
                  }

                  if (!mounted) return;
                  navigator.pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Conflict banner + sync status
  // ---------------------------------------------------------------------------

  /// A persistent, non-destructive banner (a plain `Material` surface rather
  /// than [MaterialBanner], to keep layout predictable inside this Column).
  Widget _buildConflictBanner(AppState appState) {
    return Material(
      key: const Key('answerKeyConflictBanner'),
      color: AppColors.amber50,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1, right: 8),
                  child: Icon(Icons.warning_amber_rounded,
                      color: AppColors.amber800, size: 18),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'This answer key was changed elsewhere and could not be synchronized.',
                      style: AppTextStyles.body(size: 11, color: AppColors.textDark),
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: _cloudBusy ? null : () => _onReview(appState),
                    child: const Text('Review'),
                  ),
                  TextButton(
                    onPressed: _cloudBusy ? null : () => _onKeepCloud(appState),
                    child: const Text('Keep cloud'),
                  ),
                  TextButton(
                    onPressed: _cloudBusy ? null : () => _onReplaceCloud(appState),
                    child: Text('Replace cloud',
                        style: TextStyle(color: AppColors.warmRedOrange)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Fixed app-bar button (not draggable): a white circle with a soft shadow
  /// holding the cloud-key icon. Lets a device with no local key — or one
  /// that just wants the shared key — pull the cloud answer key directly.
  Widget _buildLoadFromCloudButton(AppState appState) {
    final enabled = appState.isOnline && !_cloudBusy;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Center(
        child: Tooltip(
          message: appState.isOnline
              ? 'Load answer key from cloud'
              : 'Offline — cloud answer key unavailable',
          child: Material(
            key: const Key('loadCloudAnswerKeyButton'),
            color: Colors.white,
            shape: const CircleBorder(),
            elevation: enabled ? 3 : 0,
            shadowColor: Colors.black54,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: enabled ? () => _onLoadFromCloud(appState) : null,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Opacity(
                  opacity: enabled ? 1 : 0.35,
                  child: ColorFiltered(
                    colorFilter: enabled
                        ? const ColorFilter.mode(Colors.transparent, BlendMode.dst)
                        : const ColorFilter.mode(Colors.grey, BlendMode.saturation),
                    child: Image.asset(
                      'assets/images/cloud key.png',
                      width: 24,
                      height: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Button entry point: reads the cloud key, then reuses the same
  /// confirm-and-adopt path as "Keep cloud" (which also covers overwriting
  /// any local selections after an explicit confirmation).
  Future<void> _onLoadFromCloud(AppState appState) async {
    final cloud = await _readCloudOrShowError(
      appState,
      absentMessage: 'No cloud answer key for ${appState.activeExamCode} yet.',
    );
    if (cloud == null || !mounted) return;
    await _confirmAndKeepCloud(appState, cloud);
  }

  Widget _buildSyncChip(String label, AnswerKeySyncStatus status) {
    late final Color bg;
    late final Color fg;
    switch (status) {
      case AnswerKeySyncStatus.conflict:
        bg = const Color(0xFFFDE2E1);
        fg = AppColors.warmRedOrange;
      case AnswerKeySyncStatus.pending:
        bg = AppColors.amber100;
        fg = AppColors.amber800;
      case AnswerKeySyncStatus.upToDate:
        bg = AppColors.emerald100;
        fg = AppColors.emerald600;
      case AnswerKeySyncStatus.notConfigured:
        bg = AppColors.fileCardGray;
        fg = AppColors.textGray;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(
        label,
        style: AppTextStyles.body(size: 9, weight: FontWeight.w800, color: fg),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Conflict resolution flow
  // ---------------------------------------------------------------------------

  /// Reads the current cloud key through [AppState]. Returns a usable
  /// [CloudAnswerKeyRead] only when a row was actually found; otherwise
  /// shows a sanitized message and returns null, having touched neither the
  /// local key nor the parked conflict job.
  Future<CloudAnswerKeyRead?> _readCloudOrShowError(
    AppState appState, {
    String absentMessage = 'The cloud answer key is no longer available.',
  }) async {
    if (_cloudBusy) return null;
    setState(() => _cloudBusy = true);

    CloudAnswerKeyRead? read;
    try {
      read = await appState.readCloudAnswerKey(appState.activeExamCode);
    } catch (_) {
      read = null;
    }
    if (!mounted) return null;
    setState(() => _cloudBusy = false);

    if (read == null) {
      _snack('Cloud sync is not available on this device.');
      return null;
    }
    if (!read.exists) {
      _snack(read.error != null
          ? 'Could not load the cloud answer key. Check your connection and try again.'
          : absentMessage);
      return null;
    }
    return read;
  }

  Future<void> _onReview(AppState appState) async {
    final cloud = await _readCloudOrShowError(appState);
    if (cloud == null || !mounted) return;

    final choice = await showDialog<_ConflictChoice>(
      context: context,
      builder: (ctx) => _buildReviewDialog(ctx, cloud),
    );
    if (!mounted) return;
    if (choice == _ConflictChoice.keepCloud) {
      await _confirmAndKeepCloud(appState, cloud);
    } else if (choice == _ConflictChoice.replaceCloud) {
      await _confirmAndReplaceCloud(appState, cloud);
    }
  }

  Future<void> _onKeepCloud(AppState appState) async {
    final cloud = await _readCloudOrShowError(appState);
    if (cloud == null || !mounted) return;
    await _confirmAndKeepCloud(appState, cloud);
  }

  Future<void> _onReplaceCloud(AppState appState) async {
    final cloud = await _readCloudOrShowError(appState);
    if (cloud == null || !mounted) return;
    await _confirmAndReplaceCloud(appState, cloud);
  }

  /// "Keep cloud" — the ONLY path that discards the local answer key, and
  /// only after an explicit confirmation.
  Future<void> _confirmAndKeepCloud(
    AppState appState,
    CloudAnswerKeyRead cloud,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Use the cloud answer key?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Discard your local answer-key changes and use the cloud version?'),
            const SizedBox(height: 12),
            _buildCloudFacts(cloud),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Use cloud version'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await appState.adoptAnswerKeyFromCloud(
      appState.activeExamCode,
      cloudVersion: cloud.version!,
      answers: cloud.answers ?? const {},
      updatedAt: DateTime.tryParse(cloud.updatedAt ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
    );
    if (!mounted) return;
    setState(() {
      _selections
        ..clear()
        ..addAll(appState.answerKeys[appState.activeExamCode]?.correctChoices ??
            const {});
    });
    _snack('Using the cloud answer key.');
  }

  /// "Replace cloud" — destructive. Shows the cloud information, then a
  /// second, explicitly destructive confirmation, then asks [AppState] to
  /// prepare a version-guarded force push. The local key is left intact;
  /// nothing here claims the replacement succeeded.
  Future<void> _confirmAndReplaceCloud(
    AppState appState,
    CloudAnswerKeyRead cloud,
  ) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cloud answer key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('This is the answer key currently stored in the cloud.'),
            const SizedBox(height: 12),
            _buildCloudFacts(cloud),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace the cloud answer key?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This will permanently overwrite the newer cloud answer key '
              'with your local answer key.',
              style: AppTextStyles.body(
                size: 11,
                color: AppColors.warmRedOrange,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            _buildCloudFacts(cloud),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.warmRedOrange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace cloud key'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 10E-1 core: removes the blocked job, enqueues one fresh force job with
    // expectedCloudVersion, and wakes the manager. The force push re-reads
    // the cloud and re-conflicts if it moved past [cloud.version].
    await appState.prepareAnswerKeyForcePush(
      appState.activeExamCode,
      cloud.version!,
    );
    if (!mounted) return;
    setState(() {}); // status is now "Syncing"; local key unchanged
    _snack('Replace requested. This finishes the next time the device syncs.');
  }

  /// Read-only comparison of the local answers against the cloud answers.
  /// Opening or closing it never mutates local or cloud data; it only
  /// forwards the user to Keep cloud / Replace cloud / Cancel.
  Widget _buildReviewDialog(BuildContext ctx, CloudAnswerKeyRead cloud) {
    final local = Map<String, String>.of(_selections);
    final cloudAnswers = cloud.answers ?? const <String, String>{};
    final keys = <String>{...local.keys, ...cloudAnswers.keys}.toList()..sort();
    final headerStyle = AppTextStyles.body(
      size: 9,
      weight: FontWeight.w800,
      color: AppColors.textGray,
    );

    return AlertDialog(
      title: const Text('Review answer-key differences'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCloudFacts(cloud),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(flex: 4, child: Text('QUESTION', style: headerStyle)),
                Expanded(flex: 3, child: Text('YOUR ANSWERS', style: headerStyle)),
                Expanded(flex: 3, child: Text('CLOUD ANSWERS', style: headerStyle)),
              ],
            ),
            const Divider(height: 12),
            SizedBox(
              height: 300,
              child: SingleChildScrollView(
                child: Column(
                  children: keys.isEmpty
                      ? [
                          Text(
                            'Neither copy has any answers recorded.',
                            style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                          ),
                        ]
                      : keys.map((k) {
                          final mine = local[k] ?? '—';
                          final theirs = cloudAnswers[k] ?? '—';
                          final differs = mine != theirs;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: Text(
                                    k,
                                    style: AppTextStyles.body(
                                      size: 9.5,
                                      color: AppColors.textGray,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    mine,
                                    style: AppTextStyles.body(
                                      size: 10,
                                      weight: differs ? FontWeight.w800 : FontWeight.w400,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    theirs,
                                    style: AppTextStyles.body(
                                      size: 10,
                                      weight: differs ? FontWeight.w800 : FontWeight.w400,
                                      color: differs
                                          ? AppColors.warmRedOrange
                                          : AppColors.textDark,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, _ConflictChoice.keepCloud),
          child: const Text('Keep cloud'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, _ConflictChoice.replaceCloud),
          child: Text('Replace cloud', style: TextStyle(color: AppColors.warmRedOrange)),
        ),
      ],
    );
  }

  Widget _buildCloudFacts(CloudAnswerKeyRead cloud) {
    final lines = <String>['Cloud version: ${cloud.version}'];
    final by = cloud.updatedByName;
    if (by != null && by.trim().isNotEmpty) lines.add('Updated by: $by');
    final when = _formatTimestamp(cloud.updatedAt);
    if (when != null) lines.add('Updated: $when');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              line,
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
          ),
      ],
    );
  }

  String? _formatTimestamp(String? iso) {
    if (iso == null) return null;
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return null;
    final local = parsed.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------------------------------------------------------------------
  // Answer-key grid (unchanged)
  // ---------------------------------------------------------------------------

  Widget _buildSectionCard(OmrSection section) {
    final itemNumbers = section.items.keys.toList()..sort();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(section.name, style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          ...itemNumbers.map((itemNumber) => _buildQuestionRow(section, itemNumber)),
        ],
      ),
    );
  }

  Widget _buildQuestionRow(OmrSection section, int itemNumber) {
    final choices = section.items[itemNumber]!;
    final key = AnswerKey.keyFor(section.name, itemNumber);
    final selected = _selections[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 30,
            child: Text('$itemNumber.', style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: choices.map((bubble) => _buildChoiceBubble(key, bubble.choice, selected)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChoiceBubble(String key, String choice, String? selected) {
    final isSelected = choice == selected;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() {
        if (isSelected) {
          _selections.remove(key);
        } else {
          _selections[key] = choice;
        }
      }),
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryGreen : AppColors.lightBg,
          shape: BoxShape.circle,
          border: Border.all(color: isSelected ? AppColors.primaryGreen : const Color(0xFFCBD5E1)),
        ),
        child: Text(
          choice,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: isSelected ? Colors.white : AppColors.textDark,
          ),
        ),
      ),
    );
  }
}
