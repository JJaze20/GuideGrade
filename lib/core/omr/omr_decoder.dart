/// Platform-selecting barrel for [OmrDecoder].
///
/// Android/iOS/desktop (anywhere `dart:io` exists) get
/// omr_decoder_native.dart — the real opencv_dart-backed implementation.
/// Web gets omr_decoder_web.dart instead, since opencv_dart's dartcv4
/// bindings are dart:ffi-based and dart:ffi has no Web target; every method
/// there throws immediately rather than pulling that native dependency
/// chain into the Web build.
///
/// [AlignmentCheck] is exported from its own file so callers get the same
/// type regardless of which implementation was selected, without either
/// implementation depending on the other.
///
/// Do not add scanning logic directly to this file — it must stay a pure
/// re-export so `dart:io`/`package:opencv_dart` never become reachable from
/// the Web compilation graph.
export 'omr_alignment_check.dart';
export 'omr_decoder_web.dart' if (dart.library.io) 'omr_decoder_native.dart';
