/// The correct choice per question for one exam code, entered manually by
/// staff (see AnswerKeyEntryScreen) rather than uploaded from a file.
///
/// Keyed by section name + item number, not item number alone: exam types
/// like TAT restart numbering at 1 in every section (Test I, Test II, Test
/// III each go 1..N), so a flat item-number key would collide across them.
///
/// [itemCategories] (Admission Test only, for now) records which subtest
/// each item belongs to -- `VC` / `VR` / `FR` / `QR` -- under the same
/// `"Section|Item"` keys. It is kept apart from [correctChoices] so nothing
/// that grades or counts answers ever sees it; only at the cloud boundary
/// are the two merged into one flat map (see [toCloudAnswers] /
/// [AnswerKey.fromCloudAnswers]), which lets the existing `answer_keys`
/// row carry the categories without a schema change.
class AnswerKey {
  final String examCode;
  final Map<String, String> correctChoices;
  final Map<String, String> itemCategories;

  const AnswerKey({
    required this.examCode,
    required this.correctChoices,
    this.itemCategories = const {},
  });

  /// Prefix marking a category entry inside the flat cloud `answers` map.
  /// A real answer key is always `"Section|Item"`, and no section is named
  /// `category`, so the two can never collide.
  static const String cloudCategoryPrefix = 'category|';

  static String keyFor(String sectionName, int itemNumber) => '$sectionName|$itemNumber';

  String? choiceFor(String sectionName, int itemNumber) => correctChoices[keyFor(sectionName, itemNumber)];

  String? categoryFor(String sectionName, int itemNumber) => itemCategories[keyFor(sectionName, itemNumber)];

  /// [correctChoices] plus every category as `"category|Section|Item" -> code`.
  Map<String, String> toCloudAnswers() => {
        ...correctChoices,
        for (final e in itemCategories.entries) '$cloudCategoryPrefix${e.key}': e.value,
      };

  /// Splits a flat cloud `answers` map back into choices and categories.
  factory AnswerKey.fromCloudAnswers(String examCode, Map<String, String> answers) {
    final choices = <String, String>{};
    final categories = <String, String>{};
    for (final e in answers.entries) {
      if (e.key.startsWith(cloudCategoryPrefix)) {
        categories[e.key.substring(cloudCategoryPrefix.length)] = e.value;
      } else {
        choices[e.key] = e.value;
      }
    }
    return AnswerKey(examCode: examCode, correctChoices: choices, itemCategories: categories);
  }

  Map<String, dynamic> toJson() => {
        'examCode': examCode,
        'correctChoices': correctChoices,
        if (itemCategories.isNotEmpty) 'itemCategories': itemCategories,
      };

  /// Also repairs a key an older build saved with the flat cloud shape: any
  /// `category|Section|Item` entry found among the answers is moved into
  /// [itemCategories] (an explicit `itemCategories` entry wins). Without this
  /// such a key reads as 144 "answers" for a 72-item sheet and its categories
  /// are never seen.
  factory AnswerKey.fromJson(Map<String, dynamic> json) {
    final stored = Map<String, String>.from(json['correctChoices'] as Map);
    final categories = json['itemCategories'] is Map
        ? Map<String, String>.from(json['itemCategories'] as Map)
        : <String, String>{};
    final choices = <String, String>{};
    for (final e in stored.entries) {
      if (e.key.startsWith(cloudCategoryPrefix)) {
        categories.putIfAbsent(e.key.substring(cloudCategoryPrefix.length), () => e.value);
      } else {
        choices[e.key] = e.value;
      }
    }
    return AnswerKey(
      examCode: json['examCode'] as String,
      correctChoices: choices,
      itemCategories: categories,
    );
  }
}
