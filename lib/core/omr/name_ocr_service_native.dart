import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'name_ocr_cleanup.dart';

/// ML Kit OCR for cropped name fields; printed captions are filtered out.
class NameOcrService {
  const NameOcrService();

  /// Returns a formatted suggestion, or null for a blank/unreadable field.
  Future<String?> recognizeName(
    String imagePath, {
    required String fieldLabel,
  }) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(
        InputImage.fromFilePath(imagePath),
      );
      return cleanNameOcrText(result.text, fieldLabel);
    } catch (e) {
      debugPrint('NameOcrService[$fieldLabel] failed: $e');
      return null;
    } finally {
      await recognizer.close();
    }
  }
}
