/// Decodes a photographed answer sheet into marked choices, using the
/// fiducial corner markers in [OmrExamTemplate.cornerMarkers] to correct for
/// skew/perspective before sampling each [BubblePos].
///
/// Conditional export: native platforms (Android/iOS/desktop, anywhere
/// dart:io is available) get [omr_decoder_native.dart]'s opencv_dart-backed
/// implementation; Web gets [omr_decoder_web.dart]'s stub instead, since
/// opencv_dart's dartcv4 bindings are dart:ffi-based and dart:ffi has no Web
/// target. Both expose the exact same `OmrDecoder` API (see each file's own
/// doc comment), so callers just `import 'omr_decoder.dart'` and never need
/// to know which platform they're compiled for.
///
/// [AlignmentCheck] is plain data with no platform-specific dependency, so
/// it lives in its own file ([omr_alignment_check.dart]) and is re-exported
/// here rather than duplicated per platform.
library;

export 'omr_alignment_check.dart';
export 'omr_decoder_web.dart' if (dart.library.io) 'omr_decoder_native.dart';
