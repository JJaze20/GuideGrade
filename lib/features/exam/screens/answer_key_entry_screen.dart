import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_text_styles.dart';
import '../../../core/omr/omr_templates.dart';
import '../../../core/state/app_state.dart';
import '../../../models/answer_key.dart';
import '../../../shared/widgets/primary_button.dart';

/// Manual answer-key entry: tap the correct choice per question (like
/// ZipGrade's key-entry flow) instead of uploading a file. Reuses the same
/// OmrExamTemplate question/choice data that drives the scanner, so the
/// key always matches whatever's actually printed on the sheet.
class AnswerKeyEntryScreen extends StatefulWidget {
  const AnswerKeyEntryScreen({super.key});

  @override
  State<AnswerKeyEntryScreen> createState() => _AnswerKeyEntryScreenState();
}

class _AnswerKeyEntryScreenState extends State<AnswerKeyEntryScreen> {
  final Map<String, String> _selections = {};
  bool _loadedExisting = false;

  @override
  Widget build(BuildContext context) {
    final appState = AppStateScope.of(context);
    final template = omrTemplates[appState.activeExamCode];

    if (!_loadedExisting) {
      final existing = appState.answerKeys[appState.activeExamCode];
      if (existing != null) _selections.addAll(existing.correctChoices);
      _loadedExisting = true;
    }

    if (template == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Answer Key')),
        body: Center(
          child: Text('No sheet layout is defined for exam code "${appState.activeExamCode}".'),
        ),
      );
    }

    final totalItems = template.sections.fold<int>(0, (sum, s) => sum + s.itemCount);

    return Scaffold(
      backgroundColor: AppColors.lightBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textDark,
        elevation: 0.5,
        title: Text('Answer Key — ${appState.activeExamCode}', style: AppTextStyles.heading(size: 13)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  const FaIcon(FontAwesomeIcons.key, color: AppColors.primaryGreen, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tap the correct choice for each question.',
                      style: AppTextStyles.body(size: 10.5, color: AppColors.textGray),
                    ),
                  ),
                  Text(
                    '${_selections.length}/$totalItems answered',
                    style: AppTextStyles.body(size: 10, weight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: template.sections.length,
                itemBuilder: (context, sectionIndex) => _buildSectionCard(template.sections[sectionIndex]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: PrimaryButton(
                label: 'SAVE ANSWER KEY',
                onPressed: () {
                  appState.setAnswerKey(
                    AnswerKey(examCode: appState.activeExamCode, correctChoices: Map.of(_selections)),
                  );
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionCard(OmrSection section) {
    final itemNumbers = section.items.keys.toList()..sort();
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(section.name, style: AppTextStyles.body(size: 11, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          ...itemNumbers.map((itemNumber) => _buildQuestionRow(section, itemNumber)),
        ],
      ),
    );
  }

  Widget _buildQuestionRow(OmrSection section, int itemNumber) {
    final choices = section.items[itemNumber]!;
    final key = AnswerKey.keyFor(section.name, itemNumber);
    final selected = _selections[key];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 30,
            child: Text('$itemNumber.', style: AppTextStyles.body(size: 10, color: AppColors.textGray)),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: choices.map((bubble) => _buildChoiceBubble(key, bubble.choice, selected)).toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChoiceBubble(String key, String choice, String? selected) {
    final isSelected = choice == selected;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() {
        if (isSelected) {
          _selections.remove(key);
        } else {
          _selections[key] = choice;
        }
      }),
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? AppColors.primaryGreen : AppColors.lightBg,
          shape: BoxShape.circle,
          border: Border.all(color: isSelected ? AppColors.primaryGreen : const Color(0xFFCBD5E1)),
        ),
        child: Text(
          choice,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: isSelected ? Colors.white : AppColors.textDark,
          ),
        ),
      ),
    );
  }
}
