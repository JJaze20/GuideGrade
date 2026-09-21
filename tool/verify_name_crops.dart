// Pure-Dart geometry checks for the Last Name / First Name / Middle Name crop
// rectangles of AT, QTM and TAT (portrait v5): all three exist, share one
// printed row, do not overlap, sit inside the corner marks, are left-to-right
// in reading order, and are tall enough for handwriting. Geometry only: this
// says nothing about real-photo crop quality (needs saved device captures).
//
//   dart tool/verify_name_crops.dart
import '../lib/core/omr/omr_templates.dart';

int failures = 0;
void check(bool ok, String what) {
  if (!ok) {
    failures++;
    print('FAIL: $what');
  }
}

void main() {
  for (final code in ['AT', 'QTM', 'TAT']) {
    final t = omrTemplates[code]!;
    final w = t.pageWidthPt, h = t.pageHeightPt;
    final rects = [t.lastNameFieldRect, t.firstNameFieldRect, t.middleNameFieldRect];
    final names = ['last', 'first', 'middle'];
    final left = t.cornerMarkers[0].xFrac, right = t.cornerMarkers[1].xFrac;
    final top = t.cornerMarkers[0].yFrac, bottom = t.cornerMarkers[2].yFrac;
    for (var i = 0; i < 3; i++) {
      final r = rects[i];
      check(r.widthFrac * w >= 30, '$code ${names[i]} is at least 30 pt wide (${(r.widthFrac * w).toStringAsFixed(1)})');
      check(r.heightFrac * h >= 14, '$code ${names[i]} is at least 14 pt tall (${(r.heightFrac * h).toStringAsFixed(1)})');
      check(r.xFrac > left && r.xFrac + r.widthFrac < right, '$code ${names[i]} lies between the side corner marks');
      check(r.yFrac > top && r.yFrac + r.heightFrac < bottom, '$code ${names[i]} lies between the top and bottom corner marks');
      check((r.yFrac - rects[0].yFrac).abs() < 1e-9 && (r.heightFrac - rects[0].heightFrac).abs() < 1e-9,
          '$code ${names[i]} is on the same row as last name');
    }
    for (var i = 0; i < 2; i++) {
      final gapPt = (rects[i + 1].xFrac - (rects[i].xFrac + rects[i].widthFrac)) * w;
      check(gapPt >= -0.01 && gapPt < 6, '$code ${names[i]} -> ${names[i + 1]} gap ${gapPt.toStringAsFixed(2)} pt (no overlap, no dead zone)');
    }
    print('$code: last ${(rects[0].widthFrac * w).toStringAsFixed(0)}pt, first ${(rects[1].widthFrac * w).toStringAsFixed(0)}pt, '
        'middle ${(rects[2].widthFrac * w).toStringAsFixed(0)}pt wide, ${(rects[0].heightFrac * h).toStringAsFixed(0)}pt tall');
  }
  print(failures == 0 ? 'OK' : '$failures failed');
  if (failures != 0) throw Exception('name crop geometry failed');
}
