// Pure-Dart regression check: AT and QTM scanning geometry (bubble centres,
// corner and interior marks, page size, bubble radii, template version) in the
// working tree is identical to the origin branch's omr_templates.dart. Only the
// name-field crop rectangles may differ (the redesigned sheets' name row).
//
//   dart tool/verify_at_qtm_unchanged.dart [git-ref]   (default origin/fix/scanning-improvements)
import 'dart:io';

int failures = 0;
void check(bool ok, String what) {
  if (!ok) {
    failures++;
    print('FAIL: $what');
  }
}

/// The geometry tokens of one exam's template block, in file order.
List<String> geometryTokens(String source, String blockName) {
  final start = source.indexOf('final OmrExamTemplate $blockName =');
  if (start < 0) throw StateError('no $blockName block');
  final next = source.indexOf('\nfinal OmrExamTemplate ', start + 10);
  final block = source.substring(start, next < 0 ? source.length : next);
  final tokens = <String>[];
  for (final pattern in [
    r'templateVersion: "[^"]*"',
    r'pageWidthPt: [\d.]+',
    r'pageHeightPt: [\d.]+',
    r'bubbleRadiusPt: [\d.]+',
    r'bubbleRadiusYPt: [\d.]+',
    r'OmrCorner\([\d.]+, [\d.]+\)',
    r'OmrFiducial\(OmrFiducialRole\.\w+, [\d.]+, [\d.]+, [\d.]+\)',
    r'OmrSection\(\s*name: "[^"]*",\s*itemCount: \d+',
    r'BubblePos\("[A-Z]", [\d.]+, [\d.]+\)',
  ]) {
    tokens.addAll(RegExp(pattern).allMatches(block).map((m) => m.group(0)!));
  }
  return tokens;
}

void main(List<String> args) {
  final ref = args.isNotEmpty ? args.first : 'origin/fix/scanning-improvements';
  final origin = Process.runSync('git', ['show', '$ref:lib/core/omr/omr_templates.dart'], runInShell: true);
  if (origin.exitCode != 0) {
    print('cannot read $ref: ${origin.stderr}');
    exit(2);
  }
  final before = origin.stdout as String;
  final now = File('lib/core/omr/omr_templates.dart').readAsStringSync();
  for (final block in ['_omrAT', '_omrQTM']) {
    final a = geometryTokens(before, block);
    final b = geometryTokens(now, block);
    check(a.isNotEmpty, '$block has geometry tokens in $ref');
    check(a.length == b.length, '$block token count ${a.length} vs ${b.length}');
    var differing = 0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) differing++;
    }
    check(differing == 0, '$block geometry identical to $ref ($differing tokens differ)');
    print('$block: ${a.length} geometry tokens compared, $differing differ');
  }
  print(failures == 0 ? 'OK' : '$failures failed');
  if (failures != 0) exit(1);
}
