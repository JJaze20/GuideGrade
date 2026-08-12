/// The decoded mark for a single numbered item on a scanned sheet.
class OmrItemResult {
  final String sectionName;
  final int itemNumber;

  /// The choice label (e.g. "A", "T", "c") the decoder judged as filled in,
  /// or null if no bubble was confidently marked.
  final String? markedChoice;

  /// True when two or more bubbles for this item were too close in darkness
  /// to pick a single winner (a double/stray mark), rather than genuinely
  /// blank.
  final bool isAmbiguous;

  const OmrItemResult({
    required this.sectionName,
    required this.itemNumber,
    required this.markedChoice,
    this.isAmbiguous = false,
  });

  bool get isBlank => markedChoice == null && !isAmbiguous;
}

/// The full decoded result of one scanned answer sheet.
class OmrScanResult {
  final String examCode;
  final List<OmrItemResult> items;

  const OmrScanResult({required this.examCode, required this.items});
}
