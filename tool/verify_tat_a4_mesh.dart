import 'dart:math' as math;
import '../lib/core/omr/omr_templates.dart';
import '../lib/core/omr/omr_mesh_correction.dart';
import '../lib/core/omr/omr_template_registry.dart';

void main() {
  void check(bool ok, String message) { if (!ok) throw StateError(message); }
  final t = omrTemplates['TAT']!;
  const width=1191, height=1684;
  final corners=[for(final c in t.cornerMarkers) (c.xFrac*width,c.yFrac*height)];
  final measured={for(final f in t.interiorFiducials) f.role:(f.xFrac*width,f.yFrac*height)};
  OmrMeshCorrection build(Map<OmrFiducialRole,(double,double)> m) => OmrMeshCorrection.build(
    template:t,canonicalWidth:width,canonicalHeight:height,cornersMeasuredPx:corners,interiorMeasuredPx:m);
  final flat=build(measured);
  check(flat.verdict==OmrMeshVerdict.planar,'Flat sheet must not be distorted');
  double area=0;
  for(final tri in OmrMeshCorrection.tatA4Topology) {
    final a=flat.points[tri[0]]!,b=flat.points[tri[1]]!,c=flat.points[tri[2]]!;
    final cross=(b.canonicalX-a.canonicalX)*(c.canonicalY-a.canonicalY)-(b.canonicalY-a.canonicalY)*(c.canonicalX-a.canonicalX);
    check(cross.abs()>1,'No degenerate triangles');
    area+=cross.abs()/2;
  }
  final expected=(corners[1].$1-corners[0].$1)*(corners[2].$2-corners[0].$2);
  check((area-expected).abs()<.01,'Mesh must cover the page without excess area');
  final bent=Map<OmrFiducialRole,(double,double)>.of(measured);
  final role=OmrFiducialRole.centerAtDivider;
  bent[role]=(measured[role]!.$1+4,measured[role]!.$2);
  final mesh=build(bent);
  check(mesh.isActive,'Moderate local movement should activate correction');
  final corrected=mesh.correct(measured[role]!.$1,measured[role]!.$2);
  check((corrected.$1-bent[role]!.$1).abs()<.001,'Control point must map to measured position');
  for(final section in t.sections) {
    for(final cells in section.items.values) {
      for(final cell in cells) {
        final p=mesh.correct(cell.xFrac*width,cell.yFrac*height);
        check(p.$1.isFinite&&p.$2.isFinite,'Bubble correction finite');
        check(math.sqrt(math.pow(p.$1-cell.xFrac*width,2)+math.pow(p.$2-cell.yFrac*height,2))<=4.001,'No amplification');
      }
    }
  }
  final missing=Map<OmrFiducialRole,(double,double)>.of(bent)
    ..remove(OmrFiducialRole.tatAboveII21)..remove(OmrFiducialRole.tatAboveII41);
  check(!build(missing).isActive,'Unreferenced Test II must not activate mesh');
  final unsafe=Map<OmrFiducialRole,(double,double)>.of(measured);
  unsafe[role]=(measured[role]!.$1+100,measured[role]!.$2);
  check(!build(unsafe).isActive,'Extreme displacement rejected');
  for(final code in ['AT','QTM']) {
    final other=omrTemplates[code]!;
    final m=OmrMeshCorrection.build(template:other,canonicalWidth:width,canonicalHeight:height,
      cornersMeasuredPx:[for(final c in other.cornerMarkers)(c.xFrac*width,c.yFrac*height)],
      interiorMeasuredPx:{for(final f in other.interiorFiducials)f.role:(f.xFrac*width,f.yFrac*height)});
    check(m.verdict==OmrMeshVerdict.planar,'$code planar behavior retained');
  }
  check(omrTemplateFor('TAT','TAT-portrait-v5')!.interiorFiducials.length==10,'Old TAT retained');
  print('PASS: A4 topology, local correction, missing/unsafe marks, AT/QTM and archived TAT.');
}
