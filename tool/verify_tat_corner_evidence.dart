import 'dart:math' as math;
import '../lib/core/omr/tat_corner_evidence.dart';

void main() {
  void check(bool ok, String message) { if (!ok) throw StateError(message); }
  for (final angle in [0, 5, 12, 25, 40]) {
    for (final paper in [105.0, 180.0, 240.0]) {
      final rad=angle*math.pi/180;
      double pixel(int x,int y) {
        final dx=x-50.0,dy=y-50.0;
        final rx=dx*math.cos(rad)+dy*math.sin(rad);
        final ry=-dx*math.sin(rad)+dy*math.cos(rad);
        if(rx.abs()<=8 && ry.abs()<=8) return 25;
        return rx>=-10 ? paper : 18;
      }
      final bound=16*(math.cos(rad).abs()+math.sin(rad).abs())+2;
      final contrast=tatCornerContrast(imageWidth:100,imageHeight:100,
        x:50-bound/2,y:50-bound/2,width:bound,height:bound,grayAt:pixel);
      check(contrast>=70,'Tilted edge square rejected: $angle degrees, paper $paper');
    }
  }
  final flat=tatCornerContrast(imageWidth:100,imageHeight:100,x:40,y:40,width:20,height:20,grayAt:(x,y)=>25);
  check(flat==0,'Uniform dark tabletop must fail contrast');
  final light=tatCornerContrast(imageWidth:100,imageHeight:100,x:40,y:40,width:20,height:20,grayAt:(x,y)=>220);
  check(light==0,'Uniform paper must fail contrast');
  final edge=tatCornerContrast(imageWidth:20,imageHeight:20,x:0,y:0,width:10,height:10,
    grayAt:(x,y){check(x>=0&&x<20&&y>=0&&y<20,'Sampler out of bounds');return 50;});
  check(edge==0,'Clamped edge uniform');
  check(tatCornerAnchorRadius(1000,1500,false)==null,'No page boundary must retain broad search');
  check(tatCornerAnchorRadius(1000,1500,true)==80,'Detected boundary rejects faraway distractors');
  print('PASS: rotated edge squares at 0-40 degrees, shadows, flat backgrounds and bounded anchors.');
}
