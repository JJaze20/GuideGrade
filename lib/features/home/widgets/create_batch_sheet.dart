import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/state/app_state.dart';
import '../../../shared/widgets/primary_button.dart';

/// Bottom sheet used to register a new diagnostic batch, matching the
/// "Create New Batch" modal in the HTML prototype.
class CreateBatchSheet extends StatefulWidget {
  const CreateBatchSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const CreateBatchSheet(),
    );
  }

  @override
  State<CreateBatchSheet> createState() => _CreateBatchSheetState();
}

class _CreateBatchSheetState extends State<CreateBatchSheet> {
  final _titleController = TextEditingController();
  final _namesController = TextEditingController();
  String _selectedType = 'AT';

  final Map<String, String> _typeOptions = const {
    'AT': 'Admission Exam (AT)',
    'PT': 'Personality Profile (PT)',
    'TAT': 'Teaching Aptitude Test (TAT)',
    'QTM': 'Quantitative Math Test (QTM)',
  };

  @override
  void dispose() {
    _titleController.dispose();
    _namesController.dispose();
    super.dispose();
  }

  void _save() {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid Batch Code identification.')),
      );
      return;
    }

    AppStateScope.of(context).addBatch(title: title, typeCode: _selectedType);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Registered $title into un-checked session queues!')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const FaIcon(FontAwesomeIcons.folderPlus, size: 16, color: AppColors.primaryGreen),
              const SizedBox(width: 8),
              Text('Create New Batch', style: AppTextStyles.heading(size: 15)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Register a group target code and populate its initial un-checked examinee roster profiles.',
            style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
          ),
          const SizedBox(height: 16),
          Text('Batch Roster Code/Title', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(hintText: 'e.g., Batch 05-C'),
          ),
          const SizedBox(height: 12),
          Text('Target Assessment Type', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          DropdownButtonFormField<String>(
            value: _selectedType,
            decoration: const InputDecoration(),
            items: _typeOptions.entries
                .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: AppTextStyles.body(size: 12))))
                .toList(),
            onChanged: (v) => setState(() => _selectedType = v ?? 'AT'),
          ),
          const SizedBox(height: 12),
          Text('Add Examinees (Comma Separated Names)', style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700)),
          const SizedBox(height: 4),
          TextField(
            controller: _namesController,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'JUAN DELA CRUZ, MARIA CLARA, PEDRO PENDUKO'),
          ),
          const SizedBox(height: 18),
          PrimaryButton(label: 'SAVE & REGISTER BATCH', onPressed: _save),
          const SizedBox(height: 8),
          SecondaryButton(label: 'Dismiss', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}
