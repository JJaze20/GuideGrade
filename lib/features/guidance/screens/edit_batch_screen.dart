import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/batch.dart';
import '../../../shared/widgets/primary_button.dart';

/// Edit Batch screen for Guidance Council users.
/// Allows editing of existing batches with status-based restrictions.
class EditBatchScreen extends StatefulWidget {
  final BatchModel? batch;
  
  const EditBatchScreen({super.key, this.batch});

  @override
  State<EditBatchScreen> createState() => _EditBatchScreenState();
}

class _EditBatchScreenState extends State<EditBatchScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  
  final _formKey = GlobalKey<FormState>();
  
  late final TextEditingController _batchCodeController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _expectedCountController;
  
  late String _selectedStatus;
  
  bool _isLoading = true;
  bool _isSaving = false;
  
  BatchModel? _batch;

  @override
  void initState() {
    super.initState();
    _loadBatch();
  }

  Future<void> _loadBatch() async {
    final args = widget.batch ?? ModalRoute.of(context)?.settings.arguments as BatchModel?;
    if (args == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error: No batch data provided')),
        );
        Navigator.of(context).pop();
      }
      return;
    }

    setState(() {
      _batch = args;
      _batchCodeController = TextEditingController(text: args.batchCode);
      _descriptionController = TextEditingController(text: args.description);
      _expectedCountController = TextEditingController(text: args.expectedCount.toString());
      _selectedStatus = args.status;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _batchCodeController.dispose();
    _descriptionController.dispose();
    _expectedCountController.dispose();
    super.dispose();
  }

  Future<void> _saveBatch() async {
    if (_batch == null) return;
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _isSaving = true);

    try {
      // Update batch
      final updatedBatch = _batch!.copyWith(
        description: _descriptionController.text.trim(),
        expectedCount: int.parse(_expectedCountController.text),
        status: _selectedStatus,
        updatedAt: DateTime.now(),
      );

      await _firestoreService.updateBatch(updatedBatch);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Batch updated successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      print('Error updating batch: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating batch: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool _isFieldEditable(String fieldName) {
    if (_batch == null) return false;
    
    switch (_batch!.status) {
      case 'Draft':
        // All fields editable except exam linkage
        return fieldName != 'exam';
      case 'Active':
        // Only description and actualCount editable
        return fieldName == 'description' || fieldName == 'actualCount';
      case 'Completed':
        // Only description editable
        return fieldName == 'description';
      case 'Archived':
        // Nothing editable
        return false;
      default:
        return false;
    }
  }

  void _navigateToExamineeManagement() async {
    if (_batch == null) return;
    
    final result = await Navigator.of(context).pushNamed(
      AppRoutes.examineeManagement,
      arguments: _batch,
    );
    
    if (result == true) {
      // Reload batch to update actualCount
      await _loadBatch();
    }
  }

  List<String> _getAvailableStatusOptions() {
    if (_batch == null) return ['Draft'];
    
    switch (_batch!.status) {
      case 'Draft':
        return ['Draft', 'Active', 'Archived'];
      case 'Active':
        return ['Active', 'Completed', 'Archived'];
      case 'Completed':
        return ['Completed', 'Archived'];
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

    if (_batch == null) {
      return const Scaffold(
        body: Center(child: Text('Error loading batch')),
      );
    }

    final isArchived = _batch!.isArchived;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Edit Batch', style: AppTextStyles.heading(size: 13)),
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
                label: 'Batch Code',
                controller: _batchCodeController,
                hint: 'e.g., B-2026-001',
                required: true,
                enabled: false,
              ),
              const SizedBox(height: 12),
              _buildTextField(
                label: 'Description',
                controller: _descriptionController,
                hint: 'e.g., Morning Session A',
                required: false,
                enabled: _isFieldEditable('description'),
              ),
              const SizedBox(height: 16),
              _buildSection('Exam Information'),
              const SizedBox(height: 16),
              _buildInfoField('Exam Code', _batch!.examCode),
              const SizedBox(height: 8),
              _buildInfoField('Exam Title', _batch!.examTitle),
              const SizedBox(height: 16),
              _buildSection('Batch Configuration'),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildNumberField(
                      label: 'Expected Count',
                      controller: _expectedCountController,
                      required: true,
                      enabled: _isFieldEditable('expectedCount'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildInfoField('Actual Count', '${_batch!.actualCount}'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildSection('Status'),
              const SizedBox(height: 16),
              _buildDropdown(
                label: 'Batch Status',
                value: _selectedStatus,
                items: _getAvailableStatusOptions(),
                onChanged: (value) {
                  if (value != null) setState(() => _selectedStatus = value);
                },
                enabled: !isArchived,
              ),
              const SizedBox(height: 24),
              if (!isArchived)
                PrimaryButton(
                  label: _isSaving ? 'Saving...' : 'Save Changes',
                  onPressed: _isSaving ? null : _saveBatch,
                ),
              const SizedBox(height: 12),
              
              // Examinee Management Button
              ElevatedButton.icon(
                onPressed: () => _navigateToExamineeManagement(),
                icon: const FaIcon(FontAwesomeIcons.users, size: 14),
                label: Text(
                  'Manage Examinees (${_batch!.actualCount})',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
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
