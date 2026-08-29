import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/constants/exam_catalog.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/primary_button.dart';

/// Create Batch screen for Guidance Council users.
///
/// Creates a new local batch bound to one exam type. When reached from the
/// scan workflow (no compatible batch existed yet), [initialExamCode]
/// pre-selects and locks the exam type so the new batch is guaranteed
/// compatible with the scan the user was trying to start.
class CreateBatchScreen extends StatefulWidget {
  final String? initialExamCode;

  const CreateBatchScreen({super.key, this.initialExamCode});

  @override
  State<CreateBatchScreen> createState() => _CreateBatchScreenState();
}

class _CreateBatchScreenState extends State<CreateBatchScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  final _formKey = GlobalKey<FormState>();

  final _descriptionController = TextEditingController();
  final _expectedCountController = TextEditingController(text: '30');

  ExamCatalogEntry? _selectedExam;
  String _generatedBatchCode = '';
  bool _isSaving = false;

  bool get _examLocked => widget.initialExamCode != null;

  @override
  void initState() {
    super.initState();
    _generateBatchCode();
    if (widget.initialExamCode != null) {
      _selectedExam = examCatalog.firstWhere(
        (e) => e.examCode == widget.initialExamCode,
        orElse: () => examCatalog.first,
      );
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _expectedCountController.dispose();
    super.dispose();
  }

  void _generateBatchCode() {
    final now = DateTime.now();
    final year = now.year;
    final month = now.month.toString().padLeft(2, '0');
    final random = (100 + (now.millisecondsSinceEpoch % 900)).toString();
    setState(() {
      _generatedBatchCode = 'B-$year$month-$random';
    });
  }

  Future<void> _createBatch() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedExam == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an exam type')),
      );
      return;
    }

    setState(() => _isSaving = true);

    final repo = AppStateScope.of(context).batchRepository;
    try {
      // Local batch-code uniqueness check.
      final existing = await repo.getBatches();
      if (existing.any((b) => b.batchCode == _generatedBatchCode)) {
        _generateBatchCode();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Batch code already exists. Generated a new code.')),
          );
          setState(() => _isSaving = false);
        }
        return;
      }

      final currentUser = _auth.currentUser;

      await repo.createBatch(
        batchCode: _generatedBatchCode,
        examCode: _selectedExam!.examCode,
        examTitle: _selectedExam!.title,
        description: _descriptionController.text.trim(),
        expectedCount: int.parse(_expectedCountController.text),
        createdByUid: currentUser?.uid ?? '',
        createdByName: currentUser?.displayName ?? 'Unknown',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Batch created successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating batch: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Create Batch', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_examLocked)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.emerald100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Creating a batch for ${_selectedExam?.title ?? widget.initialExamCode} '
                    'so you can start scanning.',
                    style: AppTextStyles.body(size: 10, color: const Color(0xFF065F46), weight: FontWeight.w600),
                  ),
                ),
              _buildSection('Basic Information'),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Batch Code',
                controller: TextEditingController(text: _generatedBatchCode),
                hint: 'Auto-generated',
                required: true,
                enabled: false,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Description',
                controller: _descriptionController,
                hint: 'e.g., BSIT - 1A',
                required: false,
              ),
              const SizedBox(height: 16),
              _buildSection('Exam Type'),
              const SizedBox(height: 16),
              _buildExamDropdown(),
              const SizedBox(height: 16),
              _buildSection('Batch Configuration'),
              const SizedBox(height: 16),
              _buildNumberField(
                label: 'Expected Answer Sheets',
                controller: _expectedCountController,
                required: true,
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isSaving ? 'Creating...' : 'Create Batch',
                onPressed: _isSaving ? null : _createBatch,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSection(String title) {
    return Text(
      title,
      style: AppTextStyles.body(size: 11, weight: FontWeight.w700, color: AppColors.primaryGreen),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    String? hint,
    bool required = false,
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            if (required)
              Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          enabled: enabled,
          decoration: InputDecoration(
            hintText: hint,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.primaryGreen),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder.withOpacity(0.5)),
            ),
            filled: !enabled,
            fillColor: AppColors.lightBg.withOpacity(0.5),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildNumberField({
    required String label,
    required TextEditingController controller,
    bool required = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            if (required)
              Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.primaryGreen),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          validator: required
              ? (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Required';
                  }
                  final number = int.tryParse(value);
                  if (number == null || number <= 0) {
                    return 'Enter a valid number';
                  }
                  return null;
                }
              : null,
        ),
      ],
    );
  }

  Widget _buildExamDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Exam Type', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
            if (_examLocked)
              Text('  (locked)', style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
          ],
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<ExamCatalogEntry>(
          value: _selectedExam,
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.primaryGreen),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.cardBorder.withOpacity(0.5)),
            ),
            filled: _examLocked,
            fillColor: AppColors.lightBg.withOpacity(0.5),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          hint: Text('Select an exam type', style: AppTextStyles.body(size: 11)),
          items: examCatalog.map((exam) {
            return DropdownMenuItem(
              value: exam,
              child: Text('${exam.title} (${exam.examCode})', style: AppTextStyles.body(size: 11)),
            );
          }).toList(),
          onChanged: _examLocked ? null : (value) => setState(() => _selectedExam = value),
        ),
      ],
    );
  }
}
