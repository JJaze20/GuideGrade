import 'dart:typed_data';

import '../../models/omr_scan_result.dart';
import 'omr_alignment_check.dart';
import 'omr_templates.dart';

/// Web build-in stand-in for the native `OmrDecoder` (see
/// omr_decoder_native.dart). OMR scanning is a Guidance-Council, mobile-only
/// workflow (Android/iOS) — the System Administrator's Web build has no
/// route that reaches any screen calling this class (exam scanning isn't
/// part of the Web/admin route set). This file exists only so the Web
/// target has something type-compatible to compile in place of the native
/// implementation, which cannot compile for Web at all: opencv_dart's
/// dartcv4 bindings are dart:ffi-based, and dart:ffi has no Web target.
///
/// Deliberately contains no opencv_dart/dart:ffi/dart:io import, so none of
/// that dependency chain is ever reachable from the Web compilation graph
/// (see omr_decoder.dart's conditional export, which selects this file only
/// when dart:io is unavailable — i.e. on Web).
///
/// Every method throws [UnsupportedError] immediately rather than returning
/// a fake/empty OMR result — if this is ever actually reached at runtime,
/// that indicates a routing bug elsewhere in the app, and should fail
/// loudly rather than silently producing meaningless scan data.
class OmrDecoder {
  const OmrDecoder();

  Never _unsupported() => throw UnsupportedError(
        'OMR scanning is not supported on Web. Use the GuideGrade Android/iOS app to scan answer sheets.',
      );

  AlignmentCheck locateCorners(String imagePath, OmrExamTemplate template) => _unsupported();

  List<bool> checkCornersFromLuma(
    Uint8List lumaBytes,
    int width,
    int height,
    int bytesPerRow,
  ) =>
      _unsupported();

  OmrScanResult decode(String imagePath, OmrExamTemplate template) => _unsupported();

  void saveDebugVisualization(String imagePath, OmrExamTemplate template, String outputDir, int pageIndex) =>
      _unsupported();

  String? rectifyForOverlay(String imagePath, OmrExamTemplate template, String outputPath) => _unsupported();

  ({String lastName, String firstName, String middleInitial})? cropNameFields(
    String imagePath,
    OmrExamTemplate template, {
    required String lastNameOutPath,
    required String firstNameOutPath,
    required String middleInitialOutPath,
  }) =>
      _unsupported();
}
