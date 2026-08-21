import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/primary_button.dart';

/// Configure Exam Session — mirrors SCREENS.EXAM_SETUP.
/// Lets staff pick a pending batch, set expected scale range, and
/// upload/confirm the answer key before launching the OMR scanner.
class ExamSetupScreen extends StatefulWidget {
  const ExamSetupScreen({super.key});

  @override
  State<ExamSetupScreen> createState() => _ExamSetupScreenState();
}

class _ExamSetupScreenState extends State<ExamSetupScreen> {
  late final TextEditingController _sessionIdController;
  final TextEditingController _totalController = TextEditingController(text: '40');
  String? _selectedBatch;

  @override
  void initState() {
    super.initState();
    final randomId = 1000 + DateTime.now().millisecondsSinceEpoch % 9000;
    _sessionIdController = TextEditingController(text: 'NDMU-OMR-RUN-$randomId');
  }

  @override
  void dispose() {
    _sessionIdController.dispose();
    _totalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final assignableBatches = appState.pendingBatches;
    _selectedBatch ??= assignableBatches.isNotEmpty ? assignableBatches.first.batch : null;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Configure Exam Session', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: appState,
          builder: (context, _) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: AppColors.cardBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Session Target Log Reference ID', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            TextField(controller: _sessionIdController),
                            const SizedBox(height: 16),

                            Text('Select Assigned Batch (Unchecked Only)', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              value: _selectedBatch,
                              hint: const Text('No pending batches available'),
                              items: assignableBatches
                                  .map((b) => DropdownMenuItem(
                                        value: b.batch,
                                        child: Text('${b.batch} [${b.examCode}]', style: AppTextStyles.body(size: 12)),
                                      ))
                                  .toList(),
                              onChanged: (val) {
                                setState(() => _selectedBatch = val);
                                final matched = appState.recentActivities.firstWhere(
                                  (a) => a.batch == val,
                                  orElse: () => appState.recentActivities.first,
                                );
                                appState.setActiveExamCode(matched.examCode);
                              },
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Only cohorts lacking complete test records can be scheduled for OMR camera tracking.',
                              style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                            ),
                            const SizedBox(height: 16),

                            Text('Expected Scale Range Bounds', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _totalController,
                              keyboardType: TextInputType.number,
                            ),
                            const SizedBox(height: 16),

                            Text('Exam Answer Key Setup', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppColors.lightBg,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: const Color(0xFFE2E8F0)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('Status:', style: AppTextStyles.body(size: 10, color: AppColors.textGray, weight: FontWeight.w600)),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: appState.answerKeyStatus == 'Loaded Success'
                                              ? AppColors.emerald100
                                              : const Color(0xFFFEF3C7),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          appState.answerKeyStatus == 'Loaded Success' ? '🔑 KEY LOADED' : '⚠️ PENDING KEY',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w700,
                                            color: appState.answerKeyStatus == 'Loaded Success'
                                                ? const Color(0xFF065F46)
                                                : const Color(0xFF92400E),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  OutlinedButton.icon(
                                    onPressed: () => Navigator.of(context).pushNamed(AppRoutes.answerKeyEntry),
                                    icon: const FaIcon(FontAwesomeIcons.penToSquare, size: 13, color: AppColors.primaryGreen),
                                    label: const Text('ADD EXAM ANSWER KEY'),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: AppColors.textDark,
                                      side: const BorderSide(color: Color(0xFFCBD5E1)),
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                      textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  PrimaryButton(
                    label: 'LAUNCH OMR SCANNER LOOP',
                    icon: FontAwesomeIcons.camera,
                    onPressed: () => _launchScanner(appState),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Warns before launching the scanner if this exam has no answer key
  /// yet — without one, scored results silently render every confidently
  /// decoded item in the same green used for a verified-correct answer
  /// (see ScoredItem.isCorrect: null when ungraded, and `null == false`
  /// is false, so it falls into the "correct" branch), which reads as "all
  /// correct" when nothing was actually checked. Not a hard block — a key
  /// can legitimately be added after scanning — just makes sure that's a
  /// deliberate choice, not something staff find out from an
  /// unexpectedly-all-green results screen.
  Future<void> _launchScanner(AppState appState) async {
    if (appState.answerKeyStatus != 'Loaded Success') {
      final addKeyFirst = await _showNoAnswerKeyDialog();
      if (addKeyFirst == null) return; // dismissed — don't launch either way
      if (addKeyFirst) {
        if (!mounted) return;
        Navigator.of(context).pushNamed(AppRoutes.answerKeyEntry);
        return;
      }
    }
    appState.resetScanProgress();
    if (!mounted) return;
    Navigator.of(context).pushNamed(AppRoutes.examScanning);
  }

  /// Returns true to go add the key first, false to scan without one now,
  /// or null if dismissed (treated the same as "don't launch").
  Future<bool?> _showNoAnswerKeyDialog() {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No Answer Key Set'),
        content: const Text(
          'This exam has no answer key yet. Sheets can still be scanned, but nothing will be graded until a key is added.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Scan Without Key')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Add Key First')),
        ],
      ),
    );
  }
}
