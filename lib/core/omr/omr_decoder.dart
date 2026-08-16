// `OmrDecoder` conditional-import barrel.
//
// The native implementation (omr_decoder_native.dart) is backed by
// opencv_dart, which requires dart:ffi and a compiled native OpenCV
// library — neither exists on Web, so that file cannot be compiled for a
// Web target at all. The Web build instead gets omr_decoder_web.dart, a
// stub with the identical public API that throws immediately if ever
// actually called (it never should be — OMR scanning is a mobile-only,
// Guidance-Council route not reachable from the Web/admin build).
//
// `dart.library.io` is true on every platform this app ships natively to
// (Android, iOS, desktop) and false on Web, so it's the correct switch:
// callers of this file (`AppState`, `ExamScanningScreen`) import only this
// barrel and are unaffected by which side gets selected — both expose the
// exact same `OmrDecoder`/`AlignmentCheck` API.
export 'omr_alignment_check.dart';
export 'omr_decoder_web.dart' if (dart.library.io) 'omr_decoder_native.dart';
