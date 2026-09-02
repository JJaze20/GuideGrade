import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// google_mlkit_text_recognition-backed implementation — see
/// name_ocr_service.dart's doc comment for why this is conditionally
/// exported instead of imported directly.
class NameOcrService {
  const NameOcrService();

  /// Best-effort handwriting OCR on a small, tightly-cropped name-field
  /// image (see `OmrDecoder.cropNameFields`). [fieldLabel] is the exact
  /// printed caption drawn inside that same crop (e.g. "Last Name") — the
  /// generated sheets print the label inside the same box the student
  /// writes in (see generate_sheets.dart's `_paintSimpleHeader`/
  /// `_paintNdmuHeader`), so a real scan's crop almost always contains both
  /// the printed label ink and the handwriting; confirmed on a real device
  /// scan, where a blank field's crop OCR'd as a slightly-misread copy of
  /// the label itself ("First Name" -> "First Narme") rather than nothing,
  /// and a filled field OCR'd as the label followed by the actual answer
  /// ("Last Name" + "Doe" -> "Last Name Doe"). [fieldLabel] lets
  /// [_cleanUp] recognize and remove that printed label instead of
  /// surfacing it as a false guess.
  ///
  /// Returns a cleaned-up guess (letters/spaces/hyphens/apostrophes only,
  /// Title Case, matching how staff type names in showExamineeDialog), or
  /// null if nothing usable was recognized beyond the label, or the
  /// recognizer itself failed. A fresh [TextRecognizer] is created and
  /// closed per call — this only runs a couple of times per scanned sheet
  /// during "Compile Data", not per frame, so the extra startup cost isn't
  /// worth a persistent instance to manage the lifecycle of.
  Future<String?> recognizeName(String imagePath, {required String fieldLabel}) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final inputImage = InputImage.fromFilePath(imagePath);
      final result = await recognizer.processImage(inputImage);
      // Temporary diagnostic: logs the exact raw text ML Kit returned for
      // this crop, before any cleanup — filter logcat for "NameOcrService"
      // to see what the recognizer actually saw vs. what got surfaced.
      // TODO: remove once handwriting-recognition accuracy is validated.
      debugPrint('NameOcrService[$fieldLabel] raw="${result.text.replaceAll('\n', '\\n')}"');
      return _cleanUp(result.text, fieldLabel);
    } catch (e) {
      debugPrint('NameOcrService[$fieldLabel] failed: $e');
      return null;
    } finally {
      await recognizer.close();
    }
  }

  static String? _cleanUp(String raw, String fieldLabel) {
    // Collapse all whitespace (recognized multi-line output included) to
    // single spaces, keep only letters/spaces/hyphens/apostrophes (rules
    // out stray printed-form ink like table borders), then compare against
    // the known printed label before Title Casing.
    final flattened = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final lettersOnly = flattened.replaceAll(RegExp(r"[^A-Za-z' -]"), '').trim();
    if (lettersOnly.isEmpty) return null;

    // Nothing was actually written — OCR just read the printed label,
    // possibly with a small misread (e.g. "First Name" -> "First Narme").
    // A tight edit-distance bound (rather than an exact match) is what
    // catches that misread; a real short name isn't within 2 edits of a
    // 9-10 letter label like "Last Name"/"First Name". That bound only
    // makes sense for labels long enough that 2 edits is a small relative
    // change, though — "MI" is 2 characters, so *any* single real initial
    // ("E") is already within edit-distance 2 of "MI" and would otherwise
    // always be swallowed as "just the label". Short labels get an exact
    // (case-insensitive) match instead.
    final isJustLabel = fieldLabel.length >= 6
        ? _levenshtein(lettersOnly.toLowerCase(), fieldLabel.toLowerCase()) <= 2
        : lettersOnly.toLowerCase() == fieldLabel.toLowerCase();
    if (isJustLabel) return null;

    // Something was written after/below the label and both got swept into
    // the same crop (e.g. "Last Name Doe") — drop the label prefix so only
    // the actual answer remains. Only an exact (case-insensitive) prefix
    // match is stripped; a misread label has already been handled above.
    var name = lettersOnly;
    final lower = name.toLowerCase();
    final labelLower = fieldLabel.toLowerCase();
    if (lower.startsWith(labelLower)) {
      name = name.substring(fieldLabel.length).trim();
    }
    if (name.isEmpty) return null;

    final titleCased = name
        .split(' ')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
    return titleCased.isEmpty ? null : titleCased;
  }

  /// Classic edit-distance DP. Both inputs here are always short (a name or
  /// a ~10-character field label), so the O(n*m) cost is negligible.
  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    var previous = List<int>.generate(b.length + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0);
      current[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        current[j] = [
          current[j - 1] + 1,
          previous[j] + 1,
          previous[j - 1] + cost,
        ].reduce((v, e) => v < e ? v : e);
      }
      previous = current;
    }
    return previous[b.length];
  }
}
