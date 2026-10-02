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

  /// Which [OmrExamTemplate.templateVersion] produced [items]' coordinates
  /// — null for a result decoded before this field existed. Lets a later
  /// screen (e.g. ScannedImageViewerScreen's overlay) detect that the live
  /// template's geometry has since changed and avoid silently redrawing
  /// this scan with coordinates it was never actually decoded against.
  final String? templateVersion;

  /// Interior-fiducial mesh-correction readings used to decode [items],
  /// keyed by [OmrFiducialRole] name (`dividerLeft`, `dividerRight`,
  /// `centerAboveAnswers`, `centerAtDivider`, `centerBelowAnswers`) —
  /// fractional (0-1) page positions, resolution-independent. Null/empty
  /// for a template with no interior fiducials (legacy sheets, TAT) or a
  /// result decoded before this field existed. Persisted so
  /// ScannedImageViewerScreen's graded overlay can reconstruct the exact
  /// same [OmrMeshCorrection] used for scoring instead of assuming the
  /// displayed rectified image is an undistorted 1:1 map of template
  /// fractions — see that screen's `centerOf`.
  final Map<String, (double, double)>? meshInteriorMeasuredFrac;

  const OmrScanResult({
    required this.examCode,
    required this.items,
    this.templateVersion,
    this.meshInteriorMeasuredFrac,
  });

  Map<String, dynamic> toJson() => {
        'examCode': examCode,
        'items': items.map((i) => i.toJson()).toList(),
        if (templateVersion != null) 'templateVersion': templateVersion,
        if (meshInteriorMeasuredFrac != null)
          'meshInteriorMeasuredFrac': meshInteriorMeasuredFrac!.map(
            (role, pt) => MapEntry(role, [pt.$1, pt.$2]),
          ),
      };

  factory OmrScanResult.fromJson(Map<String, dynamic> json) => OmrScanResult(
        examCode: json['examCode'] as String,
        items: (json['items'] as List<dynamic>? ?? [])
            .map((e) => OmrItemResult.fromJson(e as Map<String, dynamic>))
            .toList(),
        templateVersion: json['templateVersion'] as String?,
        meshInteriorMeasuredFrac:
            (json['meshInteriorMeasuredFrac'] as Map<String, dynamic>?)?.map(
          (role, pt) {
            final list = pt as List<dynamic>;
            return MapEntry(role, ((list[0] as num).toDouble(), (list[1] as num).toDouble()));
          },
        ),
      );
}
