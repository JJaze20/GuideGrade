/// Only complete printed titles count; acronyms and conflicting titles do not.
String? identifySheetExam(String text) {
  final normalized = text.toUpperCase().replaceAll(RegExp(r'[^A-Z]+'), ' ').trim();
  const titles = {
    'AT': 'ADMISSION TEST',
    'QTM': 'QUALIFYING TEST IN MATHEMATICS',
    'TAT': 'TEACHING APTITUDE TEST',
  };
  final matches = titles.entries.where(
    (entry) => ' $normalized '.contains(' ${entry.value} '),
  );
  return matches.length == 1 ? matches.single.key : null;
}
