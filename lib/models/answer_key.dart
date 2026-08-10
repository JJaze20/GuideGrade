/// The correct choice per question for one exam code, entered manually by
/// staff (see AnswerKeyEntryScreen) rather than uploaded from a file.
///
/// Keyed by section name + item number, not item number alone: exam types
/// like TAT restart numbering at 1 in every section (Test I, Test II, Test
/// III each go 1..N), so a flat item-number key would collide across them.
class AnswerKey {
  final String examCode;
  final Map<String, String> correctChoices;

  const AnswerKey({required this.examCode, required this.correctChoices});

  static String keyFor(String sectionName, int itemNumber) => '$sectionName|$itemNumber';

  String? choiceFor(String sectionName, int itemNumber) => correctChoices[keyFor(sectionName, itemNumber)];
}
