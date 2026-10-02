// Verify the scanner samples the exact coordinates of the printed A4 sheet.
import 'dart:convert';
import 'dart:io';
import '../lib/core/omr/omr_templates.dart';
import '../lib/core/omr/omr_template_registry.dart';

void main() {
  final g = jsonDecode(File('tool/data/TAT-A4-placement-v2.geometry.json').readAsStringSync());
  final t = omrTemplates['TAT']!;
  void check(bool ok, String message) { if (!ok) throw StateError(message); }
  check(t.templateVersion == 'TAT-A4-placement-v2', 'A4 must be active');
  check(t.pageWidthPt == g['pageWidth'] && t.pageHeightPt == g['pageHeight'], 'Page size');
  check(t.sections.map((s) => s.name).join(',') == 'Test I,Test II,Test III', 'Scoring order');
  var count = 0;
  for (final b in g['bubbles']) {
    final s = t.sections.firstWhere((s) => s.name == b['section']);
    final cell = s.items[b['question']]!.firstWhere((p) => p.choice == b['choice']);
    check((cell.xFrac * t.pageWidthPt - b['x']).abs() < .00001, 'Bubble x');
    check((cell.yFrac * t.pageHeightPt - b['y']).abs() < .00001, 'Bubble y');
    check(t.bubbleRadiusPt == b['rx'] && t.bubbleRadiusYPt == b['ry'], 'Bubble size');
    count++;
  }
  check(count == 320 && t.sections.fold<int>(0,(n,s)=>n+s.itemCount) == 130, 'Item coverage');
  final corners = (g['fiducials'] as List).where((m) => ['topLeft','topRight','bottomLeft','bottomRight'].contains(m['role'])).toList();
  for (var i=0;i<4;i++) {
    check((t.cornerMarkers[i].xFrac*t.pageWidthPt-corners[i]['x']).abs()<.00001, 'Corner x');
    check((t.cornerMarkers[i].yFrac*t.pageHeightPt-corners[i]['y']).abs()<.00001, 'Corner y');
  }
  check(omrTemplateFor('TAT','TAT-portrait-v5')!.pageHeightPt == 936, 'Archived v5 retained');
  check(t.interiorFiducials.length == 9 && t.decoyMarkers.isEmpty, 'All A4 interior marks registered');
  print('PASS: all 320 bubbles, 130 items, A4 corners, sizes and archived v5 verified.');
}
