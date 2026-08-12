import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/batch.dart';
import '../../../models/examinee.dart';
import '../../../shared/widgets/primary_button.dart';

/// Create Examinee screen for Guidance Council users.
/// Allows creation of new examinees linked to batches.
class CreateExamineeScreen extends StatefulWidget {
  final BatchModel? batch;
  
  const CreateExamineeScreen({super.key, this.batch});

  @override
  State<CreateExamineeScreen> createState() => _CreateExamineeScreenState();
}

class _CreateExamineeScreenState extends State<CreateExamineeScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  final _formKey = GlobalKey<FormState>();
  
  final _studentNumberController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _courseController = TextEditingController();
  final _yearLevelController = TextEditingController();
  
  String _selectedSex = 'Male';
  BatchModel? _selectedBatch;
  List<BatchModel> _availableBatches = [];
  
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadBatches();
  }

  @override
  void dispose() {
    _studentNumberController.dispose();
    _fullNameController.dispose();
    _courseController.dispose();
    _yearLevelController.dispose();
    super.dispose();
  }

  Future<void> _loadBatches() async {
    setState(() => _isLoading = true);
    
    try {
      // Only load Active batches
      final batches = await _firestoreService.getBatches();
      final activeBatches = batches.where((batch) => batch.status == 'Active').toList();
      
      setState(() {
        _availableBatches = activeBatches;
        _isLoading = false;
      });
      
      // Check if batch was passed as argument
      final args = widget.batch ?? ModalRoute.of(context)?.settings.arguments as BatchModel?;
      if (args != null && activeBatches.any((b) => b.batchId == args.batchId)) {
        setState(() => _selectedBatch = args);
      }
    } catch (e) {
      print('Error loading batches: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _createExaminee() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedBatch == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a batch')),
        );
      }
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Check student number uniqueness
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

      // Create examinee
      final examinee = ExamineeModel(
        examineeId: '',
        studentNumber: _studentNumberController.text.trim(),
        fullName: _fullNameController.text.trim(),
        course: _courseController.text.trim(),
        yearLevel: _yearLevelController.text.trim(),
        sex: _selectedSex,
        batchId: _selectedBatch!.batchId,
        examId: _selectedBatch!.examId,
        examCode: _selectedBatch!.examCode,
        examTitle: _selectedBatch!.examTitle,
        createdByUid: currentUser.uid,
        createdByName: currentUser.displayName ?? 'Unknown',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      await _firestoreService.createExaminee(examinee);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Examinee created successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('Error creating examinee: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error creating examinee: $e')),
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
        title: Text('Add Examinee', style: AppTextStyles.heading(size: 13)),
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
              _buildSection('Batch Assignment'),
              const SizedBox(height: 16),
              _buildBatchDropdown(),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isSaving ? 'Creating...' : 'Add Examinee',
                onPressed: _isSaving ? null : _createExaminee,
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

  Widget _buildBatchDropdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Batch', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w600)),
            Text(' *', style: AppTextStyles.body(size: 10.5, color: Colors.red)),
          ],
        ),
        const SizedBox(height: 6),
        if (_isLoading)
          const Center(child: CircularProgressIndicator())
        else if (_availableBatches.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Text(
              'No Active batches available. Please activate a batch first.',
              style: AppTextStyles.body(size: 10, color: AppColors.textGray),
            ),
          )
        else
          DropdownButtonFormField<BatchModel>(
            value: _selectedBatch,
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
            hint: Text('Select a batch', style: AppTextStyles.body(size: 11)),
            items: _availableBatches.map((batch) {
              return DropdownMenuItem(
                value: batch,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      batch.description.isNotEmpty ? batch.description : batch.batchCode,
                      style: AppTextStyles.body(size: 11),
                    ),
                    Text(
                      '${batch.examTitle} • ${batch.actualCount}/${batch.expectedCount} examinees',
                      style: AppTextStyles.body(size: 9, color: AppColors.textGray),
                    ),
                  ],
                ),
              );
            }).toList(),
            onChanged: (value) {
              setState(() => _selectedBatch = value);
            },
          ),
      ],
    );
  }
}
