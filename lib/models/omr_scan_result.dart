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

  Map<String, dynamic> toJson() => {
        'sectionName': sectionName,
        'itemNumber': itemNumber,
        'markedChoice': markedChoice,
        'isAmbiguous': isAmbiguous,
      };

  factory OmrItemResult.fromJson(Map<String, dynamic> json) => OmrItemResult(
        sectionName: json['sectionName'] as String,
        itemNumber: json['itemNumber'] as int,
        markedChoice: json['markedChoice'] as String?,
        isAmbiguous: json['isAmbiguous'] as bool? ?? false,
      );
}

/// The full decoded result of one scanned answer sheet.
class OmrScanResult {
  final String examCode;
  final List<OmrItemResult> items;

  const OmrScanResult({required this.examCode, required this.items});

  Map<String, dynamic> toJson() => {
        'examCode': examCode,
        'items': items.map((i) => i.toJson()).toList(),
      };

  factory OmrScanResult.fromJson(Map<String, dynamic> json) => OmrScanResult(
        examCode: json['examCode'] as String,
        items: (json['items'] as List<dynamic>? ?? [])
            .map((e) => OmrItemResult.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
