import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/batch/batch_lifecycle.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/state/app_state.dart';
import '../../../models/local_batch.dart';
import '../../../shared/widgets/form_field_decoration.dart';
import '../../../shared/widgets/primary_button.dart';

/// Edit Batch screen for Guidance Council users.
///
/// Every input has a visible outline in every state (resting, focused,
/// disabled, error — see [FormFieldStyle]), required fields carry a red `*`,
/// and problems are explained under the field they belong to.
///
/// The batch's status is never picked here: it is derived from the fields
/// (see [BatchLifecycle]) and shown read-only, with an explanation. The batch
/// code and exam are fixed once a batch exists; the description and the
/// expected sheet count stay editable in every status, Archived included —
/// saving simply re-evaluates the status (and an edited Archived batch is
/// archived again once its new revision reaches the cloud).
class EditBatchScreen extends StatefulWidget {
  final LocalBatch? batch;

  const EditBatchScreen({super.key, this.batch});

  @override
  State<EditBatchScreen> createState() => _EditBatchScreenState();
}

class _EditBatchScreenState extends State<EditBatchScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _batchCodeController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _expectedCountController;

  bool _isLoading = true;
  bool _isSaving = false;

  LocalBatch? _batch;

  @override
  void initState() {
    super.initState();
    _loadBatch();
  }

  Future<void> _loadBatch() async {
    final args =
        widget.batch ??
        ModalRoute.of(context)?.settings.arguments as LocalBatch?;
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
      _expectedCountController = TextEditingController(
        text: args.expectedCount.toString(),
      );
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    if (!_isLoading || _batch != null) {
      _batchCodeController.dispose();
      _descriptionController.dispose();
      _expectedCountController.dispose();
    }
    super.dispose();
  }

  Future<void> _saveBatch() async {
    if (_batch == null || _isSaving || _batch!.isCompleted)
      return; // ignore repeated taps
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      // Status is not passed on: the repository derives it from the saved
      // fields (Draft/Active), and archiving only follows cloud confirmation.
      final updatedBatch = _batch!.copyWith(
        description: _descriptionController.text.trim(),
        expectedCount: int.parse(_expectedCountController.text.trim()),
      );

      await AppStateScope.of(context).batchRepository.updateBatch(updatedBatch);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Batch updated successfully!')),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      debugPrint('Error updating batch: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error updating batch: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// What the status would be if the form were saved as it stands now — the
  /// same rules the repository applies on save.
  String get _statusIfSaved {
    final count = int.tryParse(_expectedCountController.text.trim()) ?? 0;
    final problems = BatchLifecycle.problems(
      batchCode: _batch!.batchCode,
      examCode: _batch!.examCode,
      expectedCount: count,
    );
    return BatchLifecycle.statusAfterSave(problems);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_batch == null) {
      return const Scaffold(body: Center(child: Text('Error loading batch')));
    }

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text(
          _batch!.isCompleted ? 'Completed Batch' : 'Edit Batch',
          style: AppTextStyles.heading(size: 13),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(16),
            children: [
              _buildSection('Basic Information'),
              const SizedBox(height: 14),
              TextFormField(
                key: const Key('editBatch.batchCode'),
                controller: _batchCodeController,
                enabled: false,
                decoration: FormFieldStyle.disabled(
                  label: 'Batch code',
                  required: true,
                  helper:
                      'Assigned when the batch was created and can not be changed.',
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const Key('editBatch.description'),
                controller: _descriptionController,
                enabled: !_batch!.isCompleted,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 120,
                decoration: FormFieldStyle.decoration(
                  label: 'Description (optional)',
                  hint: 'e.g., Morning Session A',
                  helper: 'Optional. Does not affect the batch status.',
                ),
              ),
              const SizedBox(height: 8),
              _buildSection('Exam Information'),
              const SizedBox(height: 14),
              _buildInfoField('Exam Code', _batch!.examCode),
              const SizedBox(height: 10),
              _buildInfoField('Exam Title', _batch!.examTitle),
              const SizedBox(height: 20),
              _buildSection('Batch Configuration'),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('editBatch.expectedCount'),
                      controller: _expectedCountController,
                      enabled: !_batch!.isCompleted,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(5),
                      ],
                      textInputAction: TextInputAction.done,
                      onChanged: (_) =>
                          setState(() {}), // refresh the status preview
                      onFieldSubmitted: (_) => _saveBatch(),
                      decoration: FormFieldStyle.decoration(
                        label: 'Expected sheets',
                        required: true,
                        // The count is a hard scan cap (LocalBatch.isFull), so
                        // it can never go below the sheets already saved.
                        helper: _batch!.scanCount > 0
                            ? 'At least ${_batch!.scanCount} (already scanned).'
                            : null,
                      ),
                      validator: (value) {
                        final t = value?.trim() ?? '';
                        if (t.isEmpty)
                          return 'Required. Enter how many sheets to expect.';
                        final number = int.tryParse(t);
                        if (number == null || number <= 0)
                          return 'Enter a whole number greater than zero.';
                        if (number < _batch!.scanCount) {
                          return 'Must be at least ${_batch!.scanCount}, the sheets already saved.';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildInfoField(
                      'Scans captured',
                      '${_batch!.scanCount}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _buildSection('Status'),
              const SizedBox(height: 14),
              _buildStatusCard(),
              const SizedBox(height: 24),
              PrimaryButton(
                label: _isSaving ? 'Saving...' : 'Save Changes',
                onPressed: _isSaving || _batch!.isCompleted ? null : _saveBatch,
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
      style: AppTextStyles.body(
        size: 11,
        weight: FontWeight.w700,
        color: AppColors.primaryGreen,
      ),
    );
  }

  Widget _buildInfoField(String label, String value) {
    return InputDecorator(
      decoration: FormFieldStyle.disabled(label: label),
      child: Text(value, style: AppTextStyles.body(size: 12)),
    );
  }

  /// The batch's status, read-only, with the rule that produced it.
  Widget _buildStatusCard() {
    final current = _batch!.status;
    final ifSaved = _batch!.isCompleted ? 'Completed' : _statusIfSaved;
    final String explanation = switch (ifSaved) {
      'Completed' =>
        'Completed batches are read-only. Description and expected sheets cannot be changed.',
      BatchLifecycle.draft =>
        'Draft: a required field is missing or invalid. '
            'Fill in every field marked * to make this batch Active.',
      _ =>
        'Active: every required field is filled in. The batch becomes Archived '
            'automatically once the cloud has confirmed this saved version.',
    };
    return Container(
      key: const Key('editBatch.statusCard'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: FormFieldStyle.disabledFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: FormFieldStyle.disabledBorder,
          width: FormFieldStyle.restingWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const FaIcon(
                FontAwesomeIcons.lock,
                size: 11,
                color: AppColors.textGray,
              ),
              const SizedBox(width: 8),
              Text(
                'Current status: ',
                style: AppTextStyles.body(size: 11, color: AppColors.textGray),
              ),
              Text(
                current,
                style: AppTextStyles.body(size: 11.5, weight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Set automatically — it can not be chosen by hand.',
            style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
          ),
          const SizedBox(height: 8),
          Text(
            _batch!.isCompleted ? explanation : 'If saved now: $explanation',
            key: const Key('editBatch.statusExplanation'),
            style: AppTextStyles.body(size: 10.5),
          ),
          if (current == BatchLifecycle.archived) ...[
            const SizedBox(height: 8),
            Text(
              'This batch is Archived. Saving a change makes it Active again until the change reaches the cloud.',
              style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
            ),
          ],
        ],
      ),
    );
  }
}
