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

/// A retake hint for an `OmrMeshVerdict` name, or null when the geometry of
/// that capture can be trusted.
///
/// Only two verdicts are surfaced, and both say so in their own
/// documentation: `likelyMisregistered` ("check corner detection") and
/// `tooSevere` ("retake with a flatter sheet"). This is deliberately
/// advisory rather than a hard block -- `planar` and `inconclusive` decode
/// correctly the great majority of the time, and refusing those would
/// reject captures that work today. These two are different in kind: no
/// mesh was applied, and the decode ran on a frame already known to be
/// wrong, so every answer on the sheet may be misread.
String? geometryWarningFor(String? meshVerdict) => switch (meshVerdict) {
      'likelyMisregistered' =>
        'Corner detection looks wrong — one of the four corner squares was '
            'probably mismatched, so every answer on this sheet may be '
            'misread. Rescan with all four corners clearly inside the guides.',
      'tooSevere' =>
        'The sheet is too bent or slanted to correct reliably. Flatten it '
            'and rescan.',
      _ => null,
    };

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

  /// The `OmrMeshVerdict` name this decode produced, or null for a result
  /// decoded before this field existed.
  ///
  /// Carried as a plain string so this model stays free of the decoder's
  /// enum and keeps round-tripping through JSON unchanged. Two of those
  /// verdicts say in their own documentation that callers must surface them
  /// -- `tooSevere` ("retake with a flatter sheet") and `likelyMisregistered`
  /// ("check corner detection") -- and until this field existed there was no
  /// way for a caller to honour that: the decoder computed the verdict,
  /// used it to decide whether to store [meshInteriorMeasuredFrac], and
  /// dropped it. A catastrophically misregistered sheet was indistinguishable
  /// from a clean one by the time a result reached the UI.
  final String? meshVerdict;

  const OmrScanResult({
    required this.examCode,
    required this.items,
    this.templateVersion,
    this.meshInteriorMeasuredFrac,
    this.meshVerdict,
  });

  /// A retake hint when the geometry of this capture cannot be trusted, or
  /// null when it can. See [geometryWarningFor].
  String? get geometryWarning => geometryWarningFor(meshVerdict);

  Map<String, dynamic> toJson() => {
        'examCode': examCode,
        'items': items.map((i) => i.toJson()).toList(),
        if (templateVersion != null) 'templateVersion': templateVersion,
        if (meshInteriorMeasuredFrac != null)
          'meshInteriorMeasuredFrac': meshInteriorMeasuredFrac!.map(
            (role, pt) => MapEntry(role, [pt.$1, pt.$2]),
          ),
        if (meshVerdict != null) 'meshVerdict': meshVerdict,
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
        meshVerdict: json['meshVerdict'] as String?,
      );
}
