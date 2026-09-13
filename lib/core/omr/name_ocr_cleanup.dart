/// Removes a field's printed caption before formatting the name suggestion.
String? cleanNameOcrText(String raw, String fieldLabel) {
  String letters(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z]'), '');
  final label = letters(fieldLabel);
  if (label.isEmpty) return null;

  bool isLabel(String value) {
    final candidate = letters(value);
    // Short captions such as MI must not swallow real initials.
    return label.length < 6
        ? candidate == label
        : _editDistance(candidate, label) <= 2;
  }

  final nameLines = <String>[];
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
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
  final name = nameLines
      .join(' ')
      .replaceAll(RegExp(r"[^A-Za-z' -]"), '')
      .trim();
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
