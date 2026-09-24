/// The correct choice per question for one exam code, entered manually by
/// staff (see AnswerKeyEntryScreen) rather than uploaded from a file.
///
/// Keyed by section name + item number, not item number alone: exam types
/// like TAT restart numbering at 1 in every section (Test I, Test II, Test
/// III each go 1..N), so a flat item-number key would collide across them.
class AnswerKey {
  final String examCode;
  final Map<String, String> correctChoices;

  /// Optional device-local question text, using the same section/item IDs as
  /// [correctChoices]. Cloud answer-choice synchronization does not change it.
  final Map<String, String> questionTexts;

  const AnswerKey({
    required this.examCode,
    required this.correctChoices,
    this.questionTexts = const {},
  });

  static String keyFor(String sectionName, int itemNumber) => '$sectionName|$itemNumber';

  String? choiceFor(String sectionName, int itemNumber) => correctChoices[keyFor(sectionName, itemNumber)];

  Map<String, dynamic> toJson() => {
        'examCode': examCode,
        'correctChoices': correctChoices,
        'questionTexts': questionTexts,
      };

  factory AnswerKey.fromJson(Map<String, dynamic> json) => AnswerKey(
        examCode: json['examCode'] as String,
        correctChoices: Map<String, String>.from(json['correctChoices'] as Map),
        questionTexts: Map<String, String>.from(
          json['questionTexts'] as Map? ?? const {},
        ),
      );
}
