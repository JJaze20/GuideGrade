import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/answer_key.dart';
import '../../../models/exam.dart';
import '../widgets/answer_key_question.dart';

/// Answer Key Management screen for Guidance Council users.
/// Allows creation, viewing, and editing of answer keys for exams.
class AnswerKeyManagementScreen extends StatefulWidget {
  final ExamModel? exam;
  
  const AnswerKeyManagementScreen({super.key, this.exam});

  @override
  State<AnswerKeyManagementScreen> createState() => _AnswerKeyManagementScreenState();
}

class _AnswerKeyManagementScreenState extends State<AnswerKeyManagementScreen> {
  final FirestoreService _firestoreService = FirestoreService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  
  final _formKey = GlobalKey<FormState>();
  
  ExamModel? _exam;
  AnswerKeyModel? _answerKey;
  
  Map<String, String> _answers = {};
  String _version = '1.0';
  bool _isLoading = true;
  bool _isSaving = false;
  String _validationError = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
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
      _isLoading = false;
    });

    // Load existing answer key
    await _loadAnswerKey();
  }

  Future<void> _loadAnswerKey() async {
    if (_exam == null) return;

    try {
      final existingKey = await _firestoreService.getAnswerKeyByExamId(_exam!.examId);
      if (existingKey != null) {
        setState(() {
          _answerKey = existingKey;
          _answers = Map.from(existingKey.answers);
          _version = existingKey.version;
        });
      }
    } catch (e) {
      print('Error loading answer key: $e');
    }
  }

  Future<void> _saveDraft() async {
    if (_exam == null) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to get user information')),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      // Validate
      final validationError = _validateAnswers();
      if (validationError != null) {
        setState(() {
          _validationError = validationError;
          _isSaving = false;
        });
        return;
      }

      setState(() => _validationError = '');

      if (_answerKey == null) {
        // Create new answer key
        final newAnswerKey = AnswerKeyModel(
          answerKeyId: '',
          examId: _exam!.examId,
          version: '1.0',
          status: 'Draft',
          answerFormat: 'multiple_choice',
          allowedChoices: ['A', 'B', 'C', 'D'],
          answers: _answers,
          totalItems: _exam!.totalItems,
          createdByUid: currentUser.uid,
          createdByName: currentUser.displayName ?? 'Unknown',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final answerKeyId = await _firestoreService.createAnswerKey(newAnswerKey);
        
        setState(() {
          _answerKey = newAnswerKey.copyWith(answerKeyId: answerKeyId);
          _version = '1.0';
        });
      } else {
        // Update existing answer key
        final updatedKey = _answerKey!.copyWith(
          answers: _answers,
          version: _incrementVersion(_answerKey!.version),
          updatedAt: DateTime.now(),
        );

        await _firestoreService.updateAnswerKey(updatedKey);
        
        setState(() {
          _answerKey = updatedKey;
          _version = updatedKey.version;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Answer key saved successfully!')),
        );
      }
    } catch (e) {
      print('Error saving answer key: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving answer key: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _finalizeAnswerKey() async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Finalize Answer Key'),
        content: const Text('Once finalized, this Answer Key cannot be edited while the Exam is Ready.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Finalize'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // Validate before finalizing
    final validationError = _validateAnswers();
    if (validationError != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(validationError)),
        );
      }
      return;
    }

    setState(() => _isSaving = true);

    try {
      if (_answerKey == null) {
        // First finalize - save as Final directly
        final currentUser = _auth.currentUser;
        if (currentUser == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Unable to get user information')),
            );
          }
          setState(() => _isSaving = false);
          return;
        }

        final newAnswerKey = AnswerKeyModel(
          answerKeyId: '',
          examId: _exam!.examId,
          version: '1.0',
          status: 'Final',
          answerFormat: 'multiple_choice',
          allowedChoices: ['A', 'B', 'C', 'D'],
          answers: _answers,
          totalItems: _exam!.totalItems,
          createdByUid: currentUser.uid,
          createdByName: currentUser.displayName ?? 'Unknown',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final answerKeyId = await _firestoreService.createAnswerKey(newAnswerKey);
        
        setState(() {
          _answerKey = newAnswerKey.copyWith(answerKeyId: answerKeyId);
          _version = '1.0';
        });
      } else {
        // Update to Final
        final updatedKey = _answerKey!.copyWith(
          answers: _answers,
          status: 'Final',
          version: _incrementMajorVersion(_answerKey!.version),
          updatedAt: DateTime.now(),
        );

        await _firestoreService.updateAnswerKey(updatedKey);
        
        setState(() {
          _answerKey = updatedKey;
          _version = updatedKey.version;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Answer key finalized!')),
        );
      }
    } catch (e) {
      print('Error finalizing answer key: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error finalizing answer key: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  String? _validateAnswers() {
    if (_exam == null) return 'Exam data not loaded';

    // Check for blank answers
    final blankQuestions = <int>[];
    for (int i = 1; i <= _exam!.totalItems; i++) {
      if (!_answers.containsKey(i.toString()) || _answers[i.toString()]!.isEmpty) {
        blankQuestions.add(i);
      }
    }

    if (blankQuestions.isNotEmpty) {
      return 'Please provide answers for questions: ${blankQuestions.join(', ')}';
    }

    // Check answer count matches totalItems
    if (_answers.length != _exam!.totalItems) {
      return 'Number of answers (${_answers.length}) must match total items (${_exam!.totalItems})';
    }

    // Check answers are in allowed choices
    if (_answerKey != null) {
      for (final entry in _answers.entries) {
        if (!_answerKey!.allowedChoices.contains(entry.value)) {
          return 'Invalid answer for question ${entry.key}: ${entry.value}';
        }
      }
    }

    return null;
  }

  String _incrementVersion(String currentVersion) {
    // Simple version increment: 1.0 -> 1.1 -> 1.2 -> 1.3
    final parts = currentVersion.split('.');
    if (parts.length == 2) {
      final major = int.tryParse(parts[0]) ?? 1;
      final minor = int.tryParse(parts[1]) ?? 0;
      return '$major.${minor + 1}';
    }
    return '1.1';
  }

  String _incrementMajorVersion(String currentVersion) {
    // Major version increment: 1.3 -> 2.0
    final parts = currentVersion.split('.');
    if (parts.length == 2) {
      final major = int.tryParse(parts[0]) ?? 1;
      return '${major + 1}.0';
    }
    return '2.0';
  }

  bool get _isReadOnly {
    if (_exam == null) return true;
    if (_exam!.isArchived) return true;
    if (_exam!.isReady) return true;
    return false;
  }

  bool get _canFinalize {
    if (_answerKey == null) return true;
    return _answerKey!.isDraft;
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

    final isReadOnly = _isReadOnly;

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Answer Key Management', style: AppTextStyles.heading(size: 13)),
        actions: [
          if (!isReadOnly)
            IconButton(
              icon: const FaIcon(FontAwesomeIcons.rotateRight, size: 18),
              onPressed: _loadAnswerKey,
            ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Exam information
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _exam!.title,
                      style: AppTextStyles.heading(size: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Code: ${_exam!.examCode}',
                      style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildInfoChip('Total Items', '${_exam!.totalItems}'),
                        const SizedBox(width: 8),
                        _buildInfoChip('Status', _exam!.status),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Answer key information
              if (_answerKey != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.cardBorder),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Answer Key',
                            style: AppTextStyles.body(size: 11, weight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Version: $_version',
                            style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                          ),
                        ],
                      ),
                      _buildStatusChip(_answerKey!.status),
                    ],
                  ),
                ),
              const SizedBox(height: 16),

              // Validation error
              if (_validationError.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const FaIcon(FontAwesomeIcons.circleExclamation, size: 16, color: Colors.red),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _validationError,
                          style: AppTextStyles.body(size: 10, color: Colors.red.shade900),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),

              // Questions
              Text(
                'Answers',
                style: AppTextStyles.body(size: 11, weight: FontWeight.w700, color: AppColors.primaryGreen),
              ),
              const SizedBox(height: 12),

              ...List.generate(_exam!.totalItems, (index) {
                final questionNum = index + 1;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AnswerKeyQuestion(
                    questionNumber: questionNum,
                    selectedAnswer: _answers[questionNum.toString()],
                    allowedChoices: _answerKey?.allowedChoices ?? ['A', 'B', 'C', 'D'],
                    enabled: !isReadOnly,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _answers[questionNum.toString()] = value;
                        });
                      }
                    },
                  ),
                );
              }),

              const SizedBox(height: 24),

              // Actions
              if (!isReadOnly)
                Column(
                  children: [
                    ElevatedButton(
                      onPressed: _isSaving ? null : _saveDraft,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGreen,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isSaving)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          else
                            const FaIcon(FontAwesomeIcons.floppyDisk, size: 14),
                          const SizedBox(width: 8),
                          Text(
                            _isSaving ? 'Saving...' : 'Save Draft',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_canFinalize)
                      ElevatedButton(
                        onPressed: _isSaving ? null : _finalizeAnswerKey,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.darkNavy,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_isSaving)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            else
                              const FaIcon(FontAwesomeIcons.check, size: 14),
                            const SizedBox(width: 8),
                            Text(
                              _isSaving ? 'Finalizing...' : 'Finalize',
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.lightBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '$label: $value',
        style: AppTextStyles.body(size: 9.5, color: AppColors.textGray),
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color backgroundColor;
    Color textColor;

    switch (status) {
      case 'Draft':
        backgroundColor = const Color(0xFFFEF3C7);
        textColor = const Color(0xFF92400E);
        break;
      case 'Final':
        backgroundColor = const Color(0xFFD1FAE5);
        textColor = const Color(0xFF065F46);
        break;
      default:
        backgroundColor = const Color(0xFFF3F4F6);
        textColor = const Color(0xFF374151);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status,
        style: AppTextStyles.body(
          size: 10,
          weight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }
}
