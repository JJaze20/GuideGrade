// Pure-Dart checks for the portrait TAT v5 template and its mesh: the
// template against the geometry JSON it was generated from, the
// triangulation, the mesh verdicts, orientation discrimination and that
// nothing earlier changed.
//
//   dart tool/verify_tat_v5.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../lib/core/omr/omr_mesh_correction.dart';
import '../lib/core/omr/omr_tat_legacy_template.dart';
import '../lib/core/omr/omr_template_registry.dart';
import '../lib/core/omr/omr_templates.dart';
import '../lib/core/omr/tat_marker_validation.dart';

int failures = 0;
void check(bool ok, String what) {
  if (!ok) {
    failures++;
    print('FAIL: $what');
  }
}

(double, double) _at(OmrExamTemplate t, OmrFiducialRole role) {
  final f = t.interiorFiducials.firstWhere((x) => x.role == role);
  return (f.xFrac * t.pageWidthPt, f.yFrac * t.pageHeightPt);
}

void main() {
  final t = omrTemplates['TAT']!;
  final json = jsonDecode(File('tool/data/TAT-portrait-v5.geometry.json').readAsStringSync())
      as Map<String, dynamic>;
  final pw = (json['pageWidth'] as num).toDouble(), ph = (json['pageHeight'] as num).toDouble();

  // --- template == geometry JSON ------------------------------------------
  check(t.templateVersion == 'TAT-portrait-v5', 'TAT is v5');
  check(t.pageWidthPt == pw && t.pageHeightPt == ph, 'page size 612 x 936');
  check(t.decoyMarkers.isEmpty, 'v5 has no decoy marks (the second edge pair was removed)');
  const tol = 0.02; // 5-decimal fractions => 0.01 pt on a 936 pt page
  final fid = {for (final f in json['fiducials'] as List) (f as Map)['role'] as String: f};
  final corners = ['topLeft', 'topRight', 'bottomLeft', 'bottomRight'];
  for (var i = 0; i < 4; i++) {
    final f = fid[corners[i]]!;
    check(
        (t.cornerMarkers[i].xFrac * pw - (f['x'] as num)).abs() < tol &&
            (t.cornerMarkers[i].yFrac * ph - (f['y'] as num)).abs() < tol,
        'corner ${corners[i]} matches the JSON');
  }
  const roleFor = {
    'midLeft': OmrFiducialRole.dividerLeft,
    'midRight': OmrFiducialRole.dividerRight,
    'centerTestII23And43': OmrFiducialRole.centerAtDivider,
    'aboveTestI1': OmrFiducialRole.tatAboveI1,
    'aboveTestI11': OmrFiducialRole.tatAboveI11,
    'aboveTestI21': OmrFiducialRole.tatAboveI21,
    'aboveTestII21': OmrFiducialRole.tatAboveII21,
    'aboveTestII41': OmrFiducialRole.tatAboveII41,
    'aboveTestIII6': OmrFiducialRole.tatAboveIII6,
    'aboveTestIII11': OmrFiducialRole.tatAboveIII11,
  };
  check(t.interiorFiducials.length == 10, '10 interior marks (3 big + 7 small)');
  for (final e in roleFor.entries) {
    final f = fid[e.key]!;
    final m = t.interiorFiducials.where((x) => x.role == e.value).toList();
    check(m.length == 1, '${e.key} registered exactly once');
    if (m.length != 1) continue;
    check(
        (m.single.xFrac * pw - (f['x'] as num)).abs() < tol && (m.single.yFrac * ph - (f['y'] as num)).abs() < tol,
        '${e.key} position matches the JSON');
    check(m.single.halfSizePt == (f['side'] as num) / 2, '${e.key} size matches the JSON');
  }
  final bubbles = (json['bubbles'] as List).cast<Map<String, dynamic>>();
  check(bubbles.length == 320, '320 bubbles in the JSON');
  var matched = 0;
  for (final b in bubbles) {
    final sec = t.sections.firstWhere((s) => s.name == b['section']);
    final cell = sec.items[b['question'] as int]?.where((p) => p.choice == b['choice']).toList() ?? const [];
    if (cell.length == 1 &&
        (cell.single.xFrac * pw - (b['x'] as num)).abs() < tol &&
        (cell.single.yFrac * ph - (b['y'] as num)).abs() < tol) {
      matched++;
    }
  }
  check(matched == 320, 'all 320 bubble positions match ($matched/320)');
  check(t.sections.map((s) => s.itemCount).join(',') == '30,80,20', 'sections 30/80/20 (130 questions)');
  for (final s in t.sections) {
    for (var n = 1; n <= s.itemCount; n++) {
      check(s.items[n]?.map((b) => b.choice).join(',') == (s.name == 'Test I' ? 'A,B,C,D' : 'T,F'),
          '${s.name} $n choices');
    }
  }
  check(t.bubbleRadiusPt == 8.0 && t.bubbleRadiusYPt == 5.6, 'bubble radii from the JSON');
  final fields = {for (final f in json['fields'] as List) (f as Map)['name'] as String: f};
  for (final (name, r) in [
    ('Last Name', t.lastNameFieldRect),
    ('First Name', t.firstNameFieldRect),
    ('M.I.', t.middleNameFieldRect),
  ]) {
    final f = fields[name]!;
    check(
        (r.xFrac * pw - (f['x'] as num)).abs() < tol &&
            (r.yFrac * ph - (f['y'] as num)).abs() < tol &&
            (r.widthFrac * pw - (f['width'] as num)).abs() < tol &&
            (r.heightFrac * ph - (f['height'] as num)).abs() < tol,
        'name field "$name" matches the JSON (for manual-entry crops)');
  }

  // --- triangulation tiles the corner rectangle exactly --------------------
  final pos = {
    OmrMeshVertex.topLeft: (t.cornerMarkers[0].xFrac * pw, t.cornerMarkers[0].yFrac * ph),
    OmrMeshVertex.topRight: (t.cornerMarkers[1].xFrac * pw, t.cornerMarkers[1].yFrac * ph),
    OmrMeshVertex.bottomLeft: (t.cornerMarkers[2].xFrac * pw, t.cornerMarkers[2].yFrac * ph),
    OmrMeshVertex.bottomRight: (t.cornerMarkers[3].xFrac * pw, t.cornerMarkers[3].yFrac * ph),
    OmrMeshVertex.dividerLeft: _at(t, OmrFiducialRole.dividerLeft),
    OmrMeshVertex.dividerRight: _at(t, OmrFiducialRole.dividerRight),
    OmrMeshVertex.centerAtDivider: _at(t, OmrFiducialRole.centerAtDivider),
    OmrMeshVertex.tatAboveI1: _at(t, OmrFiducialRole.tatAboveI1),
    OmrMeshVertex.tatAboveI11: _at(t, OmrFiducialRole.tatAboveI11),
    OmrMeshVertex.tatAboveI21: _at(t, OmrFiducialRole.tatAboveI21),
    OmrMeshVertex.tatAboveII21: _at(t, OmrFiducialRole.tatAboveII21),
    OmrMeshVertex.tatAboveII41: _at(t, OmrFiducialRole.tatAboveII41),
    OmrMeshVertex.tatAboveIII6: _at(t, OmrFiducialRole.tatAboveIII6),
    OmrMeshVertex.tatAboveIII11: _at(t, OmrFiducialRole.tatAboveIII11),
  };
  final topology = OmrMeshCorrection.tatV5Topology;
  var areaSum = 0.0;
  final used = <OmrMeshVertex>{};
  final edgeCount = <String, int>{};
  for (final tri in topology) {
    final a = pos[tri[0]]!, b = pos[tri[1]]!, c = pos[tri[2]]!;
    final area2 = ((b.$1 - a.$1) * (c.$2 - a.$2) - (b.$2 - a.$2) * (c.$1 - a.$1)).abs();
    check(area2 > 1.0, 'triangle ${tri.map((v) => v.name).join('/')} is not degenerate');
    areaSum += area2 / 2;
    used.addAll(tri);
    for (final (p, q) in [(tri[0], tri[1]), (tri[1], tri[2]), (tri[2], tri[0])]) {
      final k = p.index < q.index ? '${p.name}|${q.name}' : '${q.name}|${p.name}';
      edgeCount[k] = (edgeCount[k] ?? 0) + 1;
    }
  }
  final x0 = pos[OmrMeshVertex.topLeft]!.$1, x1 = pos[OmrMeshVertex.topRight]!.$1;
  final y0 = pos[OmrMeshVertex.topLeft]!.$2, y1 = pos[OmrMeshVertex.bottomLeft]!.$2;
  check((areaSum - (x1 - x0) * (y1 - y0)).abs() < 0.5,
      'triangle areas sum to the corner rectangle ($areaSum vs ${(x1 - x0) * (y1 - y0)})');
  check(used.length == pos.length, 'every mark is a vertex of some triangle');
  check(edgeCount.values.every((n) => n <= 2), 'no edge is shared by more than two triangles');
  bool near(double a, double b) => (a - b).abs() < 0.5;
  for (final e in edgeCount.entries.where((e) => e.value == 1)) {
    final names = e.key.split('|');
    final p = pos[OmrMeshVertex.values.byName(names[0])]!, q = pos[OmrMeshVertex.values.byName(names[1])]!;
    final onSide = (near(p.$1, x0) && near(q.$1, x0)) ||
        (near(p.$1, x1) && near(q.$1, x1)) ||
        (near(p.$2, y0) && near(q.$2, y0)) ||
        (near(p.$2, y1) && near(q.$2, y1));
    check(onSide, 'boundary edge ${e.key} lies on the rectangle border');
  }

  // --- mesh verdicts ---------------------------------------------------------
  final measured = {for (final f in t.interiorFiducials) f.role: (f.xFrac * pw, f.yFrac * ph)};
  OmrMeshCorrection build(Map<OmrFiducialRole, (double, double)> m, {int scale = 1}) => OmrMeshCorrection.build(
        template: t,
        canonicalWidth: (pw * scale).round(),
        canonicalHeight: (ph * scale).round(),
        cornersMeasuredPx: [
          for (final c in t.cornerMarkers) (c.xFrac * pw * scale, c.yFrac * ph * scale),
        ],
        interiorMeasuredPx: {for (final e in m.entries) e.key: (e.value.$1 * scale, e.value.$2 * scale)},
      );
  check(build(measured).verdict == OmrMeshVerdict.planar, 'flat sheet: planar, global warp kept');
  check(build({}).verdict == OmrMeshVerdict.inconclusive, 'no marks found: inconclusive, not rejected');
  // Paper bowing inward at both sides (left marks move right, right marks move
  // left, most in the middle): the shape seen on a real photo. All marks moving
  // the SAME way would be a shifted frame, which is judged separately below.
  final bow = {
    for (final e in measured.entries)
      e.key: (
        e.value.$1 + 10 * math.sin(math.pi * e.value.$2 / ph) * (1 - 2 * e.value.$1 / pw),
        e.value.$2,
      ),
  };
  final bowed = build(bow);
  check(bowed.isActive, 'a 10 pt side bow is corrected by the mesh (${bowed.verdict.name})');
  for (final p in bowed.points.values) {
    final q = bowed.correct(p.canonicalX, p.canonicalY);
    check((q.$1 - p.measuredX).abs() < 0.001 && (q.$2 - p.measuredY).abs() < 0.001,
        'mesh passes through ${p.vertex.name}');
  }
  final oneMissing = {...bow}..remove(OmrFiducialRole.tatAboveI21);
  check(build(oneMissing).isActive, 'one small mark hidden: still supported');
  final twoMissing = {...bow}
    ..remove(OmrFiducialRole.tatAboveI21)
    ..remove(OmrFiducialRole.tatAboveIII11);
  check(build(twoMissing).isActive, 'two small marks hidden (one per band): still supported');
  final noBandIII = {...bow}
    ..remove(OmrFiducialRole.tatAboveIII6)
    ..remove(OmrFiducialRole.tatAboveIII11);
  check(build(noBandIII).shouldRejectCapture, 'all Test III marks hidden on a bowed sheet: refused');
  final coherent = {for (final e in measured.entries) e.key: (e.value.$1 + 9, e.value.$2)};
  check(build(coherent).verdict == OmrMeshVerdict.likelyMisregistered,
      'whole frame shifted: a wrong corner, not bending');
  final severe = {
    ...measured,
    OmrFiducialRole.tatAboveII41: (
      measured[OmrFiducialRole.tatAboveII41]!.$1 + 60,
      measured[OmrFiducialRole.tatAboveII41]!.$2
    ),
  };
  check(build(severe).shouldRejectCapture, 'one mark 60 pt off: refused');
  check(build(bow, scale: 6).verdict == bowed.verdict, 'verdict does not depend on resolution');
  var folds = 0;
  for (final s in t.sections) {
    for (final cells in s.items.values) {
      for (final b in cells) {
        final x = b.xFrac * pw, y = b.yFrac * ph;
        final p = bowed.correct(x, y), r = bowed.correct(x + 0.001, y), d = bowed.correct(x, y + 0.001);
        if ((r.$1 - p.$1) * (d.$2 - p.$2) - (r.$2 - p.$2) * (d.$1 - p.$1) <= 0) folds++;
      }
    }
  }
  check(folds == 0, 'no foldovers at any of the 320 bubbles ($folds)');

  // --- orientation: a 180 degree turn must not look like a valid sheet -------
  final small = t.interiorFiducials.where((f) => f.halfSizePt < 4).toList();
  check(small.length == 7, 'seven small marks');
  var coincide = 0;
  for (final f in small) {
    final rx = pw - f.xFrac * pw, ry = ph - f.yFrac * ph;
    for (final g in small) {
      if (math.sqrt(math.pow(rx - g.xFrac * pw, 2) + math.pow(ry - g.yFrac * ph, 2)) < 12) coincide++;
    }
  }
  check(coincide == 0, 'turned 180 degrees no small mark lands on another ($coincide coincide)');

  // --- marker shape gate and direction selection (registration inputs) -----
  for (final size in [12.0, 24.0, 54.0, 84.0]) {
    check(tatMarkerShapeMatches(expectedSidePx: size, shortSide: size, longSide: size + 2, extent: 0.92),
        'square accepted at $size px');
    check(!tatMarkerShapeMatches(expectedSidePx: size, shortSide: size, longSide: size, extent: math.pi / 4),
        'filled circle rejected at $size px');
    check(!tatMarkerShapeMatches(expectedSidePx: size, shortSide: size / 3, longSide: size * 2, extent: 0.95),
        'text/line rejected at $size px');
    check(!tatMarkerShapeMatches(expectedSidePx: size, shortSide: size * 2, longSide: size * 2, extent: 0.95),
        'wrong-size square rejected at $size px');
  }
  check(tatMarkerMatchIsAmbiguous(0.9, 0.88), 'competing candidates not guessed');
  check(!tatMarkerMatchIsAmbiguous(0.9, -1), 'single candidate retained');
  check(selectTatPortraitDirection(asShotCount: 6, asShotScore: 5.4, turnedCount: 0, turnedScore: 0) == 0,
      'upright sheet: as shot');
  check(selectTatPortraitDirection(asShotCount: 0, asShotScore: 0, turnedCount: 6, turnedScore: 5.2) == 1,
      'upside-down sheet: turned 180');
  check(selectTatPortraitDirection(asShotCount: 2, asShotScore: 1.8, turnedCount: 1, turnedScore: 0.9) == null,
      'too few marks either way: refused');
  check(selectTatPortraitDirection(asShotCount: 4, asShotScore: 3.6, turnedCount: 4, turnedScore: 3.5) == null,
      'two equally plausible readings: refused');
  check(selectTatPortraitDirection(asShotCount: 3, asShotScore: 2.7, turnedCount: 1, turnedScore: 0.8) == 0,
      'three marks beat a stray match');

  // --- nothing earlier changed ----------------------------------------------
  check(omrTemplateFor('TAT', null)!.templateVersion == 'TAT-portrait-v5', 'current TAT is v5');
  check(omrTemplateFor('TAT', 'TAT-portrait-v1')!.templateVersion == 'TAT-portrait-v1', 'v1 scans still resolve');
  check(identical(omrTemplateFor('TAT', 'TAT-redesign-v1'), legacyTatTemplate), 'legacy TAT scans still resolve');
  check(omrTemplateFor('TAT', 'no-such-layout') == null, 'an unknown layout resolves to nothing, not to the wrong sheet');
  for (final code in ['AT', 'QTM']) {
    check(identical(omrTemplateFor(code, null), omrTemplates[code]), '$code resolves as before');
    check(omrTemplates[code]!.interiorFiducials.length == 5, '$code keeps its 5 interior marks');
    check(omrTemplates[code]!.decoyMarkers.isEmpty, '$code has no decoys');
  }

  print(failures == 0 ? 'OK' : '$failures failed');
  if (failures != 0) throw Exception('TAT v5 verification failed');
}
