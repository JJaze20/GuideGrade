// Pure-Dart check of portrait TAT's decoy marks (see OmrDecoyMark): they exist,
// sit on the bottom corners' edge columns above them, are not registered as
// corners or interior fiducials, and no other exam has any.
// Run: dart tool/verify_tat_decoys.dart
import '../lib/core/omr/omr_templates.dart';

int failures = 0;
void check(bool ok, String what) {
  if (!ok) {
    failures++;
    print('FAIL: $what');
  }
}

void main() {
  final tat = omrTATPortraitV1;
  check(tat.templateVersion == 'TAT-portrait-v1', 'TAT is the portrait template');
  check(tat.decoyMarkers.length == 2, 'TAT lists its two edge decoys');
  final bl = tat.cornerMarkers[2], br = tat.cornerMarkers[3];
  for (final d in tat.decoyMarkers) {
    final corner = (d.xFrac - bl.xFrac).abs() < 0.01 ? bl : br;
    check((d.xFrac - corner.xFrac).abs() < 0.01, 'decoy shares a bottom corner\'s edge column');
    check(d.yFrac < corner.yFrac, 'decoy is above that corner');
    final gapPt = (corner.yFrac - d.yFrac) * tat.pageHeightPt;
    check(gapPt > 100 && gapPt < 150, 'decoy is ~125 pt above the corner (got ${gapPt.toStringAsFixed(1)})');
    check(d.halfSizePt == 7.0, 'decoy is corner-sized');
    for (final f in tat.interiorFiducials) {
      final near = (f.xFrac - d.xFrac).abs() < 0.01 && (f.yFrac - d.yFrac).abs() < 0.01;
      check(!near, 'decoy is not also registered as ${f.role.name}');
    }
    for (final c in tat.cornerMarkers) {
      check(!((c.xFrac - d.xFrac).abs() < 0.01 && (c.yFrac - d.yFrac).abs() < 0.01), 'decoy is not a corner');
    }
  }
  for (final e in omrTemplates.entries.where((e) => e.key != 'TAT')) {
    check(e.value.decoyMarkers.isEmpty, '${e.key} has no decoys');
  }
  print(failures == 0 ? 'OK' : '$failures failed');
  if (failures != 0) throw Exception('decoy verification failed');
}
