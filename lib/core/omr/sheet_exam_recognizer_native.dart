import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'sheet_exam_identity.dart';

/// Best-effort printed-title recognition, independent of answer decoding.
Future<String?> recognizeSheetExam(String imagePath) async {
  TextRecognizer? recognizer;
  try {
    recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final result = await recognizer.processImage(InputImage.fromFilePath(imagePath));
    return identifySheetExam(result.text);
  } catch (_) {
    return null;
  } finally {
    try {
      await recognizer?.close();
    } catch (_) {
      // Cleanup failure must not replace the recognition result.
    }
  }
}
