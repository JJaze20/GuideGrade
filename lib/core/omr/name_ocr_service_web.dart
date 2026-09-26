/// Web build-in stand-in for the native `NameOcrService` (see
/// name_ocr_service_native.dart). google_mlkit_text_recognition is
/// Android/iOS-only; this file exists purely so `flutter build web`
/// resolves a type-compatible class in its place — mirrors
/// omr_decoder_web.dart's exact reasoning.
///
/// Scanning (and therefore name-field OCR) has no route in the Web/admin
/// build (see omr_decoder_web.dart), so this is never actually reached at
/// runtime. Unlike OmrDecoder's stub, this returns null instead of
/// throwing: a caller treats "no OCR suggestion" as a normal, expected
/// outcome (recognition can always fail on-device too), so there's no
/// separate "unsupported platform" case worth distinguishing here.
class NameOcrService {
  const NameOcrService();

  Future<String?> recognizeName(String imagePath, {required String fieldLabel}) async => null;
}
