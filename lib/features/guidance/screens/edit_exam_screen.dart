import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/exam.dart';
import '../../../models/answer_key.dart';
import '../../../shared/widgets/primary_button.dart';

/// Edit Exam screen for Guidance Council users.
/// Allows editing of existing exams with status-based restrictions.
class EditExamScreen extends StatefulWidget {
  final ExamModel? exam;
  
  const EditExamScreen({super.key, this.exam});

  @override
  State<EditExamScreen> createState() => _EditExamScreenState();
}

class _EditExamScreenState extends State<EditExamScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  
  final _formKey = GlobalKey<FormState>();
  
  AnswerKeyModel? _answerKey;
  
  late final TextEditingController _examCodeController;
  late final TextEditingController _titleController;
  late final TextEditingController _totalItemsController;
  late final TextEditingController _durationController;
  late final TextEditingController _instructionsController;
  late final TextEditingController _academicYearController;
  late final TextEditingController _semesterController;
  
  late String _selectedCategory;
  late String _selectedTemplate;
  late String _selectedStatus;
  
  bool _isLoading = true;
  bool _isSaving = false;
  bool _isCheckingCode = false;
  
  ExamModel? _exam;

  @override
  void initState() {
    super.initState();
    _loadExam();
  }

  Future<void> _loadExam() async {
    final args = widget.exam ?? ModalRoute.of(context)?.settings.arguments as ExamModel?;
    if (args == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: No exam data provided')),
        );
        Navigator.of(context).pop();
      }
      return;
    }

    setState(() {
      _exam = args;
      _examCodeController = TextEditingController(text: args.examCode);
      _titleController = TextEditingController(text: args.title);
      _totalItemsController = TextEditingController(text: args.totalItems.toString());
      _durationController = TextEditingController(text: args.duration.toString());
      _instructionsController = TextEditingController(text: args.instructions);
      _academicYearController = TextEditingController(text: args.academicYear);
      _semesterController = TextEditingController(text: args.semester);
      _selectedCategory = args.category;
      _selectedTemplate = args.answerSheetTemplate;
      _selectedStatus = args.status;
      _isLoading = false;
    });

    // Load answer key
    await _loadAnswerKey();
  }

  Future<void> _loadAnswerKey() async {
    if (_exam == null) return;
    
    try {
      final answerKey = await _firestoreService.getAnswerKeyByExamId(_exam!.examId);
      setState(() {
        _answerKey = answerKey;
      });
    } catch (e) {
      print('Error loading answer key: $e');
    }
  }

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

  Future<bool> _checkExamCodeUniqueness(String examCode) async {
    if (examCode.isEmpty) return false;
    if (_exam?.examCode == examCode) return true; // Same code, no change
    
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

  Future<void> _saveExam() async {
    if (_exam == null) return;
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Check exam code uniqueness if changed
      if (_examCodeController.text.trim() != _exam!.examCode) {
        final isUnique = await _checkExamCodeUniqueness(_examCodeController.text.trim());
        
        if (!isUnique) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Exam code already exists. Please use a different code.')),
            );
          }
          setState(() => _isSaving = false);
          return;
        }
      }

      // Validate totalItems change - prevent if answer key exists
      final newTotalItems = int.parse(_totalItemsController.text);
      if (_answerKey != null && newTotalItems != _exam!.totalItems) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot change total items after answer key is created.')),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      // Validate status change to Ready
      if (_selectedStatus == 'Ready' && _exam!.status != 'Ready') {
        if (_answerKey == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cannot mark exam as Ready without an answer key.')),
            );
          }
          setState(() => _isSaving = false);
          return;
        }

        if (_answerKey!.status != 'Final') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Cannot mark exam as Ready unless answer key is Final.')),
            );
          }
          setState(() => _isSaving = false);
          return;
        }
      }

      // Update exam
      final updatedExam = _exam!.copyWith(
        examCode: _examCodeController.text.trim(),
        title: _titleController.text.trim(),
        category: _selectedCategory,
        totalItems: newTotalItems,
        duration: int.parse(_durationController.text),
        instructions: _instructionsController.text.trim(),
        answerSheetTemplate: _selectedTemplate,
        status: _selectedStatus,
        academicYear: _academicYearController.text.trim(),
        semester: _semesterController.text.trim(),
        updatedAt: DateTime.now(),
      );

      await _firestoreService.updateExam(updatedExam);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Exam updated successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('Error updating exam: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating exam: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool _isFieldEditable(String fieldName) {
    if (_exam == null) return false;
    
    // Prevent editing totalItems if answer key exists
    if (fieldName == 'totalItems' && _answerKey != null) {
      return false;
    }
    
    switch (_exam!.status) {
      case 'Draft':
        // All fields editable (except totalItems if answer key exists)
        return true;
      case 'Ready':
        // Only instructions editable
        return fieldName == 'instructions';
      case 'Archived':
        // Nothing editable
        return false;
      default:
        return false;
    }
  }

  void _navigateToAnswerKeyManagement() async {
    if (_exam == null) return;
    
    final result = await Navigator.of(context).pushNamed(
      AppRoutes.answerKeyManagement,
      arguments: _exam,
    );
    
    if (result == true) {
      // Reload answer key if something changed
      await _loadAnswerKey();
    }
  }

  List<String> _getAvailableStatusOptions() {
    if (_exam == null) return ['Draft'];
    
    switch (_exam!.status) {
      case 'Draft':
        return ['Draft', 'Ready', 'Archived'];
      case 'Ready':
        return ['Ready', 'Archived'];
      case 'Archived':
        return ['Archived'];
      default:
        return ['Draft'];
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_exam == null) {
      return const Scaffold(
        body: Center(child: Text('Error loading exam')),
      );
    }

    final isArchived = _exam!.isArchived;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Edit Exam', style: AppTextStyles.heading(size: 13)),
        actions: [
          if (isArchived)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              margin: const EdgeInsets.only(right: 16),
              decoration: BoxDecoration(
                color: AppColors.textGray.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const FaIcon(FontAwesomeIcons.lock, size: 12, color: AppColors.textGray),
                  const SizedBox(width: 6),
                  Text('Read-Only', style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
                ],
              ),
            ),
        ],
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
                hint: 'e.g., AT-2026-001',
                required: true,
                enabled: _isFieldEditable('examCode'),
                suffix: _isCheckingCode
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Exam Title',
                controller: _titleController,
                hint: 'e.g., Admission Test 2026',
                required: true,
                enabled: _isFieldEditable('title'),
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Category',
                value: _selectedCategory,
                // 'personality' is discontinued and no longer selectable, but a
                // legacy exam already saved with that category must still be
                // shown without crashing the dropdown (its value must be one
                // of `items`), so it's appended only when it's the loaded value.
                items: [
                  'admission',
                  'aptitude',
                  'quantitative',
                  if (_selectedCategory == 'personality') 'personality',
                ],
                onChanged: _isFieldEditable('category')
                    ? (value) {
                        if (value != null) setState(() => _selectedCategory = value);
                      }
                    : null,
                enabled: _isFieldEditable('category'),
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
                      enabled: _isFieldEditable('totalItems'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildNumberField(
                      label: 'Duration (min)',
                      controller: _durationController,
                      required: true,
                      enabled: _isFieldEditable('duration'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Answer Sheet Template',
                value: _selectedTemplate,
                // Same reasoning as the Category dropdown above: 'Personality-300'
                // is discontinued but must not crash the dropdown for a legacy
                // exam that already has it saved.
                items: [
                  'Default-50',
                  'Default-100',
                  'Admission-200',
                  if (_selectedTemplate == 'Personality-300') 'Personality-300',
                ],
                onChanged: _isFieldEditable('answerSheetTemplate')
                    ? (value) {
                        if (value != null) setState(() => _selectedTemplate = value);
                      }
                    : null,
                enabled: _isFieldEditable('answerSheetTemplate'),
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
                      enabled: _isFieldEditable('academicYear'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildTextField(
                      label: 'Semester',
                      controller: _semesterController,
                      required: true,
                      enabled: _isFieldEditable('semester'),
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
                enabled: _isFieldEditable('instructions'),
              ),
              const SizedBox(height: 16),
              _buildSection('Status'),
              const SizedBox(height: 16),
              _buildDropdown(
                label: 'Exam Status',
                value: _selectedStatus,
                items: _getAvailableStatusOptions(),
                onChanged: (value) {
                  if (value != null) setState(() => _selectedStatus = value);
                },
                enabled: !isArchived,
              ),
              const SizedBox(height: 24),
              
              // Answer Key Management Button
              if (_exam!.status == 'Draft' || _exam!.status == 'Ready' || _exam!.status == 'Archived')
                ElevatedButton.icon(
                  onPressed: () => _navigateToAnswerKeyManagement(),
                  icon: const FaIcon(FontAwesomeIcons.key, size: 14),
                  label: Text(
                    _exam!.status == 'Draft' ? 'Manage Answer Key' : 'View Answer Key',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              const SizedBox(height: 12),
              
              if (!isArchived)
                PrimaryButton(
                  label: _isSaving ? 'Saving...' : 'Save Changes',
                  onPressed: _isSaving ? null : _saveExam,
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
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            if (required)
              Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
            if (!enabled)
              Text(' (Read-only)', style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          enabled: enabled,
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
            if (!enabled)
              Text(' (Read-only)', style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: TextInputType.number,
          enabled: enabled,
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
            filled: !enabled,
            fillColor: AppColors.lightBg.withOpacity(0.5),
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
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            if (!enabled)
              Text(' (Read-only)', style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
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

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<String> items,
    required void Function(String?)? onChanged,
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            if (!enabled)
              Text(' (Read-only)', style: AppTextStyles.body(size: 9, color: AppColors.textGray)),
          ],
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          initialValue: value,
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
            filled: !enabled,
            fillColor: AppColors.lightBg.withOpacity(0.5),
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
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}
