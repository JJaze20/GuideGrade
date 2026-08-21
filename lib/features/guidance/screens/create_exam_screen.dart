import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/exam.dart';
import '../../../shared/widgets/primary_button.dart';

/// Create Exam screen for Guidance Council users.
/// Allows creation of new exams with validation.
class CreateExamScreen extends StatefulWidget {
  const CreateExamScreen({super.key});

  @override
  State<CreateExamScreen> createState() => _CreateExamScreenState();
}

class _CreateExamScreenState extends State<CreateExamScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final AuthService _authService = AuthService();
  
  final _formKey = GlobalKey<FormState>();
  
  final _examCodeController = TextEditingController();
  final _titleController = TextEditingController();
  final _totalItemsController = TextEditingController(text: '50');
  final _durationController = TextEditingController(text: '90');
  final _instructionsController = TextEditingController();
  final _academicYearController = TextEditingController(text: '2026-2027');
  final _semesterController = TextEditingController(text: '1st Semester');
  
  String _selectedCategory = 'admission';
  String _selectedTemplate = 'Default-50';
  
  bool _isLoading = false;
  bool _isCheckingCode = false;

  @override
  void dispose() {
    _examCodeController.dispose();
    _titleController.dispose();
    _totalItemsController.dispose();
    _durationController.dispose();
    _instructionsController.dispose();
    _academicYearController.dispose();
    _semesterController.dispose();
    super.dispose();
  }

  /// The only exam codes recognized by the OMR sheet layouts (omrTemplates)
  /// -- any other value would let an exam be saved that Answer Key
  /// Management / Exam Setup can never actually use for scanning.
  static const Set<String> _validExamCodes = {'QTM', 'TAT', 'AT'};

  String? _validateExamCode(String? value) {
    final trimmed = (value ?? '').trim();
    if (trimmed.isEmpty) {
      return 'Required';
    }
    if (!_validExamCodes.contains(trimmed.toUpperCase())) {
      return 'Must be exactly QTM, TAT, or AT';
    }
    return null;
  }

  Future<bool> _checkExamCodeUniqueness(String examCode) async {
    if (examCode.isEmpty) return false;
    
    setState(() => _isCheckingCode = true);
    
    try {
      final existingExam = await _firestoreService.getExamByCode(examCode);
      setState(() => _isCheckingCode = false);
      return existingExam == null;
    } catch (e) {
      print('Error checking exam code: $e');
      setState(() => _isCheckingCode = false);
      return false;
    }
  }

  Future<void> _createExam() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      // Canonical form: trimmed, uppercase -- matches omrTemplates' keys
      // exactly regardless of what case the user typed.
      final examCode = _examCodeController.text.trim().toUpperCase();

      // Check exam code uniqueness
      final isUnique = await _checkExamCodeUniqueness(examCode);

      if (!isUnique) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Exam code already exists. Please use a different code.')),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // Get current user
      final currentUser = await _authService.getCurrentFirestoreUser();
      if (currentUser == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to get user information.')),
          );
        }
        setState(() => _isLoading = false);
        return;
      }

      // Create exam
      final exam = ExamModel(
        examId: '', // Will be set by Firestore
        examCode: examCode,
        title: _titleController.text.trim(),
        category: _selectedCategory,
        totalItems: int.parse(_totalItemsController.text),
        duration: int.parse(_durationController.text),
        instructions: _instructionsController.text.trim(),
        answerSheetTemplate: _selectedTemplate,
        status: 'Draft',
        createdByUid: currentUser.userId,
        createdByName: currentUser.displayName,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        academicYear: _academicYearController.text.trim(),
        semester: _semesterController.text.trim(),
      );

      await _firestoreService.createExam(exam);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Exam created successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('Error creating exam: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating exam: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
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
        title: Text('Create Exam', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSection('Basic Information'),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Exam Code',
                controller: _examCodeController,
                hint: 'QTM, TAT, or AT',
                required: true,
                validator: _validateExamCode,
                suffix: _isCheckingCode
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                'Must be exactly QTM, TAT, or AT -- this selects which OMR sheet layout the exam uses.',
                style: AppTextStyles.body(size: 9, color: AppColors.textGray),
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Exam Title',
                controller: _titleController,
                hint: 'e.g., Admission Test 2026',
                required: true,
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Category',
                value: _selectedCategory,
                items: const [
                  'admission',
                  'aptitude',
                  'quantitative',
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _selectedCategory = value);
                },
              ),
              const SizedBox(height: 16),
              _buildSection('Exam Configuration'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildNumberField(
                      label: 'Total Items',
                      controller: _totalItemsController,
                      required: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildNumberField(
                      label: 'Duration (min)',
                      controller: _durationController,
                      required: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Answer Sheet Template',
                value: _selectedTemplate,
                items: const [
                  'Default-50',
                  'Default-100',
                  'Admission-200',
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _selectedTemplate = value);
                },
              ),
              const SizedBox(height: 16),
              _buildSection('Organization'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildTextField(
                      label: 'Academic Year',
                      controller: _academicYearController,
                      required: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(
                      label: 'Semester',
                      controller: _semesterController,
                      required: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildSection('Instructions'),
              const SizedBox(height: 16),
              _buildTextArea(
                label: 'Instructions',
                controller: _instructionsController,
                hint: 'Enter exam instructions for examinees...',
                maxLines: 4,
              ),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isLoading ? 'Creating...' : 'Create Exam',
                onPressed: _isLoading ? null : _createExam,
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
    Widget? suffix,
    String? Function(String?)? validator,
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
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: suffix,
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

  Widget _buildTextArea({
    required String label,
    required TextEditingController controller,
    String? hint,
    int maxLines = 3,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
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
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<String> items,
    required Function(String?) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          value: value,
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
          items: items.map((item) {
            return DropdownMenuItem(
              value: item,
              child: Text(
                item,
                style: AppTextStyles.body(size: 11),
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
