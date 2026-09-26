/// Best-effort, on-device handwriting OCR for the Last Name / First Name
/// crops produced by `OmrDecoder.cropNameFields` — used only to pre-fill
/// the "Tag Student" dialog with a suggestion; staff always confirm or
/// correct it (see showExamineeDialog's `ocrSuggestion` param). Never
/// treated as authoritative, and never mirrored to the cloud sync layer —
/// see the doc comment on `AppState.persistCapturedSessionToBatch`.
///
/// Conditional export: native platforms get [name_ocr_service_native.dart]'s
/// google_mlkit_text_recognition-backed implementation; Web gets
/// [name_ocr_service_web.dart]'s stub instead, since that plugin is
/// Android/iOS-only — mirrors the exact split `omr_decoder.dart` already
/// uses for opencv_dart, for the same reason (keep `flutter build web`
/// compiling).
library;

export 'name_ocr_service_web.dart' if (dart.library.io) 'name_ocr_service_native.dart';
