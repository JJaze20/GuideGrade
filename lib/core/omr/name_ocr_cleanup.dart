// Match complete phrases rather than individual header words: Dame, Marbel,
// South, etc. can be part of a person's name.
const _sheetPhrases = [
  'Guidance Honors and Scholarship Center',
  'Guidance and Testing Center',
  'Notre Dame of Marbel University',
  'City of Koronadal South Cotabato',
  'City of Koronadal',
  'South Cotabato',
  'Koronadal',
  'Address of School Last Attended',
  'School Last Attended',
  'Qualifying Test in Mathematics',
  'Admission Test',
  'Answer Document',
  'Answer Sheet',
  'Date of Birth',
  'Exam Code',
];

String _letters(String value) =>
    value.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

/// Removes known printed sheet text before formatting a name suggestion.
/// This is a conservative text filter, not handwriting detection.
String? cleanNameOcrText(String raw, String fieldLabel) {
  final label = _letters(fieldLabel);
  if (label.isEmpty) return null;

  bool isLabel(String value) {
    final candidate = _letters(value);
    // Short captions such as MI must not swallow real initials.
    return label.length < 6
        ? candidate == label
        : _editDistance(candidate, label) <= 2;
  }

  final nameLines = <String>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    // Ambiguous single-word captions are removed only as complete lines.
    if (const {
      'batch',
      'date',
      'gender',
      'grade',
      'school',
      'examiner',
      'ageyearsmonths',
    }.contains(_letters(line))) {
      continue;
    }
    final words = line.trim().split(RegExp(r'\s+'));
    if (words.length == 1 && words.first.isEmpty) continue;
    // Try whole tokens only: never remove part of a handwritten name.
    // One to three tokens covers "LastName", "Last Name", and "M. I.".
    for (var count = 1; count <= words.length && count <= 3; count++) {
      if (isLabel(words.take(count).join(' '))) {
        words.removeRange(0, count);
        break;
      }
    }
    nameLines.add(words.join(' '));
  }
  final tokens = nameLines.join(' ').split(RegExp(r'\s+'));
  final phrases = [
    ..._sheetPhrases,
    'Last Name',
    'First Name',
    'Middle Initial',
  ].map(_letters).toSet();
  final kept = <String>[];
  for (var i = 0; i < tokens.length;) {
    var matched = 0;
    // Longest match first; also handles captions joined or split by OCR,
    // and headers wrapped across lines. Never match inside a name token.
    for (var count = 1; count <= 9 && i + count <= tokens.length; count++) {
      final candidate = _letters(tokens.sublist(i, i + count).join());
      if (phrases.contains(candidate) ||
          (count <= 3 && isLabel(tokens.sublist(i, i + count).join()))) {
        matched = count;
      }
    }
    if (matched > 0) {
      i += matched;
    } else {
      kept.add(tokens[i++]);
    }
  }
  final name = kept.join(' ').replaceAll(RegExp(r"[^A-Za-z' -]"), '').trim();
  if (name.isEmpty) return null;
  return name
      .split(RegExp(r'\s+'))
      .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
      .join(' ');
}

int _editDistance(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      current[j] = [
        current[j - 1] + 1,
        previous[j] + 1,
        substitution,
      ].reduce((a, b) => a < b ? a : b);
    }
    previous = current;
  }
  return previous.last;
}
