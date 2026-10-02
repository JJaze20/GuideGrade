// Pure Dart checks, runnable without Flutter's OpenCV native build hooks:
// dart tool/verify_tat_registration.dart
import 'dart:math' as math;
import '../lib/core/omr/omr_templates.dart';
import '../lib/core/omr/omr_tat_legacy_template.dart';
import '../lib/core/omr/omr_mesh_correction.dart';
import '../lib/core/omr/tat_marker_validation.dart';

void check(bool value, String label) {
  if (!value) throw StateError(label);
}

void main() {
  final t = omrTemplates['TAT']!;
  final measured = <OmrFiducialRole, (double,double)>{
    for(final f in t.interiorFiducials)
      f.role: (f.xFrac*t.pageWidthPt,f.yFrac*t.pageHeightPt),
  };
  OmrMeshCorrection build(Map<OmrFiducialRole,(double,double)> m, {int scale=1, OmrExamTemplate? template}) {
    final spec = template ?? t;
    return OmrMeshCorrection.build(template:spec,
      canonicalWidth:(spec.pageWidthPt*scale).round(),
      canonicalHeight:(spec.pageHeightPt*scale).round(),
      cornersMeasuredPx:[for(final c in spec.cornerMarkers)
        (c.xFrac*spec.pageWidthPt*scale,c.yFrac*spec.pageHeightPt*scale)],
      interiorMeasuredPx:{for(final e in m.entries) e.key:(e.value.$1*scale,e.value.$2*scale)});
  }
  check(t.templateVersion=='TAT-redesign-v2','version');
  check(t.interiorFiducials.length==8,'eight extra real marks');
  check(t.sections.map((s)=>s.itemCount).join(',')=='30,80,20','section counts');
  for(final s in t.sections) {
    check(s.items.length==s.itemCount,'all items present');
    for(var n=1;n<=s.itemCount;n++) {
      check(s.items[n]!.map((b)=>b.choice).join(',')==(s.name=='Test I'?'A,B,C,D':'T,F'),'choice mapping');
    }
  }
  final flat=build(measured);
  check(flat.verdict==OmrMeshVerdict.planar && !flat.isActive,'flat retains global correction');
  check(flat.diagnostics.length==8,'all marks evaluated');
  check(build({}).verdict==OmrMeshVerdict.inconclusive,'missing not detected');
  final bent={for(final e in measured.entries) e.key:
    (e.value.$1,e.value.$2+4*math.sin(math.pi*e.value.$1/t.pageWidthPt))};
  final mesh=build(bent);
  check(mesh.isActive,'modest synthetic bend supported');
  for(final p in mesh.points.values) {
    final q=mesh.correct(p.canonicalX,p.canonicalY);
    check((q.$1-p.measuredX).abs()<0.001 && (q.$2-p.measuredY).abs()<0.001,'mesh passes measured anchors');
  }
  final missingSide={...bent}..remove(OmrFiducialRole.dividerLeft);
  check(build(missingSide).isActive,'one missing side, section references retained');
  final missingSection={...bent}..remove(OmrFiducialRole.tatAboveII);
  check(build(missingSection).shouldRejectCapture,'unsupported measured displacement rejected');
  final severe={...measured,OmrFiducialRole.tatBelowIII:(measured[OmrFiducialRole.tatBelowIII]!.$1+25,544.0)};
  check(build(severe).shouldRejectCapture,'one failing mark cannot be hidden');
  check(build({OmrFiducialRole.tatBelowIII:severe[OmrFiducialRole.tatBelowIII]!}).shouldRejectCapture,'large measured failure overrides missing evidence');
  final shifted={for(final e in measured.entries)e.key:(e.value.$1+9,e.value.$2)};
  check(build(shifted).verdict==OmrMeshVerdict.likelyMisregistered,'coherent outer-frame error');
  final restored=OmrMeshCorrection.fromMeasuredFractions(template:t,canonicalWidth:1872,canonicalHeight:1224,
      measuredFrac:mesh.toMeasuredFractions(936,612));
  for(final s in t.sections) {
    for(final bubbles in s.items.values) {
      for(final b in bubbles) {
        final x=b.xFrac*936,y=b.yFrac*612;
        final p=mesh.correct(x,y), q=restored.correct(x*2,y*2);
        check((p.$1-q.$1/2).abs()<1e-6 && (p.$2-q.$2/2).abs()<1e-6,'saved overlay/sample mapping agrees');
        final right=mesh.correct(x+0.001,y),down=mesh.correct(x,y+0.001);
        final jac=(right.$1-p.$1)*(down.$2-p.$2)-(right.$2-p.$2)*(down.$1-p.$1);
        check(jac>0,'no local foldovers');
      }
    }
  }
  check(build(bent,scale:6).verdict==mesh.verdict,'resolution-independent verdict');
  check(mesh.correct(0,0)==(0.0,0.0),'no unsupported outer extrapolation');
  check(build({},template:legacyTatTemplate).verdict==OmrMeshVerdict.notApplicable,'archive compatibility');
  for(final code in ['AT','QTM']) check(omrTemplates[code]!.interiorFiducials.length==5,'AT/QTM unchanged');
  for(final size in [18.0,28.0,54.0,84.0]) {
    check(tatMarkerShapeMatches(expectedSidePx:size,shortSide:size,longSide:size+2,extent:0.92),'square at multiple resolutions');
    check(!tatMarkerShapeMatches(expectedSidePx:size,shortSide:size,longSide:size,extent:math.pi/4),'filled circle rejected');
    check(!tatMarkerShapeMatches(expectedSidePx:size,shortSide:size/3,longSide:size*2,extent:0.95),'text/line rejected');
    check(!tatMarkerShapeMatches(expectedSidePx:size,shortSide:size*2,longSide:size*2,extent:0.95),'wrong-size square rejected');
  }
  check(tatMarkerMatchIsAmbiguous(0.9,0.88),'competing candidates not guessed');
  check(!tatMarkerMatchIsAmbiguous(0.9,-1),'single candidate retained');
  print('PASS: TAT mapping, flat/bent geometry, missing/severe/coherent marks, scale, all 320 overlay positions, legacy and candidate gates.');
}
