import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/omr_scan_result.dart';
import 'omr_alignment_check.dart';
import 'omr_templates.dart';

/// Decodes a photographed answer sheet into marked choices, using the
/// fiducial corner markers in [OmrExamTemplate.cornerMarkers] to correct for
/// skew/perspective before sampling each [BubblePos].
///
/// Native (Android/iOS/desktop) implementation — backed by opencv_dart,
/// which requires dart:ffi and a compiled native OpenCV library, neither of
/// which exist on Web. This file is only ever selected for compilation on
/// platforms where dart:io is available (see omr_decoder.dart's conditional
/// export); Web gets omr_decoder_web.dart instead. Logic here is unchanged
/// from before that split — this is the same implementation, just moved
/// into its own file with [AlignmentCheck] factored out to a shared file so
/// both platform variants can return the same type.
class OmrDecoder {
  const OmrDecoder();

  /// How far (as a fraction of the shorter image dimension) to search around
  /// each corner marker's expected position for the actual fiducial mark.
  static const double _cornerSearchWindowFrac = 0.08;

  /// Canonical pixels per PDF point when warping the sheet flat. Bubble
  /// sampling geometry below is tuned against this scale.
  static const double _canonicalPxPerPt = 2.0;

  /// Block size (must be odd) for the adaptive threshold that binarizes the
  /// warped sheet before bubble sampling. Large enough to span several
  /// bubbles so it tracks slow lighting gradients across the page rather
  /// than reacting to a single bubble, small enough to still adapt to
  /// vignetting/uneven light within the sheet.
  static const int _adaptiveThresholdBlockSize = 45;

  /// Constant subtracted from the local adaptive-threshold mean; higher
  /// values require darker pixels to count as "ink".
  static const double _adaptiveThresholdC = 12;

  /// A bubble's ink fill fraction (0 = empty, 1 = fully black) must clear
  /// this floor to be considered marked at all.
  static const double _blankFillFloor = 0.15;

  /// The most-filled bubble in an item must beat the runner-up fill
  /// fraction by at least this much to be treated as an unambiguous single
  /// mark.
  static const double _ambiguousMargin = 0.15;

  /// Cheap alignment check for right after a photo is captured: does the
  /// same image load + corner search as [decode], but skips the perspective
  /// warp and bubble sampling, so it's reasonable to run on every capture
  /// rather than only at full-decode time.
  AlignmentCheck locateCorners(String imagePath, OmrExamTemplate template) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) {
        return const AlignmentCheck.misaligned('Could not read the captured photo.');
      }
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        return _checkAlignment(gray, template);
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Same alignment check as [locateCorners], but against a live camera
  /// preview frame instead of a captured file — cheap enough to run
  /// periodically while framing, for the on-screen guide's live
  /// green/red feedback. [lumaBytes] is the Y (luma) plane of a YUV
  /// camera frame, already 8-bit grayscale with no color conversion
  /// needed. [bytesPerRow] may exceed [width] (row padding, common on
  /// Android camera buffers) — the extra columns are cropped off.
  AlignmentCheck checkAlignmentFromLuma(
    Uint8List lumaBytes,
    int width,
    int height,
    int bytesPerRow,
    OmrExamTemplate template,
  ) {
    final full = cv.Mat.fromList(height, bytesPerRow, cv.MatType.CV_8UC1, lumaBytes);
    try {
      final gray = bytesPerRow == width ? full : full.region(cv.Rect(0, 0, width, height));
      try {
        return _checkAlignment(gray, template);
      } finally {
        if (!identical(gray, full)) gray.dispose();
      }
    } finally {
      full.dispose();
    }
  }

  /// Shared by [locateCorners] and [checkAlignmentFromLuma] so a captured
  /// photo and a live preview frame are judged by identical logic.
  AlignmentCheck _checkAlignment(cv.Mat gray, OmrExamTemplate template) {
    try {
      _refineCorners(gray, template);
      return const AlignmentCheck.aligned();
    } on StateError catch (e) {
      return AlignmentCheck.misaligned(e.message);
    }
  }

  /// Reads [imagePath] against [template] and returns the decoded marks.
  /// Throws a [StateError] with a user-facing message if the sheet couldn't
  /// be read or aligned.
  OmrScanResult decode(String imagePath, OmrExamTemplate template) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) {
        throw StateError('Could not read the captured photo at $imagePath.');
      }
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        final corners = _refineCorners(gray, template);
        final canonicalWidth = (template.pageWidthPt * _canonicalPxPerPt).round();
        final canonicalHeight = (template.pageHeightPt * _canonicalPxPerPt).round();

        final dstCorners = cv.VecPoint2f.fromList([
          cv.Point2f(0, 0),
          cv.Point2f(canonicalWidth.toDouble(), 0),
          cv.Point2f(0, canonicalHeight.toDouble()),
          cv.Point2f(canonicalWidth.toDouble(), canonicalHeight.toDouble()),
        ]);
        final srcCorners = cv.VecPoint2f.fromList(corners);
        final transform = cv.getPerspectiveTransform2f(srcCorners, dstCorners);
        try {
          final warped = cv.warpPerspective(gray, transform, (canonicalWidth, canonicalHeight));
          try {
            final blurred = cv.gaussianBlur(warped, (3, 3), 0);
            try {
              final inkMap = cv.adaptiveThreshold(
                blurred,
                255,
                cv.ADAPTIVE_THRESH_GAUSSIAN_C,
                cv.THRESH_BINARY_INV,
                _adaptiveThresholdBlockSize,
                _adaptiveThresholdC,
              );
              try {
                return _readBubbles(inkMap, template, canonicalWidth, canonicalHeight);
              } finally {
                inkMap.dispose();
              }
            } finally {
              blurred.dispose();
            }
          } finally {
            warped.dispose();
          }
        } finally {
          transform.dispose();
          srcCorners.dispose();
          dstCorners.dispose();
        }
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// Debug-only: writes two annotated JPEGs to [outputDir] — the detected
  /// corner markers drawn on the original photo, and the full expected
  /// bubble grid drawn on the warped/aligned image — so a misread sheet can
  /// be diagnosed by looking at where the decoder actually thinks things
  /// are, instead of guessing from decoded results alone. [outputDir] must
  /// already exist and be writable.
  void saveDebugVisualization(String imagePath, OmrExamTemplate template, String outputDir, int pageIndex) {
    final src = cv.imread(imagePath);
    try {
      if (src.isEmpty) return;
      final gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      try {
        List<cv.Point2f> corners;
        try {
          corners = _refineCorners(gray, template);
        } on StateError catch (e) {
          // Corner detection itself failed — still write the raw photo so
          // framing/lighting/orientation can be inspected, plus the exact
          // error, instead of silently producing no debug output for
          // precisely the failing case that needs to be seen.
          cv.imwrite('$outputDir/sheet${pageIndex}_FAILED.jpg', src);
          File('$outputDir/sheet${pageIndex}_error.txt').writeAsStringSync(e.message);
          return;
        }

        final cornersDebug = src.clone();
        try {
          for (final c in corners) {
            cv.circle(cornersDebug, cv.Point(c.x.round(), c.y.round()), 16, cv.Scalar(0, 0, 255), thickness: 5);
          }
          cv.imwrite('$outputDir/sheet${pageIndex}_corners.jpg', cornersDebug);
        } finally {
          cornersDebug.dispose();
        }

        final canonicalWidth = (template.pageWidthPt * _canonicalPxPerPt).round();
        final canonicalHeight = (template.pageHeightPt * _canonicalPxPerPt).round();
        final dstCorners = cv.VecPoint2f.fromList([
          cv.Point2f(0, 0),
          cv.Point2f(canonicalWidth.toDouble(), 0),
          cv.Point2f(0, canonicalHeight.toDouble()),
          cv.Point2f(canonicalWidth.toDouble(), canonicalHeight.toDouble()),
        ]);
        final srcCorners = cv.VecPoint2f.fromList(corners);
        final transform = cv.getPerspectiveTransform2f(srcCorners, dstCorners);
        try {
          final warped = cv.warpPerspective(src, transform, (canonicalWidth, canonicalHeight));
          try {
            for (final section in template.sections) {
              for (final entry in section.items.entries) {
                for (final bubble in entry.value) {
                  final x = (bubble.xFrac * canonicalWidth).round();
                  final y = (bubble.yFrac * canonicalHeight).round();
                  cv.circle(warped, cv.Point(x, y), 3, cv.Scalar(0, 0, 255), thickness: -1);
                }
              }
            }
            cv.imwrite('$outputDir/sheet${pageIndex}_grid.jpg', warped);
          } finally {
            warped.dispose();
          }
        } finally {
          transform.dispose();
          srcCorners.dispose();
          dstCorners.dispose();
        }
      } finally {
        gray.dispose();
      }
    } finally {
      src.dispose();
    }
  }

  /// The template's 4 [OmrCorner]s are ordered top-left, top-right,
  /// bottom-left, bottom-right. For each, seed an expected pixel position
  /// and search a local window around it for the actual fiducial mark (a
  /// small dark blob — solid square or thin tick, shape-agnostic), returning
  /// its refined centroid.
  ///
  /// The seed comes from [_detectPageQuad] when the photo shows background
  /// around the sheet (the common case — the viewfinder doesn't crop tight
  /// to the page), bilinearly interpolating within the detected page
  /// boundary. Assuming the fractional page position maps directly onto the
  /// full image (`xFrac * image.width`) is only correct when the page fills
  /// the frame edge-to-edge, which produced systematically wrong seeds -
  /// and therefore a skewed homography and misread bubbles - whenever any
  /// background was visible around the sheet.
  List<cv.Point2f> _refineCorners(cv.Mat gray, OmrExamTemplate template) {
    const labels = ['top-left', 'top-right', 'bottom-left', 'bottom-right'];
    final corners = template.cornerMarkers;
    final pageQuad = _detectPageQuad(gray);
    final found = List.generate(corners.length, (i) {
      final double expectedX;
      final double expectedY;
      if (pageQuad != null) {
        final seed = _bilinearInterpolate(pageQuad, corners[i].xFrac, corners[i].yFrac);
        expectedX = seed.$1;
        expectedY = seed.$2;
      } else {
        expectedX = corners[i].xFrac * gray.width;
        expectedY = corners[i].yFrac * gray.height;
      }
      final marker = _findMarkerNear(gray, expectedX, expectedY);
      if (marker == null) {
        throw StateError(
          'Could not find the ${labels[i]} alignment mark. Retake the photo with the full sheet, including all four corners, in frame.',
        );
      }
      return marker;
    });
    _validateQuad(found, template, gray);
    return found;
  }

  /// Finding *a* plausible small dark blob near each of the 4 expected
  /// corner spots isn't enough on its own — if the sheet is out of frame or
  /// badly misaligned, those 4 windows can each still latch onto unrelated
  /// clutter (shadows, texture, edges) that individually passes the
  /// size filter, so the corner search silently "succeeds" on nonsense.
  /// This checks the 4 found points actually form a plausible sheet-shaped
  /// rectangle together before accepting them.
  void _validateQuad(List<cv.Point2f> corners, OmrExamTemplate template, cv.Mat gray) {
    final tl = corners[0], tr = corners[1], bl = corners[2], br = corners[3];

    if (tl.x >= tr.x || bl.x >= br.x || tl.y >= bl.y || tr.y >= br.y) {
      throw StateError(
        'The detected corner marks are not arranged like the sheet. Retake the photo with the sheet upright and all four corners visible.',
      );
    }

    final width = ((tr.x - tl.x) + (br.x - bl.x)) / 2;
    final height = ((bl.y - tl.y) + (br.y - tr.y)) / 2;
    final expectedAspect = _expectedMarkerQuadAspectRatio(template);
    final actualAspect = width / height;
    // A real sheet's aspect ratio should match reasonably closely (paper
    // dimensions are exact), but this is a coarse secondary check — the
    // centrality filter in _detectPageQuad is the primary defense against
    // picking up background clutter (a second sheet, wall, furniture)
    // instead of the actual sheet. 0.15 (tightened from an original 0.35
    // that let a clutter-quad through) turned out to reject too many
    // genuine handheld photos too, whose measured aspect ratio shifts more
    // than that from normal perspective/keystone distortion at a
    // non-perfectly-perpendicular angle. 0.25 is a middle ground.
    if ((actualAspect - expectedAspect).abs() > expectedAspect * 0.25) {
      throw StateError(
        "The detected corners don't form a sheet-shaped rectangle. Retake the photo with just the one sheet, on a plain background, in frame.",
      );
    }

    final imageArea = gray.width * gray.height;
    final quadArea = width * height;
    if (quadArea < imageArea * 0.05) {
      throw StateError('The sheet appears too small in this photo. Move closer and retake.');
    }
  }

  /// The aspect ratio the 4 detected corner markers should actually form,
  /// derived from [template.cornerMarkers] rather than assumed to be the
  /// full page's own aspect ratio.
  ///
  /// Those are not the same thing whenever an exam's bubble grid doesn't
  /// use the full page width — QTM's grid (2 narrow columns) only spans
  /// its left half, so its real marker quad is roughly half as wide,
  /// relative to its height, as the full A4 page (~0.35 vs ~0.71). Using
  /// the page's own ratio here rejected every correctly-aligned QTM photo
  /// outright, regardless of how well the 4 markers were actually found.
  /// Computed the same way [_validateQuad] measures the *detected* quad's
  /// width/height (averaging the two opposite edges), just from the
  /// template's known-good corner fractions instead of pixel coordinates,
  /// so a template whose corners already span most of the page (e.g. AT)
  /// is unaffected and a narrower one (QTM, TAT) is validated correctly
  /// instead of by accident.
  double _expectedMarkerQuadAspectRatio(OmrExamTemplate template) {
    final corners = template.cornerMarkers;
    final tl = corners[0], tr = corners[1], bl = corners[2], br = corners[3];
    final widthFrac = ((tr.xFrac - tl.xFrac) + (br.xFrac - bl.xFrac)) / 2;
    final heightFrac = ((bl.yFrac - tl.yFrac) + (br.yFrac - tr.yFrac)) / 2;
    final widthPt = widthFrac * template.pageWidthPt;
    final heightPt = heightFrac * template.pageHeightPt;
    return widthPt / heightPt;
  }

  /// Finds the largest plausible quadrilateral near the center of the photo
  /// that bounds the sheet (page edge against whatever background surrounds
  /// it), returning its corners ordered [topLeft, topRight, bottomLeft,
  /// bottomRight], or null if no such quad is found (e.g. the page already
  /// fills the whole frame, so there's no visible boundary edge to detect -
  /// callers should fall back to treating the image itself as the page).
  ///
  /// A qualifying contour (large enough, roughly central) is turned into a
  /// quad either by polygon approximation, when that cleanly yields a
  /// convex 4-point shape, or by its own axis-aligned bounding box
  /// otherwise -- ordinary handheld photos often have a page-boundary
  /// contour that's clearly the sheet but doesn't polygon-approximate to a
  /// perfect quad (paper curl, shadow fringing, compression noise), and
  /// discarding those outright was what pushed corner seeding into
  /// assuming the page fills the frame edge-to-edge, which is wrong
  /// whenever any background is actually visible around the sheet.
  ///
  /// Requiring the candidate's centroid to be reasonably central rules out
  /// unrelated background objects - a second sheet lower in frame, a wall
  /// corner, furniture - that can otherwise out-area the actual sheet and
  /// get picked as "the page" just because they're bigger, even though the
  /// on-screen guide already tells the user to center the sheet they're
  /// scanning. Both quad-extraction paths go through this same check.
  List<(double, double)>? _detectPageQuad(cv.Mat gray) {
    final blurred = cv.gaussianBlur(gray, (5, 5), 0);
    try {
      final edges = cv.canny(blurred, 50, 150);
      try {
        final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
        try {
          final dilated = cv.dilate(edges, kernel, iterations: 2);
          try {
            final (contours, hierarchy) = cv.findContours(dilated, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
            try {
              final imageArea = (gray.width * gray.height).toDouble();
              final centerX = gray.width / 2;
              final centerY = gray.height / 2;
              final maxCenterDistance = 0.3 * math.sqrt(gray.width * gray.width + gray.height * gray.height) / 2;
              List<(double, double)>? bestQuad;
              double bestArea = 0;
              for (final contour in contours) {
                final area = cv.contourArea(contour);
                if (area < imageArea * 0.2 || area <= bestArea) continue;
                final peri = cv.arcLength(contour, true);
                final approx = cv.approxPolyDP(contour, 0.02 * peri, true);
                try {
                  List<(double, double)> points;
                  if (approx.length == 4 && cv.isContourConvex(approx)) {
                    points = [for (final p in approx) (p.x.toDouble(), p.y.toDouble())];
                  } else {
                    // The contour's outline didn't reduce cleanly to a
                    // 4-point convex polygon -- common in ordinary
                    // handheld photos (slight paper curl, shadow fringing
                    // along one edge, compression noise) even when the
                    // contour clearly is the sheet. Rather than discarding
                    // an already-large, still-to-be-centrality-checked
                    // contour outright -- which is what pushed
                    // _refineCorners into its full-frame fallback whenever
                    // any background was visible -- fall back to this
                    // contour's own axis-aligned bounding box as a
                    // still-plausible quad estimate. It goes through the
                    // exact same centrality gate below as a strict 4-point
                    // quad would, so this doesn't accept clutter the
                    // strict path wouldn't also have been willing to
                    // accept had its edges been a bit cleaner.
                    final rect = cv.boundingRect(contour);
                    points = [
                      (rect.x.toDouble(), rect.y.toDouble()),
                      ((rect.x + rect.width).toDouble(), rect.y.toDouble()),
                      (rect.x.toDouble(), (rect.y + rect.height).toDouble()),
                      ((rect.x + rect.width).toDouble(), (rect.y + rect.height).toDouble()),
                    ];
                  }
                  final centroidX = points.map((p) => p.$1).reduce((a, b) => a + b) / 4;
                  final centroidY = points.map((p) => p.$2).reduce((a, b) => a + b) / 4;
                  final centerDistance = math.sqrt(math.pow(centroidX - centerX, 2) + math.pow(centroidY - centerY, 2));
                  if (centerDistance > maxCenterDistance) continue;
                  bestArea = area;
                  bestQuad = points;
                } finally {
                  approx.dispose();
                }
              }
              return bestQuad == null ? null : _orderQuadCorners(bestQuad);
            } finally {
              contours.dispose();
              hierarchy.dispose();
            }
          } finally {
            dilated.dispose();
          }
        } finally {
          kernel.dispose();
        }
      } finally {
        edges.dispose();
      }
    } finally {
      blurred.dispose();
    }
  }

  /// Orders 4 arbitrary quad points as [topLeft, topRight, bottomLeft,
  /// bottomRight]: top-left has the smallest x+y, bottom-right the largest;
  /// top-right has the largest x-y, bottom-left the smallest.
  List<(double, double)> _orderQuadCorners(List<(double, double)> pts) {
    final bySum = [...pts]..sort((a, b) => (a.$1 + a.$2).compareTo(b.$1 + b.$2));
    final byDiff = [...pts]..sort((a, b) => (a.$1 - a.$2).compareTo(b.$1 - b.$2));
    return [bySum.first, byDiff.last, byDiff.first, bySum.last];
  }

  /// Bilinearly interpolates a fractional page position within the
  /// quadrilateral [quad] ([topLeft, topRight, bottomLeft, bottomRight]).
  (double, double) _bilinearInterpolate(List<(double, double)> quad, double xFrac, double yFrac) {
    final tl = quad[0], tr = quad[1], bl = quad[2], br = quad[3];
    final topX = tl.$1 + (tr.$1 - tl.$1) * xFrac;
    final topY = tl.$2 + (tr.$2 - tl.$2) * xFrac;
    final bottomX = bl.$1 + (br.$1 - bl.$1) * xFrac;
    final bottomY = bl.$2 + (br.$2 - bl.$2) * xFrac;
    return (topX + (bottomX - topX) * yFrac, topY + (bottomY - topY) * yFrac);
  }

  /// Searches the window around ([expectedX], [expectedY]) for the fiducial
  /// mark. Rather than taking the largest dark blob in the window (which
  /// reliably locked onto nearby header text/table lines instead of the
  /// actual mark whenever those happened to out-area it - a real bug, not
  /// just noise, since it picked the *same* wrong feature just as
  /// confidently at higher photo resolution), this rejects implausibly
  /// tiny (speckle) or large (a line/text run spanning much of the window)
  /// blobs, then takes whichever remaining blob's centroid is closest to
  /// the expected position.
  cv.Point2f? _findMarkerNear(cv.Mat gray, double expectedX, double expectedY) {
    final windowRadius = _cornerSearchWindowFrac * math.min(gray.width, gray.height);
    final left = (expectedX - windowRadius).clamp(0, gray.width - 1).round();
    final top = (expectedY - windowRadius).clamp(0, gray.height - 1).round();
    final right = (expectedX + windowRadius).clamp(left + 1, gray.width).round();
    final bottom = (expectedY + windowRadius).clamp(top + 1, gray.height).round();

    final roiRect = cv.Rect(left, top, right - left, bottom - top);
    final roi = gray.region(roiRect);
    try {
      final (_, binary) = cv.threshold(roi, 0, 255, cv.THRESH_BINARY_INV | cv.THRESH_OTSU);
      try {
        final (contours, hierarchy) = cv.findContours(binary, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
        try {
          final roiArea = (right - left) * (bottom - top);
          final windowCenterX = (right - left) / 2;
          final windowCenterY = (bottom - top) / 2;

          double bestDistance = double.infinity;
          cv.Rect? bestRect;
          for (final contour in contours) {
            final area = cv.contourArea(contour);
            if (area < 8 || area > roiArea * 0.35) continue;
            final rect = cv.boundingRect(contour);
            final cx = rect.x + rect.width / 2;
            final cy = rect.y + rect.height / 2;
            final distance = math.sqrt(math.pow(cx - windowCenterX, 2) + math.pow(cy - windowCenterY, 2));
            if (distance < bestDistance) {
              bestDistance = distance;
              bestRect = rect;
            }
          }
          if (bestRect == null) return null;
          final cx = left + bestRect.x + bestRect.width / 2;
          final cy = top + bestRect.y + bestRect.height / 2;
          return cv.Point2f(cx.toDouble(), cy.toDouble());
        } finally {
          contours.dispose();
          hierarchy.dispose();
        }
      } finally {
        binary.dispose();
      }
    } finally {
      roi.dispose();
    }
  }

  OmrScanResult _readBubbles(cv.Mat inkMap, OmrExamTemplate template, int canonicalWidth, int canonicalHeight) {
    // Sample the full printed bubble (its radius, converted to canonical
    // pixels), not a size guessed independently of what's actually on the
    // page — otherwise enlarging bubbles in the sheet generator without a
    // matching decoder change just keeps sampling the same small patch in
    // the middle, which is where the printed choice letter lives.
    final bubbleSampleHalfPx = template.bubbleRadiusPt * _canonicalPxPerPt;
    final items = <OmrItemResult>[];
    for (final section in template.sections) {
      for (final itemNumber in section.items.keys.toList()..sort()) {
        final choices = section.items[itemNumber]!;
        String? bestChoice;
        double bestFill = -1;
        double runnerUpFill = -1;
        for (final bubble in choices) {
          final fill = _bubbleFillFraction(inkMap, bubble, bubbleSampleHalfPx, canonicalWidth, canonicalHeight);
          if (fill > bestFill) {
            runnerUpFill = bestFill;
            bestFill = fill;
            bestChoice = bubble.choice;
          } else if (fill > runnerUpFill) {
            runnerUpFill = fill;
          }
        }

        if (bestFill < _blankFillFloor) {
          items.add(OmrItemResult(sectionName: section.name, itemNumber: itemNumber, markedChoice: null));
        } else if (bestFill - runnerUpFill < _ambiguousMargin) {
          items.add(
            OmrItemResult(
              sectionName: section.name,
              itemNumber: itemNumber,
              markedChoice: null,
              isAmbiguous: true,
            ),
          );
        } else {
          items.add(
            OmrItemResult(sectionName: section.name, itemNumber: itemNumber, markedChoice: bestChoice),
          );
        }
      }
    }
    return OmrScanResult(examCode: template.examCode, items: items);
  }

  /// Fraction (0-1) of the bubble's sample ROI that is "ink" on the
  /// binarized [inkMap] (255 = ink, after THRESH_BINARY_INV), independent
  /// of the original photo's overall brightness.
  double _bubbleFillFraction(cv.Mat inkMap, BubblePos bubble, double sampleHalfPx, int canonicalWidth, int canonicalHeight) {
    final cx = bubble.xFrac * canonicalWidth;
    final cy = bubble.yFrac * canonicalHeight;
    final left = (cx - sampleHalfPx).clamp(0, canonicalWidth - 1).round();
    final top = (cy - sampleHalfPx).clamp(0, canonicalHeight - 1).round();
    final right = (cx + sampleHalfPx).clamp(left + 1, canonicalWidth).round();
    final bottom = (cy + sampleHalfPx).clamp(top + 1, canonicalHeight).round();

    final roi = inkMap.region(cv.Rect(left, top, right - left, bottom - top));
    try {
      final mean = roi.mean();
      try {
        return mean.val1 / 255.0;
      } finally {
        mean.dispose();
      }
    } finally {
      roi.dispose();
    }
  }
}
