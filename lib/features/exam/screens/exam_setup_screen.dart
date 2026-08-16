import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/answer_key_adapter.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../core/state/app_state.dart';
import '../../../models/batch.dart';
import '../../../models/exam.dart';
import '../../../models/examinee.dart';
import '../../../shared/widgets/primary_button.dart';

/// Configure Exam Session — mirrors SCREENS.EXAM_SETUP.
///
/// Real Firestore identity end-to-end: staff pick a real ExamModel, then a
/// real BatchModel belonging to it, then a real ExamineeModel belonging to
/// that batch, and the scanner can only be launched once a valid Final
/// answer key for the selected exam has been loaded and converted for
/// scoring. Nothing here is sourced from local/SharedPreferences state
/// anymore -- see AppState.setScanSession for what carries this identity
/// into the scanning and results screens.
class ExamSetupScreen extends StatefulWidget {
  const ExamSetupScreen({super.key});

  @override
  State<ExamSetupScreen> createState() => _ExamSetupScreenState();
}

class _ExamSetupScreenState extends State<ExamSetupScreen> {
  final FirestoreService _firestoreService = FirestoreService();

  bool _isLoadingExams = true;
  List<ExamModel> _exams = [];
  ExamModel? _selectedExam;

  bool _isLoadingBatches = false;
  List<BatchModel> _batches = [];
  BatchModel? _selectedBatch;

  bool _isLoadingExaminees = false;
  List<ExamineeModel> _examinees = [];
  ExamineeModel? _selectedExaminee;

  bool _isLoadingAnswerKey = false;
  AnswerKeyLoadResult? _answerKeyResult;

  @override
  void initState() {
    super.initState();
    _loadExams();
  }

  Future<void> _loadExams() async {
    setState(() => _isLoadingExams = true);
    final allExams = await _firestoreService.getExams();
    setState(() {
      // Only exams marked Ready are eligible for scanning -- Draft exams
      // may still be missing their Final answer key or other setup.
      _exams = allExams.where((e) => e.isReady).toList();
      _isLoadingExams = false;
    });
  }

  Future<void> _onExamSelected(ExamModel? exam) async {
    setState(() {
      _selectedExam = exam;
      _selectedBatch = null;
      _batches = [];
      _selectedExaminee = null;
      _examinees = [];
      _answerKeyResult = null;
    });
    if (exam == null) return;
    await Future.wait([_loadBatches(exam), _loadAnswerKey(exam)]);
  }

  Future<void> _loadBatches(ExamModel exam) async {
    setState(() => _isLoadingBatches = true);
    final examBatches = await _firestoreService.getBatchesByExamId(exam.examId);
    if (!mounted) return;
    setState(() {
      // Only batches Active for this exam are selectable for scanning.
      _batches = examBatches.where((b) => b.status == 'Active' && b.examId == exam.examId).toList();
      _isLoadingBatches = false;
    });
  }

  Future<void> _loadAnswerKey(ExamModel exam) async {
    setState(() {
      _isLoadingAnswerKey = true;
      _answerKeyResult = null;
    });
    final appState = AppStateScope.of(context);
    try {
      final finalKey = await _firestoreService.getFinalAnswerKeyByExamId(exam.examId);
      final result = buildAnswerKeyForScoring(finalKey: finalKey, examCode: exam.examCode);
      if (result.isUsable) {
        appState.setAnswerKey(result.answerKey!);
      }
      if (!mounted) return;
      setState(() {
        _answerKeyResult = result;
        _isLoadingAnswerKey = false;
      });
    } on MultipleFinalAnswerKeysException catch (e) {
      if (!mounted) return;
      setState(() {
        _answerKeyResult = AnswerKeyLoadResult(
          usability: AnswerKeyUsability.multipleFinal,
          message: '$e Contact Guidance Council to resolve this before scanning.',
        );
        _isLoadingAnswerKey = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _answerKeyResult = AnswerKeyLoadResult(
          usability: AnswerKeyUsability.missing,
          message: 'Could not load the answer key: $e',
        );
        _isLoadingAnswerKey = false;
      });
    }
  }

  void _onBatchSelected(BatchModel? batch) {
    setState(() {
      _selectedBatch = batch;
      _selectedExaminee = null;
      _examinees = [];
    });
    if (batch == null || _selectedExam == null) return;
    // Defensive: the batch list is already filtered to this exam, but
    // refuse to proceed if that invariant is ever violated.
    if (batch.examId != _selectedExam!.examId) {
      setState(() => _selectedBatch = null);
      return;
    }
    _loadExaminees(batch);
  }

  Future<void> _loadExaminees(BatchModel batch) async {
    setState(() => _isLoadingExaminees = true);
    final batchExaminees = await _firestoreService.getExamineesByBatchId(batch.batchId);
    if (!mounted) return;
    setState(() {
      _examinees = batchExaminees.where((e) => e.batchId == batch.batchId).toList();
      _isLoadingExaminees = false;
    });
  }

  void _onExamineeSelected(ExamineeModel? examinee) {
    if (examinee != null && _selectedBatch != null && examinee.batchId != _selectedBatch!.batchId) {
      return; // defensive: should never be offered, refuse if it happens
    }
    setState(() => _selectedExaminee = examinee);
  }

  bool get _canLaunch =>
      _selectedExam != null &&
      _selectedBatch != null &&
      _selectedExaminee != null &&
      _answerKeyResult?.isUsable == true;

  void _launchScanner(AppState appState) {
    if (!_canLaunch) return;
    appState.setScanSession(
      examId: _selectedExam!.examId,
      examCode: _selectedExam!.examCode,
      examTitle: _selectedExam!.title,
      totalItems: _selectedExam!.totalItems,
      batchId: _selectedBatch!.batchId,
      batchCode: _selectedBatch!.batchCode,
      examineeId: _selectedExaminee!.examineeId,
      examineeName: _selectedExaminee!.fullName,
    );
    appState.resetScanProgress();
    Navigator.of(context).pushNamed(AppRoutes.examScanning);
  }

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Configure Exam Session', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Padding(
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
                        _buildSectionLabel('1. Select Exam'),
                        const SizedBox(height: 6),
                        _isLoadingExams
                            ? const _InlineLoading()
                            : DropdownButtonFormField<ExamModel>(
                                initialValue: _selectedExam,
                                hint: Text(
                                  _exams.isEmpty ? 'No Ready exams available' : 'Choose an exam',
                                  style: AppTextStyles.body(size: 11),
                                ),
                                items: _exams
                                    .map((e) => DropdownMenuItem(
                                          value: e,
                                          child: Text('${e.title} [${e.examCode}]', style: AppTextStyles.body(size: 12)),
                                        ))
                                    .toList(),
                                onChanged: _onExamSelected,
                              ),
                        const SizedBox(height: 4),
                        Text(
                          'Only exams marked Ready can be scanned.',
                          style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                        ),
                        const SizedBox(height: 16),

                        _buildSectionLabel('2. Select Batch'),
                        const SizedBox(height: 6),
                        _isLoadingBatches
                            ? const _InlineLoading()
                            : DropdownButtonFormField<BatchModel>(
                                initialValue: _selectedBatch,
                                hint: Text(
                                  _selectedExam == null
                                      ? 'Select an exam first'
                                      : _batches.isEmpty
                                          ? 'No Active batches for this exam'
                                          : 'Choose a batch',
                                  style: AppTextStyles.body(size: 11),
                                ),
                                items: _batches
                                    .map((b) => DropdownMenuItem(
                                          value: b,
                                          child: Text(
                                            '${b.batchCode} (${b.actualCount}/${b.expectedCount})',
                                            style: AppTextStyles.body(size: 12),
                                          ),
                                        ))
                                    .toList(),
                                onChanged: _selectedExam == null ? null : _onBatchSelected,
                              ),
                        const SizedBox(height: 16),

                        _buildSectionLabel('3. Select Examinee'),
                        const SizedBox(height: 6),
                        _isLoadingExaminees
                            ? const _InlineLoading()
                            : DropdownButtonFormField<ExamineeModel>(
                                initialValue: _selectedExaminee,
                                hint: Text(
                                  _selectedBatch == null
                                      ? 'Select a batch first'
                                      : _examinees.isEmpty
                                          ? 'No registered examinees in this batch'
                                          : 'Choose an examinee',
                                  style: AppTextStyles.body(size: 11),
                                ),
                                items: _examinees
                                    .map((ex) => DropdownMenuItem(
                                          value: ex,
                                          child: Text(
                                            '${ex.studentNumber} — ${ex.fullName}',
                                            style: AppTextStyles.body(size: 12),
                                          ),
                                        ))
                                    .toList(),
                                onChanged: _selectedBatch == null ? null : _onExamineeSelected,
                              ),
                        const SizedBox(height: 4),
                        Text(
                          'The scanned sheet(s) in this session will be graded as this examinee.',
                          style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                        ),
                        const SizedBox(height: 16),

                        _buildSectionLabel('4. Answer Key'),
                        const SizedBox(height: 6),
                        _buildAnswerKeyStatus(),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              PrimaryButton(
                label: 'LAUNCH OMR SCANNER LOOP',
                icon: FontAwesomeIcons.camera,
                onPressed: _canLaunch ? () => _launchScanner(appState) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionLabel(String text) =>
      Text(text, style: AppTextStyles.body(size: 11, weight: FontWeight.w700));

  Widget _buildAnswerKeyStatus() {
    if (_selectedExam == null) {
      return _statusBanner(
        icon: FontAwesomeIcons.circleInfo,
        color: AppColors.textGray,
        background: AppColors.lightBg,
        message: 'Select an exam to load its Final answer key.',
      );
    }
    if (_isLoadingAnswerKey) {
      return const _InlineLoading();
    }
    final result = _answerKeyResult;
    if (result == null) {
      return _statusBanner(
        icon: FontAwesomeIcons.circleInfo,
        color: AppColors.textGray,
        background: AppColors.lightBg,
        message: 'Loading answer key…',
      );
    }
    if (result.isUsable) {
      return _statusBanner(
        icon: FontAwesomeIcons.circleCheck,
        color: const Color(0xFF065F46),
        background: AppColors.emerald100,
        message: '🔑 Final answer key loaded and ready for scoring.',
      );
    }
    return _statusBanner(
      icon: FontAwesomeIcons.triangleExclamation,
      color: const Color(0xFF92400E),
      background: const Color(0xFFFEF3C7),
      message: result.message,
    );
  }

  Widget _statusBanner({
    required FaIconData icon,
    required Color color,
    required Color background,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(10)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FaIcon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color))),
        ],
      ),
    );
  }
}

class _InlineLoading extends StatelessWidget {
  const _InlineLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}
