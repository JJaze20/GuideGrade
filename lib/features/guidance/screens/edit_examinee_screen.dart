import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/batch.dart';
import '../../../models/examinee.dart';
import '../../../shared/widgets/primary_button.dart';

/// Edit Examinee screen for Guidance Council users.
/// Allows editing of existing examinees.
class EditExamineeScreen extends StatefulWidget {
  final ExamineeModel? examinee;
  
  const EditExamineeScreen({super.key, this.examinee});

  @override
  State<EditExamineeScreen> createState() => _EditExamineeScreenState();
}

class _EditExamineeScreenState extends State<EditExamineeScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  
  final _formKey = GlobalKey<FormState>();
  
  late final TextEditingController _studentNumberController;
  late final TextEditingController _fullNameController;
  late final TextEditingController _courseController;
  late final TextEditingController _yearLevelController;
  
  late String _selectedSex;
  
  bool _isLoading = true;
  bool _isSaving = false;

  ExamineeModel? _examinee;

  /// The examinee's actual batch, fetched by [ExamineeModel.batchId] so the
  /// "Batch Code" field below can show the real, human-readable
  /// [BatchModel.batchCode] instead of the raw Firestore document ID that
  /// [ExamineeModel.batchId] actually is.
  BatchModel? _batch;

  @override
  void initState() {
    super.initState();
    _loadExaminee();
  }

  Future<void> _loadExaminee() async {
    final args = widget.examinee ?? ModalRoute.of(context)?.settings.arguments as ExamineeModel?;
    if (args == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: No examinee data provided')),
        );
        Navigator.of(context).pop();
      }
      return;
    }

    final batch = await _firestoreService.getBatchById(args.batchId);

    if (!mounted) return;
    setState(() {
      _examinee = args;
      _batch = batch;
      _studentNumberController = TextEditingController(text: args.studentNumber);
      _fullNameController = TextEditingController(text: args.fullName);
      _courseController = TextEditingController(text: args.course);
      _yearLevelController = TextEditingController(text: args.yearLevel);
      _selectedSex = args.sex;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _studentNumberController.dispose();
    _fullNameController.dispose();
    _courseController.dispose();
    _yearLevelController.dispose();
    super.dispose();
  }

  Future<void> _saveExaminee() async {
    if (_examinee == null) return;
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Check student number uniqueness if changed
      if (_studentNumberController.text.trim() != _examinee!.studentNumber) {
        final existingExaminee = await _firestoreService.getExamineeByStudentNumber(
          _studentNumberController.text.trim(),
        );
        
        if (existingExaminee != null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Student number already exists. Please use a different number.')),
            );
          }
          setState(() => _isSaving = false);
          return;
        }
      }

      // Update examinee
      final updatedExaminee = _examinee!.copyWith(
        studentNumber: _studentNumberController.text.trim(),
        fullName: _fullNameController.text.trim(),
        course: _courseController.text.trim(),
        yearLevel: _yearLevelController.text.trim(),
        sex: _selectedSex,
        updatedAt: DateTime.now(),
      );

      await _firestoreService.updateExaminee(updatedExaminee);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Examinee updated successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('Error updating examinee: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating examinee: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _deleteExaminee() async {
    if (_examinee == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Examinee'),
        content: const Text('Are you sure you want to delete this examinee? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSaving = true);

    try {
      await _firestoreService.deleteExaminee(_examinee!.examineeId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Examinee deleted successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('Error deleting examinee: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting examinee: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_examinee == null) {
      return const Scaffold(
        body: Center(child: Text('Error loading examinee')),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Edit Examinee', style: AppTextStyles.heading(size: 13)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.red),
            onPressed: _isSaving ? null : _deleteExaminee,
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSection('Student Information'),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Student Number / Applicant ID',
                controller: _studentNumberController,
                hint: 'e.g., 2026-0001',
                required: true,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Full Name',
                controller: _fullNameController,
                hint: 'e.g., Juan Dela Cruz',
                required: true,
              ),
              const SizedBox(height: 12),
              _buildDropdown(
                label: 'Sex',
                value: _selectedSex,
                items: const ['Male', 'Female'],
                onChanged: (value) {
                  if (value != null) setState(() => _selectedSex = value);
                },
              ),
              const SizedBox(height: 16),
              _buildSection('Academic Information'),
              const SizedBox(height: 16),
              _buildTextField(
                label: 'Course / Program',
                controller: _courseController,
                hint: 'e.g., BS Computer Science',
                required: false,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Year Level',
                controller: _yearLevelController,
                hint: 'e.g., 1st Year',
                required: false,
              ),
              const SizedBox(height: 16),
              _buildSection('Batch Information'),
              const SizedBox(height: 16),
              _buildInfoField('Batch Code', _batch?.batchCode ?? 'Unavailable'),
              const SizedBox(height: 8),
              _buildInfoField('Exam', _examinee!.examTitle),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isSaving ? 'Saving...' : 'Save Changes',
                onPressed: _isSaving ? null : _saveExaminee,
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
          validator: required
              ? (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'This field is required';
                  }
                  return null;
                }
              : null,
        ),
      ],
    );
  }

  Widget _buildInfoField(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.lightBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.cardBorder),
          ),
          child: Text(
            value,
            style: AppTextStyles.body(size: 11),
          ),
        ),
      ],
    );
  }

  Widget _buildDropdown({
    required String label,
    required String value,
    required List<String> items,
    required void Function(String?) onChanged,
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
