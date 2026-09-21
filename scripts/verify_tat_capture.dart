// Native image regression check. Render answer_sheets/TAT.pdf to a PNG first.
// dart run scripts/verify_tat_capture.dart path/to/TAT.png
import 'dart:io';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:guidegrade/core/omr/omr_decoder_native.dart';
import 'package:guidegrade/core/omr/omr_templates.dart';

void main(List<String> args) {
  if (args.length != 1) {
    throw ArgumentError('Provide a raster of the current answer_sheets/TAT.pdf');
  }
  final directory = Directory.systemTemp.createTempSync('tat-capture-');
  final source = cv.imread(args.single);
  final template = omrTemplates['TAT']!;
  const decoder = OmrDecoder();
  try {
    if (source.isEmpty) throw StateError('Could not load template raster');
    for (final height in [800, 1600, 2400]) {
      final raster = cv.resize(source, (
        (height * template.pageWidthPt / template.pageHeightPt).round(),
        height,
      ));
      try {
        final path = '${directory.path}/tat-$height.png';
        cv.imwrite(path, raster);
        final check = decoder.locateCorners(path, template);
        if (!check.aligned) {
          throw StateError('Complete sheet at $height px: ${check.message}');
        }
        // Cover the whole bottom-right corner region, including the nearby
        // edge mark. A section square must not substitute for a missing corner.
        final white = cv.Scalar.all(255);
        try {
          cv.rectangle(raster, cv.Rect(
            (raster.width * .85).floor(),
            (raster.height * .80).floor(),
            (raster.width * .15).ceil(),
            (raster.height * .20).ceil(),
          ), white, thickness: -1);
        } finally {
          white.dispose();
        }
        cv.imwrite(path, raster);
        final obscured = decoder.locateCorners(path, template);
        if (obscured.aligned) {
          throw StateError('Missing bottom-right corner accepted at $height px');
        }
      } finally {
        raster.dispose();
      }
    }
    stdout.writeln('PASS: complete and obscured TAT rasters at 800/1600/2400 px.');
  } finally {
    source.dispose();
    directory.deleteSync(recursive: true);
  }
}
