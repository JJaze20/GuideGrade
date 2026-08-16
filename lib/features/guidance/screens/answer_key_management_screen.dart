import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/answer_key_adapter.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/services/firestore_service.dart';
import '../../../models/answer_key.dart';
import '../../../models/exam.dart';
import '../widgets/answer_key_question.dart';

/// Answer Key Management screen for Guidance Council users.
///
/// Section-aware: structure (which sections exist, how many items each
/// has, which choices are valid per item) is always derived from
/// omrTemplates[exam.examCode] -- never a flat 1..totalItems loop and
/// never a locally-hardcoded choice list, so this works correctly for
/// single-section exams (QTM, Admission) and multi-section exams (TAT's
/// Test I / Test II / Test III, which each restart numbering at 1) alike.
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
  OmrExamTemplate? _template;
  AnswerKeyModel? _answerKey;

  Map<String, Map<String, String>> _answers = {};
  String _version = '1.0';
  bool _isLoading = true;
  bool _isSaving = false;
  String _validationError = '';

  /// Non-empty when the loaded key predates section support -- explains
  /// what was (or wasn't) carried over into [_answers].
  String _compatibilityNote = '';

  /// True only for a legacy TAT key: its structure can't be safely
  /// reinterpreted at all, so every field starts blank and must be
  /// re-entered before this key can be saved/finalized again.
  bool _isLegacyBlocked = false;

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

    final template = omrTemplates[args.examCode];

    setState(() {
      _exam = args;
      _template = template;
      _answers = template != null ? emptySectionAnswers(template) : {};
      _isLoading = false;
    });

    await _loadAnswerKey();
  }

  Future<void> _loadAnswerKey() async {
    if (_exam == null || _template == null) return;

    try {
      final existingKey = await _firestoreService.getAnswerKeyByExamId(_exam!.examId);
      if (existingKey == null) {
        setState(() {
          _answerKey = null;
          _answers = emptySectionAnswers(_template!);
          _compatibilityNote = '';
          _isLegacyBlocked = false;
        });
        return;
      }

      if (existingKey.isLegacy) {
        final migration = migrateLegacyAnswerKeyForEditing(existingKey, _template!, _exam!.examCode);
        setState(() {
          _answerKey = existingKey;
          _version = existingKey.version;
          _answers = migration.blocked ? emptySectionAnswers(_template!) : migration.prefill;
          _compatibilityNote = migration.note;
          _isLegacyBlocked = migration.blocked;
        });
      } else {
        // Merge onto an empty template shape so a key saved under an older
        // (but still current-schema) template revision doesn't leave any
        // section/item missing from the editable state.
        final merged = emptySectionAnswers(_template!);
        existingKey.answers.forEach((sectionName, items) {
          if (merged.containsKey(sectionName)) merged[sectionName] = Map.of(items);
        });
        setState(() {
          _answerKey = existingKey;
          _version = existingKey.version;
          _answers = merged;
          _compatibilityNote = '';
          _isLegacyBlocked = false;
        });
      }
    } catch (e) {
      print('Error loading answer key: $e');
    }
  }

  Future<void> _saveDraft() async {
    if (_exam == null || _template == null) return;
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
        final newAnswerKey = AnswerKeyModel(
          answerKeyId: '',
          examId: _exam!.examId,
          version: '1.0',
          status: 'Draft',
          schemaVersion: AnswerKeyModel.currentSchemaVersion,
          answers: _answers,
          legacyFlatAnswers: const {},
          totalItems: _totalItems,
          createdByUid: currentUser.uid,
          createdByName: currentUser.displayName ?? 'Unknown',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final answerKeyId = await _firestoreService.createAnswerKey(newAnswerKey);

        setState(() {
          _answerKey = newAnswerKey.copyWith(answerKeyId: answerKeyId);
          _version = '1.0';
          _compatibilityNote = '';
          _isLegacyBlocked = false;
        });
      } else {
        final updatedKey = _answerKey!.copyWith(
          answers: _answers,
          version: _incrementVersion(_answerKey!.version),
          updatedAt: DateTime.now(),
        );

        await _firestoreService.updateAnswerKey(updatedKey);

        setState(() {
          _answerKey = updatedKey;
          _version = updatedKey.version;
          _compatibilityNote = '';
          _isLegacyBlocked = false;
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

      // Safe finalization: refuse if another Final key already exists for
      // this exam (e.g. a concurrent Guidance Council session finalized one
      // in the meantime), rather than silently ending up with two.
      final hasOther = await _firestoreService.hasOtherFinalAnswerKey(
        _exam!.examId,
        _answerKey?.answerKeyId ?? '',
      );
      if (hasOther) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Another Final answer key already exists for this exam. Refresh and review it before finalizing this one.',
              ),
            ),
          );
        }
        setState(() => _isSaving = false);
        return;
      }

      if (_answerKey == null) {
        final newAnswerKey = AnswerKeyModel(
          answerKeyId: '',
          examId: _exam!.examId,
          version: '1.0',
          status: 'Final',
          schemaVersion: AnswerKeyModel.currentSchemaVersion,
          answers: _answers,
          legacyFlatAnswers: const {},
          totalItems: _totalItems,
          createdByUid: currentUser.uid,
          createdByName: currentUser.displayName ?? 'Unknown',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final answerKeyId = await _firestoreService.createAnswerKey(newAnswerKey);

        setState(() {
          _answerKey = newAnswerKey.copyWith(answerKeyId: answerKeyId);
          _version = '1.0';
          _compatibilityNote = '';
          _isLegacyBlocked = false;
        });
      } else {
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
          _compatibilityNote = '';
          _isLegacyBlocked = false;
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

  int get _totalItems =>
      _template?.sections.fold<int>(0, (sum, s) => sum + s.itemCount) ?? _exam?.totalItems ?? 0;

  /// Section-aware validation: every item in every section of the template
  /// must have a non-empty, template-valid answer. Never a flat
  /// 1..totalItems loop -- that's exactly what let TAT's Test I/II/III
  /// collide under one continuous count before this rewrite.
  String? _validateAnswers() {
    if (_exam == null || _template == null) return 'Exam data not loaded';
    if (_isLegacyBlocked) {
      return 'This answer key predates section support and must be fully re-entered before saving.';
    }

    final missing = <String>[];
    for (final section in _template!.sections) {
      final sectionAnswers = _answers[section.name] ?? {};
      for (final itemNumber in section.items.keys) {
        final value = sectionAnswers[itemNumber.toString()];
        if (value == null || value.isEmpty) {
          missing.add('${section.name} Q$itemNumber');
        }
      }
    }
    if (missing.isNotEmpty) {
      final shown = missing.take(8).join(', ');
      final suffix = missing.length > 8 ? ' (+${missing.length - 8} more)' : '';
      return 'Please provide answers for: $shown$suffix';
    }

    for (final section in _template!.sections) {
      final sectionAnswers = _answers[section.name]!;
      for (final itemNumber in section.items.keys) {
        final valid = section.items[itemNumber]!.map((b) => b.choice).toSet();
        final value = sectionAnswers[itemNumber.toString()];
        if (!valid.contains(value)) {
          return 'Invalid answer for ${section.name} Q$itemNumber: $value';
        }
      }
    }

    return null;
  }

  String _incrementVersion(String currentVersion) {
    final parts = currentVersion.split('.');
    if (parts.length == 2) {
      final major = int.tryParse(parts[0]) ?? 1;
      final minor = int.tryParse(parts[1]) ?? 0;
      return '$major.${minor + 1}';
    }
    return '1.1';
  }

  String _incrementMajorVersion(String currentVersion) {
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

  void _setAnswer(String sectionName, int itemNumber, String value) {
    setState(() {
      _answers.putIfAbsent(sectionName, () => {});
      _answers[sectionName]![itemNumber.toString()] = value;
    });
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

    if (_template == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Answer Key Management')),
        body: Center(
          child: Text('No sheet layout is defined for exam code "${_exam!.examCode}".'),
        ),
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
                    Text(_exam!.title, style: AppTextStyles.heading(size: 13)),
                    const SizedBox(height: 4),
                    Text(
                      'Code: ${_exam!.examCode}',
                      style: AppTextStyles.body(size: 10, color: AppColors.textGray),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildInfoChip('Total Items', '$_totalItems'),
                        const SizedBox(width: 8),
                        _buildInfoChip('Sections', '${_template!.sections.length}'),
                        const SizedBox(width: 8),
                        _buildInfoChip('Status', _exam!.status),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

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
                          Text('Answer Key', style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
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

              if (_compatibilityNote.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: Colors.amber.shade900),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _compatibilityNote,
                          style: AppTextStyles.body(size: 10, color: Colors.amber.shade900),
                        ),
                      ),
                    ],
                  ),
                ),

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

              Text(
                'Answers',
                style: AppTextStyles.body(size: 11, weight: FontWeight.w700, color: AppColors.primaryGreen),
              ),
              const SizedBox(height: 12),

              // One card per OmrSection (Test I / Test II / Test III for
              // TAT, a single section for QTM/Admission), each with its own
              // independently-numbered items and its own valid choice set
              // per item -- sourced entirely from the template, not a
              // second stored copy.
              ..._template!.sections.map((section) => _buildSectionCard(section, isReadOnly)),

              const SizedBox(height: 24),

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

  Widget _buildSectionCard(OmrSection section, bool isReadOnly) {
    final itemNumbers = section.items.keys.toList()..sort();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${section.name}  ·  ${section.itemCount} items',
            style: AppTextStyles.body(size: 11.5, weight: FontWeight.w800, color: AppColors.primaryGreen),
          ),
          const SizedBox(height: 10),
          ...itemNumbers.map((itemNumber) {
            final choices = section.items[itemNumber]!.map((b) => b.choice).toList();
            final selected = _answers[section.name]?[itemNumber.toString()];
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: AnswerKeyQuestion(
                questionNumber: itemNumber,
                selectedAnswer: selected,
                allowedChoices: choices,
                enabled: !isReadOnly && !_isLegacyBlocked,
                onChanged: (value) {
                  if (value != null) _setAnswer(section.name, itemNumber, value);
                },
              ),
            );
          }),
        ],
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
        style: AppTextStyles.body(size: 10, weight: FontWeight.w600, color: textColor),
      ),
    );
  }
}
