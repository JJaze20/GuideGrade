import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/batch.dart';
import '../../../models/exam.dart';
import '../../../shared/widgets/primary_button.dart';

/// Create Batch screen for Guidance Council users.
/// Allows creation of new batches linked to exams.
class CreateBatchScreen extends StatefulWidget {
  const CreateBatchScreen({super.key});

  @override
  State<CreateBatchScreen> createState() => _CreateBatchScreenState();
}

class _CreateBatchScreenState extends State<CreateBatchScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  final _formKey = GlobalKey<FormState>();
  
  final _descriptionController = TextEditingController();
  final _expectedCountController = TextEditingController(text: '30');
  
  ExamModel? _selectedExam;
  List<ExamModel> _availableExams = [];
  String _generatedBatchCode = '';
  
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadExams();
    _generateBatchCode();
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _expectedCountController.dispose();
    super.dispose();
  }

  Future<void> _loadExams() async {
    setState(() => _isLoading = true);
    
    try {
      // Only load exams that are Ready (have Final answer keys)
      final exams = await _firestoreService.getExams();
      final readyExams = exams.where((exam) => exam.status == 'Ready').toList();
      
      setState(() {
        _availableExams = readyExams;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading exams: $e');
      setState(() => _isLoading = false);
    }
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

  Future<bool> _checkBatchCodeUniqueness(String batchCode) async {
    if (batchCode.isEmpty) return false;
    
    try {
      final existingBatch = await _firestoreService.getBatchByCode(batchCode);
      return existingBatch == null;
    } catch (e) {
      print('Error checking batch code: $e');
      return false;
    }
  }

  Future<void> _createBatch() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedExam == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an exam')),
        );
      }
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Check batch code uniqueness
      final isUnique = await _checkBatchCodeUniqueness(_generatedBatchCode);
      
      if (!isUnique) {
        _generateBatchCode(); // Generate new code
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Batch code already exists. Generated a new code.')),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      // Get current user
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to get user information.')),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      // Create batch
      final batch = BatchModel(
        batchId: '',
        batchCode: _generatedBatchCode,
        examId: _selectedExam!.examId,
        examCode: _selectedExam!.examCode,
        examTitle: _selectedExam!.title,
        status: 'Draft',
        description: _descriptionController.text.trim(),
        expectedCount: int.parse(_expectedCountController.text),
        actualCount: 0,
        createdByUid: currentUser.uid,
        createdByName: currentUser.displayName ?? 'Unknown',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await _firestoreService.createBatch(batch);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Batch created successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('Error creating batch: $e');
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
                hint: 'e.g., Morning Session A',
                required: false,
              ),
              const SizedBox(height: 16),
              _buildSection('Exam Selection'),
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
            Text('Exam', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
          ],
        ),
        const SizedBox(height: 6),
        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else if (_availableExams.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Text(
              'No Ready exams available. Please mark an exam as Ready first.',
              style: AppTextStyles.body(size: 10, color: AppColors.textGray),
            ),
          )
        else
          DropdownButtonFormField<ExamModel>(
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
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
            hint: Text('Select an exam', style: AppTextStyles.body(size: 11)),
            items: _availableExams.map((exam) {
              return DropdownMenuItem(
                value: exam,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      exam.title,
                      style: AppTextStyles.body(size: 11),
                    ),
                    Text(
                      '${exam.examCode} • ${exam.totalItems} items',
                      style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                    ),
                  ],
                ),
              );
            }).toList(),
            onChanged: (value) {
              setState(() => _selectedExam = value);
            },
          ),
      ],
    );
  }
}
