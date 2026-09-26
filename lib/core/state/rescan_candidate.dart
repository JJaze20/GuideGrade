import '../../models/omr_scan_result.dart';

/// A replacement photo for an existing sheet that has passed the alignment
/// and decoding checks but has NOT been saved: it exists only as temporary
/// files and in memory until a reviewer confirms it.
///
/// Every path here is a temporary file created for this candidate (the
/// camera's cache copy, the review image and the name crops, each under a
/// candidate-specific name). Saved records never reference them — the
/// repository copies whatever it keeps into the batch's own storage — so they
/// can always be deleted when the candidate is abandoned.
class RescanCandidate {
  final String photoPath;

  /// Already decoded when the photo was captured; the comparison and the save
  /// both reuse it, so nothing is decoded again.
  final OmrScanResult decoded;

  /// Perspective-corrected copy for display, if decoding wrote one.
  final String? reviewImagePath;

  final String? nameCropLastPath;
  final String? nameCropFirstPath;
  final String? nameCropMiddlePath;

  /// What on-device OCR made of the new photo's name crops. UNVERIFIED and
  /// advisory: shown next to the saved identity, never saved by a rescan and
  /// never used to accept or reject it.
  final String? ocrLastName;
  final String? ocrFirstName;
  final String? ocrMiddleName;

  const RescanCandidate({
    required this.photoPath,
    required this.decoded,
    this.reviewImagePath,
    this.nameCropLastPath,
    this.nameCropFirstPath,
    this.nameCropMiddlePath,
    this.ocrLastName,
    this.ocrFirstName,
    this.ocrMiddleName,
  });

  /// The crops a person needs to compare handwriting: last and first name.
  bool get hasIdentifyingCrops => nameCropLastPath != null && nameCropFirstPath != null;

  bool get hasOcrSuggestion =>
      (ocrLastName ?? '').isNotEmpty ||
      (ocrFirstName ?? '').isNotEmpty ||
      (ocrMiddleName ?? '').isNotEmpty;

  /// Every temporary file this candidate owns.
  Iterable<String> get temporaryPaths => [
        photoPath,
        if (reviewImagePath != null) reviewImagePath!,
        if (nameCropLastPath != null) nameCropLastPath!,
        if (nameCropFirstPath != null) nameCropFirstPath!,
        if (nameCropMiddlePath != null) nameCropMiddlePath!,
      ];
}
